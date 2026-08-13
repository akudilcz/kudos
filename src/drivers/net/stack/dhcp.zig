//! DHCP client (RFC 2131 / 2132). Runs once at init (net.init) to learn our
//! IP/netmask/gateway/DNS before any fetch. Built on net's broadcast-UDP send
//! and polled RX dispatch.

const std = @import("std");
const net = @import("net.zig");
const nic = @import("../nic/nic.zig");
const dhcp_wire = @import("dhcp_wire.zig");
const cfg = @import("config.zig");
const timer = @import("../../../kernel/timer/timer.zig");

// BOOTP op codes / hardware type / RFC 1497 magic cookie.
const BOOTREQUEST = 1;
const BOOTREPLY = 2;
const HTYPE_ETH = 1;
const HLEN_ETH = 6;
const MAGIC = [4]u8{ 0x63, 0x82, 0x53, 0x63 };

// BOOTP fixed-area field offsets and the size through the magic cookie.
const OFF_XID = 4;
const OFF_FLAGS = 10;
const OFF_YIADDR = 16;
const OFF_CHADDR = 28;
const OFF_MAGIC = 236;
const BOOTP_FIXED = 240; // op..magic cookie inclusive; options follow

const FLAG_BROADCAST: u16 = 0x8000;

// Option codes and message types are owned by dhcp_wire (the pure, host-tested parser).
// Aliased here so the request BUILDERS below use the same values the parser does — one
// definition, not two that can drift.
const OPT_SUBNET = dhcp_wire.OPT_SUBNET;
const OPT_ROUTER = dhcp_wire.OPT_ROUTER;
const OPT_DNS = dhcp_wire.OPT_DNS;
const OPT_MSGTYPE = dhcp_wire.OPT_MSGTYPE;
const OPT_SERVERID = dhcp_wire.OPT_SERVERID;
const OPT_END = dhcp_wire.OPT_END;
const DHCPOFFER = dhcp_wire.DHCPOFFER;
const DHCPACK = dhcp_wire.DHCPACK;
const DHCPNAK = dhcp_wire.DHCPNAK;

// Request-side only (the parser never reads these).
const OPT_REQ_IP = 50;
const OPT_PARAMREQ = 55;
const DHCPDISCOVER = 1;
const DHCPREQUEST = 3;

// BOOTP/DHCP UDP ports (RFC 951/2131) — owned by the pure dhcp_wire.zig (the
// ACK snoop reads them off raw frames there); re-exported so net.zig's RX
// demux keeps naming CLIENT_PORT through this module.
pub const CLIENT_PORT = dhcp_wire.CLIENT_PORT;
const SERVER_PORT = dhcp_wire.SERVER_PORT;

// Per-phase receive policy: bounded retries, polled deadline (same shape as
// net.resolveMac / udp.dnsResolve). DHCP runs ON the boot stack (the entry root
// calls net.init before the GSP boot), so these budgets are pure boot
// latency when nothing answers: a silent network costs the full DISCOVER phase,
// TRIES × PHASE_MS = 6 s, before the boot proceeds with `net: DOWN` (a REQUEST
// phase only happens after an OFFER, so it costs nothing extra in that case).
// Per-phase reply budget and retry count. Sized for two constraints:
//  - RFC 2131 §4.1: clients retransmit with timeouts on the order of seconds
//    (the suggested first interval is 4 s) — sub-second budgets are far outside
//    what servers are required to meet.
//  - QEMU's e1000 model (hw/net/e1000.c set_rx_control) arms a 1000 ms
//    flush-delay timer on every RCTL write, during which the model delivers
//    NOTHING to the RX ring. A total budget under ~1 s therefore fails
//    deterministically on QEMU: the OFFER flushes into the ring just after the
//    client gives up. 3 × 2000 ms clears that window with margin.
const TRIES = 3;
const PHASE_MS = 2000;

// One in-flight transaction.
var xid: u32 = 0;
var in_progress = false;
var got_reply = false;
var reply: [576]u8 = undefined; // RFC 2131 minimum reassembly size
var reply_len: usize = 0;

// The two fields the REQUEST must echo back from the OFFER.
//
// Only these two are staged. The lease values are NOT held here between messages:
// dhcp_wire.acceptAck returns them as a single value that is committed in one step, so
// there is no window in which a half-parsed lease can reach the live configuration.
var offered_ip = [4]u8{ 0, 0, 0, 0 };
var server_id = [4]u8{ 0, 0, 0, 0 };

/// True while configure() is mid-transaction. Gates net.zig's RX accommodations
/// (broadcast-dst accept, port-68 routing) so normal RX is unchanged once bound.
pub fn active() bool {
    return in_progress;
}

/// Called by net's RX dispatch for UDP datagrams to the client port while a
/// transaction is active. `msg` is the BOOTP message (UDP payload).
pub fn handleReply(msg: []const u8) void {
    if (msg.len < BOOTP_FIXED) return;
    if (msg[0] != BOOTREPLY) return;
    if (net.rbe32(msg[OFF_XID .. OFF_XID + 4]) != xid) return;
    if (!std.mem.eql(u8, msg[OFF_MAGIC .. OFF_MAGIC + 4], &MAGIC)) return;
    const n = @min(msg.len, reply.len);
    @memcpy(reply[0..n], msg[0..n]);
    reply_len = n;
    got_reply = true;
}

/// Build the BOOTP fixed area (op..magic cookie) into `out`. Returns BOOTP_FIXED.
fn buildBootp(out: []u8) usize {
    @memset(out[0..BOOTP_FIXED], 0);
    out[0] = BOOTREQUEST;
    out[1] = HTYPE_ETH;
    out[2] = HLEN_ETH;
    out[3] = 0; // hops
    net.wbe32(out[OFF_XID .. OFF_XID + 4], xid);
    net.wbe16(out[OFF_FLAGS .. OFF_FLAGS + 2], FLAG_BROADCAST);
    @memcpy(out[OFF_CHADDR .. OFF_CHADDR + HLEN_ETH], &cfg.our_mac);
    @memcpy(out[OFF_MAGIC .. OFF_MAGIC + 4], &MAGIC);
    return BOOTP_FIXED;
}

/// Append a code/length/value option at out[n.*], advancing n past it.
fn putOption(out: []u8, n: *usize, code: u8, body: []const u8) void {
    out[n.*] = code;
    out[n.* + 1] = @intCast(body.len);
    @memcpy(out[n.* + 2 .. n.* + 2 + body.len], body);
    n.* += 2 + body.len;
}

/// Build a DHCPDISCOVER into `out` (fixed area + msgtype + param-request list).
/// Returns the total length. Matches runPhase's `build` signature.
fn buildDiscover(out: []u8) usize {
    var n = buildBootp(out);
    putOption(out, &n, OPT_MSGTYPE, &[_]u8{DHCPDISCOVER});
    putOption(out, &n, OPT_PARAMREQ, &[_]u8{ OPT_SUBNET, OPT_ROUTER, OPT_DNS });
    out[n] = OPT_END;
    n += 1;
    return n;
}

/// Build a DHCPREQUEST into `out`, echoing the offered IP + server id from the
/// staged OFFER values. Returns the total length. Matches runPhase's `build`.
fn buildRequest(out: []u8) usize {
    var n = buildBootp(out);
    putOption(out, &n, OPT_MSGTYPE, &[_]u8{DHCPREQUEST});
    putOption(out, &n, OPT_REQ_IP, &offered_ip);
    putOption(out, &n, OPT_SERVERID, &server_id);
    putOption(out, &n, OPT_PARAMREQ, &[_]u8{ OPT_SUBNET, OPT_ROUTER, OPT_DNS });
    out[n] = OPT_END;
    n += 1;
    return n;
}

/// Poll net.pump() until a reply with the wanted message type arrives or the
/// deadline expires. A NAK aborts (returns false). Returns true on the want type.
fn awaitReply(want: u8) bool {
    const deadline = timer.millis() + PHASE_MS;
    while (timer.millis() < deadline) {
        net.pump();
        if (!got_reply) continue;
        got_reply = false;
        const mt = dhcp_wire.parseOptions(reply[0..reply_len]).msg_type orelse continue;
        if (mt == DHCPNAK) {
            net.dbg("dhcp: NAK\n");
            return false;
        }
        if (mt == want) return true;
    }
    return false;
}

/// One DHCP exchange: build the outbound message with `build`, broadcast it, and
/// wait for a reply of message type `want`, retrying up to TRIES times. `name` is
/// for the debug log. Returns true once such a reply lands in `reply`. The two
/// bind steps (DISCOVER→OFFER and REQUEST→ACK) are the same loop — only the
/// builder and the wanted type differ.
fn runPhase(name: []const u8, build: *const fn (out: []u8) usize, want: u8) bool {
    var buf: [400]u8 = undefined;
    var t: u8 = 0;
    while (t < TRIES) : (t += 1) {
        got_reply = false;
        const len = build(&buf);
        if (!net.sendBroadcastUdp(CLIENT_PORT, SERVER_PORT, buf[0..len])) {
            net.dbg(name);
            net.dbg(" send failed\n");
            return false;
        }
        net.dbg(name);
        net.dbg(" sent\n");
        // awaitReply returns false on NAK too; retry while the budget remains.
        if (awaitReply(want)) return true;
    }
    return false;
}

/// Run the DISCOVER -> OFFER -> REQUEST -> ACK bind, committing the lease into
/// cfg on success. Returns true iff a complete ACK was committed.
pub fn configure() bool {
    in_progress = true;
    defer in_progress = false;

    // Non-zero transaction id derived from the boot tick.
    xid = @as(u32, @truncate(timer.now())) | 0x1000_0000;

    // DISCOVER -> OFFER.
    if (!runPhase("dhcp: DISCOVER", buildDiscover, DHCPOFFER)) {
        net.dbg("dhcp: no OFFER\n");
        return false;
    }
    captureOfferFields();
    net.dbg("dhcp: OFFER received\n");

    // REQUEST -> ACK.
    if (!runPhase("dhcp: REQUEST", buildRequest, DHCPACK)) {
        net.dbg("dhcp: no ACK\n");
        return false;
    }
    if (!commitAck()) return false;
    state = .bound; // isUp()/isBound() read this — one truth for blocking + async
    return true;
}

/// Stage the two fields the REQUEST must echo back from the OFFER: the address
/// being offered (yiaddr) and which server offered it (option 54). Shared by the
/// blocking configure() and the async pump().
fn captureOfferFields() void {
    offered_ip = dhcp_wire.yiaddr(reply[0..reply_len]);
    if (dhcp_wire.parseOptions(reply[0..reply_len]).server_id) |sid| server_id = sid;
}

/// Commit the ACK's lease into cfg, or return false if it carried no address.
/// The ACK's options are authoritative over the OFFER's. The acceptance rule —
/// THE LEASE IS THE ADDRESS, everything else optional — lives in dhcp_wire.zig,
/// pure and host-tested. It is the rule that once cost us a machine (see
/// dhcp_wire.acceptAck), so it must be somewhere a test can reach it; this file
/// imports the NIC's MMIO and can never compile on the host. Shared by the
/// blocking configure() and the async pump().
fn commitAck() bool {
    const ack = reply[0..reply_len];
    const opts = dhcp_wire.parseOptions(ack);
    const lease = dhcp_wire.acceptAck(dhcp_wire.yiaddr(ack), opts) orelse {
        net.dbg("dhcp: ACK carried no address (yiaddr=0)\n");
        return false;
    };
    if (lease.assumed_mask) net.dbg("dhcp: ACK had no netmask — assuming /24\n");
    if (opts.gateway == null) net.dbg("dhcp: ACK had no gateway — on-subnet traffic only\n");
    if (opts.dns == null) net.dbg("dhcp: ACK had no DNS server — name lookup unavailable\n");

    // Commit (single source of truth). gateway/dns stay zero when absent; the code
    // that needs them (nextHop for off-subnet, udp.dnsResolve) checks and reports.
    @memcpy(&cfg.our_ip, &lease.ip);
    @memcpy(&cfg.netmask, &lease.mask);
    @memcpy(&cfg.gateway, &lease.gateway);
    @memcpy(&cfg.dns_server, &lease.dns);
    net.dbg("dhcp: ACK committed\n");
    return true;
}

// ── Async bind — kicked off at boot, driven by net.pump() in the session loop ───
//
// The blocking configure() above is kept for the -Dheartbeat debug image, which
// deliberately brings the network up BEFORE the desktop so telemetry survives a
// later hang. A normal boot cannot afford that: a lost first DISCOVER plus the
// retry gap costs ~13 s on the critical path (a DISCOVER sent before the PHY has
// carrier just vanishes). Instead start() KICKS OFF the bind and pump() — called
// every session-loop iteration by net.pump(), AFTER its RX drain — advances it one
// bounded step at a time. No spin, no sleep: the desktop shows at the first GPU
// present and the lease lands in the background a moment later, exactly as Linux
// lets carrier + DHCP settle after the UI is already up.
const State = enum { idle, await_link, discovering, requesting, bound };
var state: State = .idle;
var next_tx_ms: u64 = 0; // when to (re)transmit the current phase's message

/// Retransmit cadence for the in-flight DISCOVER/REQUEST. RFC 2131 §4.1 suggests
/// seconds; 1 s is brisk for a LAN and still far above any real server's latency.
const RETX_MS: u64 = 1000;

/// Gate on SENDING DHCP frames. Left false until USB enumeration finishes so the
/// bind sends NOTHING on the wire while xhci.init walks the bus: a DISCOVER/REQUEST
/// broadcast from the trace/service pump (bootPump) mid-enumeration competes with
/// the tight, IRQ-less xHCI transfer timing and can tip a marginal device into
/// never enumerating. The NIC's link autonegotiates during enumeration, but the
/// first frame goes out only once the bus walk is done (armSending, called from
/// the entry root).
var sending_armed = false;

/// Begin an async bind. The NIC must already be claimed (nic.init). Returns to the
/// caller immediately; the lease is committed later, from pump() — but no frame is
/// sent until armSending() (after USB enumeration). See `sending_armed`.
pub fn start() void {
    xid = @as(u32, @truncate(timer.now())) | 0x1000_0000;
    got_reply = false;
    in_progress = true; // gates net.zig's port-68 / broadcast-dst RX accommodations
    state = .await_link;
    next_tx_ms = 0;
}

/// Allow the async bind to start sending. Called once USB enumeration is done, so
/// the bind's DISCOVER never contends with the bus walk. The lease then typically
/// binds during GSP boot, before the first present's cadence window.
pub fn armSending() void {
    sending_armed = true;
}

/// True once a lease is committed (async OR blocking). net.isUp() reads this.
pub fn isBound() bool {
    return state == .bound;
}

/// Advance the async bind by at most one bounded step. Non-blocking; safe to call
/// at the session-loop rate. A reply that arrived in this iteration's RX drain is
/// already in `reply`/`got_reply`, so it is acted on the same tick.
pub fn pump() void {
    if (!sending_armed) return; // no frames on the wire until USB enumeration is done
    switch (state) {
        .idle, .bound => return,
        .await_link => {
            // Wait for carrier with NO send and NO spin: a DISCOVER before autoneg
            // completes is lost, and each session-loop tick simply re-checks. The
            // instant the PHY reports link, send the first DISCOVER.
            if (!nic.linkUp()) return;
            sendPhase(buildDiscover);
            state = .discovering;
        },
        .discovering => {
            if (takeReply(DHCPOFFER)) {
                captureOfferFields();
                net.dbg("dhcp: OFFER received (async)\n");
                sendPhase(buildRequest);
                state = .requesting;
            } else retransmit(buildDiscover);
        },
        .requesting => {
            if (takeReply(DHCPACK)) {
                if (commitAck()) {
                    state = .bound;
                    in_progress = false;
                    net.dbg("dhcp: bound (async)\n");
                } else {
                    // ACK with no address — restart the whole bind from a fresh xid.
                    start();
                }
            } else retransmit(buildRequest);
        },
    }
}

/// Broadcast one phase message and arm the retransmit timer.
fn sendPhase(build: *const fn (out: []u8) usize) void {
    var buf: [400]u8 = undefined;
    got_reply = false;
    const len = build(&buf);
    _ = net.sendBroadcastUdp(CLIENT_PORT, SERVER_PORT, buf[0..len]);
    next_tx_ms = timer.millis() + RETX_MS;
}

/// Re-send the current phase message once the retransmit timer expires (a lost
/// broadcast, or the server was not ready). Unbounded by design: a background bind
/// must keep trying — the machine is unreachable until it succeeds.
fn retransmit(build: *const fn (out: []u8) usize) void {
    if (timer.millis() < next_tx_ms) return;
    // Carrier can drop mid-bind (cable, switch reconfigure); fall back to waiting.
    if (!nic.linkUp()) {
        state = .await_link;
        return;
    }
    sendPhase(build);
}

/// Consume a reply of the wanted type if one arrived. A NAK restarts the bind.
fn takeReply(want: u8) bool {
    if (!got_reply) return false;
    got_reply = false;
    const mt = dhcp_wire.parseOptions(reply[0..reply_len]).msg_type orelse return false;
    if (mt == DHCPNAK) {
        net.dbg("dhcp: NAK (async) — restarting bind\n");
        start();
        return false;
    }
    return mt == want;
}
