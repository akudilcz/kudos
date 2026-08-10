//! The hub of the network: Ethernet, ARP, IPv4 and ICMP, the receive demux, and the
//! send path that everything above shares.
//!
//! A frame arrives, and this file decides who it belongs to: an ARP query it answers
//! itself, a ping it echoes, a TCP segment it hands to tcp.zig, a datagram it routes to
//! whoever claimed that UDP port. Going the other way, everything that sends builds its
//! payload into the shared staging buffer here and calls `sendIp`.
//!
//! The parsing this depends on is NOT here — it is in wire.zig, which is pure and
//! host-tested, because every validation guard in it stops a panic that any machine on
//! the LAN could trigger by sending one malformed frame.

const std = @import("std");
const wire = @import("wire.zig");
const netown = @import("netown.zig");
const nic = @import("../nic/nic.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const cfg = @import("config.zig");
const klog = @import("../../../kernel/debug/klog.zig");
const gate = @import("../../../kernel/debug/gate.zig");
const udp = @import("udp.zig");
const tcp = @import("tcp.zig");
const http = @import("http.zig");
const dhcp = @import("dhcp.zig");
const sched = @import("../../../kernel/sched/sched.zig");
const http_wire = @import("http_wire.zig");
const fetchjob = @import("fetchjob.zig");
const job = @import("job"); // the shared named module (jobs.zig + fetchjob.zig too)
const jobs = @import("../../../kernel/sched/jobs.zig");

pub const ETH_ARP = 0x0806;
pub const ETH_IP = 0x0800;
// IP protocol numbers and IP/UDP header sizes are owned by the pure wire.zig
// (like the byte-order helpers below) — re-exported, never re-spelled.
pub const PROTO_ICMP = wire.PROTO_ICMP;
pub const PROTO_TCP = wire.PROTO_TCP;
pub const PROTO_UDP = wire.PROTO_UDP;
pub const IP_HLEN = wire.IP_HLEN;
pub const UDP_HLEN = wire.UDP_HLEN;

// On-wire header sizes (bytes). Single source of truth for the offset arithmetic
// in this module and in udp.zig / tcp.zig — referenced, never re-spelled inline.
// Ethernet II: dst(6) + src(6) + ethertype(2). The number itself lives in the
// network contract, which the guest bridge above this layer sizes from too.
pub const ETH_HLEN = inet.ETHER_HEADER_BYTES;
pub const TCP_HLEN = 20; // TCP header with no options
pub const ETH_IP_HLEN = ETH_HLEN + IP_HLEN; // start of the transport payload (34)

var present = false;
// Staging-buffer size for a single outgoing frame: one standard (non-jumbo)
// Ethernet frame plus headroom. Both the data and control paths stage into a
// buffer this size before handing it to the NIC.
const FRAME_BUF = 2048;

// Most RX frames processed in one pump() call. pump() runs inside the system
// task's render loop, so its per-call work is bounded to protect the 60 Hz frame budget
// (PERF-003/007): one RX ring's worth is high throughput, and anything still
// queued is taken on the very next pump. A plain cap — no yield inside the render
// path, which would delay the render() that follows pump() in the same loop.
const MAX_DRAIN_PER_PUMP: usize = 32;
var txpkt: [FRAME_BUF]u8 = undefined; // data path (IP/TCP/UDP we originate)
var ctrlpkt: [FRAME_BUF]u8 = undefined; // control path (ARP/ICMP), so a mid-send ARP
// resolution cannot clobber a half-built data packet in txpkt.

// ── Who may drive the stack (spec NET-018) ───────────────────────────────────
//
// EVERY global in this file and in tcp.zig — txpkt, the ARP cache, the one TCP
// connection, and the NIC's single RX staging buffer — is written without a
// lock, because the stack was built for one driver and its comments still say
// so. That stopped being true when the system task and the command worker both
// became floating tasks: `net.pump()` runs from the session loop AND from
// `tcp.pumpUntil` inside a fetch, so two cores could poll the NIC at once. The
// second overwrote the frame the first was still parsing, `recv_buf` took a
// splice of two segments, and kudos ACKed bytes it had never correctly stored.
// The peer therefore never retransmitted, and the corruption surfaced far away
// — as a TLS record that would not authenticate, or as a fault that retired the
// system task's core and took the desktop with it.
//
// The rule is now explicit: a task CLAIMS the stack for the length of an
// operation, and everyone else leaves it alone until it is released. Claiming
// is a try, never a wait — the claimant is the only one who pumps while it
// holds the stack, so a blocked caller could not be woken by anyone else
// anyway, and a spinning render loop is the thing this exists to prevent.
var stack_holder: ?*anyopaque = null;

/// How deep we are inside `pump()`. Non-zero above 1 means a send re-entered the
/// receive path to resolve an address; the tail-of-pump sends run at depth 1
/// only, so an inner pump can never transmit over a frame an outer one staged.
var pump_depth: usize = 0;

/// This caller's identity. Null before the scheduler exists (the boot stack is
/// then the single thread of control and owns the stack by default), which the
/// claim/skip rules below treat as "nobody else can be running".
///
/// The `schedulerLive` guard is NOT optional, and omitting it cost a boot:
/// `currentTask` masks interrupts and reads per-CPU state, and this is reached
/// from the trace path — which runs from the very first klog line, long before
/// per-CPU state exists. The machine came up mute, with no trace to say why.
/// `sched.setActivity` guards the same call for the same reason.
fn me() ?*anyopaque {
    if (!sched.schedulerLive()) return null;
    return @ptrCast(sched.currentTask());
}

/// Take the stack for this task, or report that someone else has it. The holder
/// must `releaseStack` on every path out, including error paths. The policy is
/// netown's; this adds only the atomic exchange.
pub fn claimStack() bool {
    const task = me();
    if (!netown.mayClaim(@atomicLoad(?*anyopaque, &stack_holder, .acquire), task)) return false;
    const t = task orelse return true; // no scheduler: one thread of control
    return @cmpxchgStrong(?*anyopaque, &stack_holder, null, t, .acq_rel, .acquire) == null;
}

pub fn releaseStack() void {
    @atomicStore(?*anyopaque, &stack_holder, null, .release);
}

/// True when ANOTHER task is driving the stack, so this one must not touch it.
/// The steady loops test this and skip — they render instead of racing, which
/// is why a request no longer stops the desktop.
pub fn stackHeldByOther() bool {
    return netown.mustSkip(@atomicLoad(?*anyopaque, &stack_holder, .acquire), me());
}
/// Emit `s` to klog only when `.net` logging is enabled.
pub fn dbg(s: []const u8) void {
    if (gate.on(.net)) klog.puts(s);
}
/// Emit `s` then hex `v` (newline-terminated), only when `.net` is enabled.
pub fn dbgx(s: []const u8, v: u64) void {
    if (gate.on(.net)) {
        klog.puts(s);
        klog.putHex(v);
        klog.putc('\n');
    }
}

/// Bring the stack up: claim a NIC, latch our MAC, then acquire an address via
/// DHCP. Returns false (and marks the stack down) if either step fails — there is
/// no static fallback, so a later fetch fails loudly rather than on a phantom LAN.
pub fn init() bool {
    // IDEMPOTENT: if we already hold a lease, change NOTHING.
    //
    // The network is up before the shell exists on any netbooted run — netdebug and KMR1
    // both ride on it — and the `net` command brings the stack up lazily. Without this
    // guard that resets the NIC and re-runs DHCP underneath the live link. DHCP DISCOVER
    // is a broadcast and can be lost, so a failed second round drops `present`, the
    // address is gone, and the machine is unreachable: no ARP, no ping, no remote reboot.
    if (present) return true;

    present = nic.init();
    if (!present) return false;
    cfg.our_mac = nic.macAddr();
    // Learn our address via DHCP before anything tries to send.
    // No static fallback: a failed lease marks the network down so fetch fails loud.
    if (!dhcp.configure()) {
        klog.puts("net: DHCP FAILED -- no address (unreachable: no ARP, no ping, no KMR1)\n");
        present = false;
        return false;
    }
    return true;
}

/// Claim the NIC and KICK OFF an async DHCP bind, returning immediately — the lease
/// is committed later, from pump() in the session loop (dhcp.pump). This is the
/// normal boot path: it takes the ~13 s DHCP wait off the critical path so the
/// desktop shows at the first GPU present instead of waiting for a lease. Returns
/// false only if no NIC is present (then there is nothing to bind and never will
/// be). Idempotent: a second call while a lease is already up is a no-op.
pub fn startAsync() bool {
    if (present and dhcp.isBound()) return true;
    if (!present) {
        present = nic.init();
        if (!present) return false;
        cfg.our_mac = nic.macAddr();
    }
    dhcp.start();
    return true;
}

/// Allow the async DHCP bind to start sending (see dhcp.armSending). Called by the
/// boot orchestration once USB enumeration is finished, so no DHCP frame contends
/// with the bus walk. Harmless if a lease is already up or no async bind is running.
pub fn armDhcp() void {
    dhcp.armSending();
}

/// True once a DHCP lease is committed (by either the blocking init() or the async
/// bind). Callers use it to mean "the network is usable", so it must track the
/// LEASE, not merely that a NIC was claimed.
pub fn isUp() bool {
    return dhcp.isBound();
}

/// Called from every blocking network wait (tcp.connect/send/pumpUntil), so a
/// long transfer never starves the debug channel. `net.pump()` alone moves TCP
/// bytes but does NOT drain netdebug output or service KMR1 (that is
/// fileserv.service) — so a multi-second fetch would otherwise go silent and stop
/// answering remote status/reboot, looking exactly like a wedge. main wires this
/// to netdebug.drain + fileserv.service; the net stack cannot name those higher
/// layers, so it reaches them through this hook (same pattern as reboot.flush_hook).
pub var wait_hook: ?*const fn () void = null;

/// Run the wait-time keepalive if one is installed. Called from the blocking
/// loops right after `net.pump()`.
pub inline fn serviceDuringWait() void {
    if (wait_hook) |h| h();
}

/// Print the leased address config (our_ip / gateway / dns_server) to klog.
/// Called from main after a successful init so the lease is visible on the diag
/// console. Reuses the dotted-quad print idiom from udp.zig's DNS debug.
pub fn logConfig() void {
    klog.puts("ip ");
    printIp(cfg.our_ip);
    klog.puts(" gw ");
    printIp(cfg.gateway);
    klog.puts(" dns ");
    printIp(cfg.dns_server);
    klog.putc('\n');
}

/// Print an IPv4 address as a dotted quad ("a.b.c.d") to klog.
fn printIp(ip: [4]u8) void {
    inline for (0..4) |k| {
        printDec(ip[k]);
        if (k < 3) klog.putc('.');
    }
}

/// Print a byte as decimal (0..255) for human-readable dotted-quad addresses.
fn printDec(v: u8) void {
    if (v >= 100) klog.putc('0' + v / 100);
    if (v >= 10) klog.putc('0' + (v / 10) % 10);
    klog.putc('0' + v % 10);
}

/// The transport payload region of the shared TX packet (after Ethernet+IP).
/// udp/tcp write their segment here, then call sendIp.
pub fn txPayload() []u8 {
    return txpkt[ETH_IP_HLEN..];
}

// ---- byte-order helpers ----
// Network byte order is big-endian; these are the single source of truth for
// on-wire 16/32-bit field access across net/udp/tcp/dhcp.
// On-wire helpers are owned by the pure, host-tested `wire.zig` (single source of
// truth). Re-exported here so the udp/tcp/dhcp builders and the
// `net` command keep calling them as `net.wbe16` etc.
pub const wbe16 = wire.wbe16;
pub const wbe32 = wire.wbe32;
pub const rbe16 = wire.rbe16;
pub const rbe32 = wire.rbe32;
pub const checksum16 = wire.checksum16;
pub const ipEq = wire.ipEq;
pub const parseIp = wire.parseIp;
pub const buildUdp = wire.buildUdp;

/// Resolve `host` — a dotted-quad literal or a DNS name — to an IPv4 address.
/// A literal address is not a name: resolving "192.168.20.30" must not put a
/// DNS query on the wire (and must still work when the DNS server is the thing
/// that is broken). The single home of the literal-or-DNS rule; every fetch
/// path (http, the background GET, the app seam) resolves through it.
pub fn resolveHost(host: []const u8) ?[4]u8 {
    if (wire.parseIp(host)) |ip| return ip;
    return udp.dnsResolve(host);
}

/// True if `ip` shares our subnet (network portion equal under our netmask),
/// i.e. it is directly reachable rather than via the gateway.
fn sameSubnet(ip: [4]u8) bool {
    for (0..4) |i| {
        if ((ip[i] & cfg.netmask[i]) != (cfg.our_ip[i] & cfg.netmask[i])) return false;
    }
    return true;
}

// ---- ARP ----
const ArpEntry = struct { ip: [4]u8, mac: [6]u8 };
// ARP cache depth. A handful of entries covers this host's working set (gateway
// + a few peers); the cache fills then stops growing (no eviction needed here).
const ARP_CACHE_SIZE = 8;
// How long resolveMac pumps RX waiting for an ARP reply before giving up (ms).
const ARP_RESOLVE_TIMEOUT_MS: u64 = 1000;
var arp_cache: [ARP_CACHE_SIZE]ArpEntry = undefined;
var arp_count: usize = 0;
const ETH_BROADCAST = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

// ARP-over-Ethernet/IPv4 fixed fields (RFC 826) and the packet size.
const ARP_HTYPE_ETH = 1;
const ARP_HLEN = 6; // hardware (MAC) address length
const ARP_PLEN = 4; // protocol (IPv4) address length
const ARP_REQUEST = 1;
const ARP_REPLY = 2;
const ARP_LEN = 28; // htype/ptype/hlen/plen/oper + 2×(MAC+IP)

/// Build an ARP packet body into `p` (the bytes after the Ethernet header).
/// Sender is always us; `target_mac`/`target_ip` are the request/reply target
/// (request leaves the target MAC zeroed). Single builder for both opers.
fn buildArp(p: []u8, oper: u16, target_mac: [6]u8, target_ip: [4]u8) void {
    wbe16(p[0..2], ARP_HTYPE_ETH);
    wbe16(p[2..4], ETH_IP);
    p[4] = ARP_HLEN;
    p[5] = ARP_PLEN;
    wbe16(p[6..8], oper);
    @memcpy(p[8..14], &cfg.our_mac);
    @memcpy(p[14..18], &cfg.our_ip);
    @memcpy(p[18..24], &target_mac);
    @memcpy(p[24..28], &target_ip);
}

/// Is `ip` already in the ARP cache? Lets a caller choose unicast WITHOUT risking the
/// blocking resolve inside sendIp. The trace channel needs exactly this: it must never
/// stall a boot to resolve an address, and it must never be the thing that triggers ARP.
pub fn arpKnown(ip: [4]u8) bool {
    return arpLookup(ip) != null;
}

/// The cached MAC for `ip`, or null if we have not resolved it yet.
fn arpLookup(ip: [4]u8) ?[6]u8 {
    for (arp_cache[0..arp_count]) |e| {
        if (ipEq(e.ip, ip)) return e.mac;
    }
    return null;
}
/// Cache `ip`->`mac`, updating an existing entry, appending while there is
/// room, and evicting round-robin once the fixed cache is full. A fresh
/// resolution must never be dropped in favor of stale entries: dropping it
/// would leave that IP (e.g. the gateway) unresolvable until reboot.
var arp_evict: usize = 0;
fn arpInsert(ip: [4]u8, mac: [6]u8) void {
    for (arp_cache[0..arp_count]) |*e| {
        if (ipEq(e.ip, ip)) {
            e.mac = mac;
            return;
        }
    }
    if (arp_count < arp_cache.len) {
        arp_cache[arp_count] = .{ .ip = ip, .mac = mac };
        arp_count += 1;
    } else {
        arp_cache[arp_evict] = .{ .ip = ip, .mac = mac };
        arp_evict = (arp_evict + 1) % arp_cache.len;
    }
}

/// Fill the Ethernet header in `buf` and transmit `ETH_HLEN + payload_len` bytes.
fn sendFrame(buf: []u8, dst: [6]u8, ethertype: u16, payload_len: usize) void {
    @memcpy(buf[0..6], &dst);
    @memcpy(buf[6..12], &cfg.our_mac);
    wbe16(buf[12..14], ethertype);
    const frame = buf[0 .. ETH_HLEN + payload_len];
    // This host is a bridge port like any other. A frame it addresses to a
    // guest has to be switched there and NOT sent, because the wire's switch
    // will not reflect it back down the port it arrived on — without this, an
    // ARP reply to a guest, and every packet after it, would leave and never
    // arrive. Broadcast is copied to the guests and still goes out (`offer`
    // answers false for it), exactly as on the receive side.
    if (bridge) |b| {
        if (b.offer(b.ctx, null, frame)) return;
    }
    nic.send(frame);
}

/// Broadcast an ARP request asking who owns `target`.
fn sendArpRequest(target: [4]u8) void {
    buildArp(ctrlpkt[ETH_HLEN..], ARP_REQUEST, [_]u8{0} ** 6, target);
    sendFrame(&ctrlpkt, ETH_BROADCAST, ETH_ARP, ARP_LEN);
}

/// Handle an inbound ARP packet: cache the sender's IP->MAC when the packet
/// addresses US — a reply to our request, or a request for our IP (that peer is
/// about to talk to us) — and answer requests targeting our IP with our MAC.
/// Senders of unrelated broadcast who-has requests are NOT cached: on a busy
/// LAN they would fill the small cache with strangers and crowd out the entries
/// we actually route through (the gateway).
fn handleArp(p: []const u8) void {
    if (p.len < ARP_LEN) return;
    const oper = rbe16(p[6..8]);
    var sip: [4]u8 = undefined;
    var smac: [6]u8 = undefined;
    var tip: [4]u8 = undefined;
    @memcpy(&smac, p[8..14]);
    @memcpy(&sip, p[14..18]);
    @memcpy(&tip, p[24..28]);
    if (ipEq(tip, cfg.our_ip)) {
        arpInsert(sip, smac);
        if (oper == ARP_REQUEST) {
            buildArp(ctrlpkt[ETH_HLEN..], ARP_REPLY, smac, sip);
            sendFrame(&ctrlpkt, smac, ETH_ARP, ARP_LEN);
        }
    }
}

/// Resolve `ip` to a MAC: cache hit, else broadcast an ARP request and pump RX
/// until the reply lands or a 1 s deadline expires (null on timeout).
fn resolveMac(ip: [4]u8) ?[6]u8 {
    if (arpLookup(ip)) |m| return m;
    const deadline = timer.millis() + ARP_RESOLVE_TIMEOUT_MS;
    sendArpRequest(ip);
    dbgx("arp request sent, ip0=", ip[0]);
    while (timer.millis() < deadline) {
        pump();
        if (arpLookup(ip)) |m| {
            dbg("arp resolved\n");
            return m;
        }
        sched.waitYield(); // SMP: yield to core 0's system task between polls
    }
    dbg("arp FAILED\n");
    return null;
}

// ---- IPv4 ----
var ip_id: u16 = 1;

/// Write a 20-byte IPv4 header into `h` (no options): version 4 / IHL 5, total
/// length, an auto-incrementing id, TTL 64, the given protocol, source and
/// destination addresses, and the header checksum. The single place the IPv4
/// header is laid out — both the normal send path and the DHCP broadcast path use
/// it (they differ only in src/dst).
fn buildIpHeader(h: []u8, src: [4]u8, dst: [4]u8, proto: u8, payload_len: usize) void {
    h[0] = 0x45; // version 4, IHL 5
    h[1] = 0;
    wbe16(h[2..4], @intCast(IP_HLEN + payload_len));
    wbe16(h[4..6], ip_id);
    ip_id +%= 1;
    wbe16(h[6..8], 0); // flags/frag
    h[8] = 64; // TTL
    h[9] = proto;
    wbe16(h[10..12], 0); // checksum placeholder
    @memcpy(h[12..16], &src);
    @memcpy(h[16..20], &dst);
    wbe16(h[10..12], checksum16(h, 0));
}

/// The on-link next hop for `dst` — the single source of truth for IPv4 routing
/// (sendIp + handleIcmp): dst itself when it shares our subnet, else the gateway,
/// and null when dst is off-subnet and we HAVE no gateway (a lease may legally
/// omit one; see dhcp.zig's commit). Null rather than 0.0.0.0 so the caller fails
/// immediately: handing 0.0.0.0 to resolveMac would ARP for it and stall a full
/// second per send, which inside a heartbeat loop turns a routing gap into a
/// liveness failure.
fn nextHop(dst: [4]u8) ?[4]u8 {
    if (sameSubnet(dst)) return dst;
    if (cfg.gateway[0] == 0 and cfg.gateway[1] == 0 and cfg.gateway[2] == 0 and cfg.gateway[3] == 0) {
        dbg("net: no gateway — cannot reach off-subnet destination\n");
        return null;
    }
    return cfg.gateway;
}

/// Build the IPv4 header and send the transport payload already placed at
/// txPayload(). Returns false if the next hop can't be resolved.
pub fn sendIp(dst: [4]u8, proto: u8, payload_len: usize) bool {
    // The payload is already staged in the SHARED txpkt. A task that does not
    // hold the stack must not send it — netdebug's trace and the KMR1 reply both
    // reach here from the render loop, and either one landing between another
    // task's stage and its send puts a frame on the wire whose header and body
    // come from different packets. The caller counts the refusal and retries.
    if (stackHeldByOther()) return false;
    const hop = nextHop(dst) orelse return false;
    const mac = resolveMac(hop) orelse return false;

    buildIpHeader(txpkt[ETH_HLEN..ETH_IP_HLEN], cfg.our_ip, dst, proto, payload_len);
    sendFrame(&txpkt, mac, ETH_IP, IP_HLEN + payload_len);
    return true;
}

/// UNICAST a UDP datagram to `dst`. Same staging as sendBroadcastUdp, but addressed —
/// and 802.11 acknowledges and retries a unicast frame while giving a broadcast one
/// neither, so this is what the trace uses once it knows who is listening
/// (netdebug.collector).
///
/// Returns false if the next hop cannot be resolved (no lease, no ARP) — the caller
/// falls back to broadcast rather than losing the line.
pub fn sendUdpTo(dst: [4]u8, src_port: u16, dst_port: u16, payload: []const u8) bool {
    if (!present) return false;
    // Checked BEFORE staging, not just in sendIp: buildUdp writes into the shared
    // txpkt, so a refusal after the write has already corrupted whatever the
    // stack's holder had staged there.
    if (stackHeldByOther()) return false;
    const len = wire.buildUdp(txpkt[ETH_IP_HLEN..], src_port, dst_port, payload);
    return sendIp(dst, PROTO_UDP, len);
}

/// Send a UDP datagram from 0.0.0.0:src_port to 255.255.255.255:dst_port as an Ethernet
/// broadcast, bypassing ARP and the our_ip source stamp — so it works before we own an
/// address. Used by DHCP (RFC 2131) and by the trace before a collector is known.
/// Returns true once posted.
pub fn sendBroadcastUdp(src_port: u16, dst_port: u16, payload: []const u8) bool {
    if (stackHeldByOther()) return false; // shared txpkt — see sendUdpTo
    // UDP header + payload into the transport region (the shared wire.buildUdp).
    const len = wire.buildUdp(txpkt[ETH_IP_HLEN..], src_port, dst_port, payload);

    // IPv4 header: src 0.0.0.0, dst 255.255.255.255, proto UDP.
    buildIpHeader(txpkt[ETH_HLEN..ETH_IP_HLEN], .{ 0, 0, 0, 0 }, wire.IP_BROADCAST, PROTO_UDP, len);

    sendFrame(&txpkt, ETH_BROADCAST, ETH_IP, IP_HLEN + len);
    return true;
}

/// TCP/UDP pseudo-header sum for transport checksums.
pub fn pseudoSum(dst: [4]u8, proto: u8, seg_len: usize) u32 {
    var sum: u32 = 0;
    sum += rbe16(cfg.our_ip[0..2]);
    sum += rbe16(cfg.our_ip[2..4]);
    sum += rbe16(dst[0..2]);
    sum += rbe16(dst[2..4]);
    sum += proto;
    sum += @intCast(seg_len);
    return sum;
}

// ---- ICMP echo (RFC 792) ----
const ICMP_ECHO_REQUEST = 8;
const ICMP_ECHO_REPLY = 0;
const ICMP_ID: u16 = 0x4B55; // 'KU' — our fixed echo identifier
var ping_seq: u16 = 0; // sequence of the in-flight echo request
var ping_reply = false; // a reply matching (ICMP_ID, ping_seq) arrived

/// Handle an inbound ICMP message from `src`: answer an echo request with a
/// (length-bounded) echo reply, or note an echo reply matching our in-flight ping.
fn handleIcmp(src: [4]u8, p: []const u8) void {
    if (p.len < 8) return;
    switch (p[0]) {
        ICMP_ECHO_REQUEST => {
            // Reply, echoing the message with type flipped to 0.
            //
            // The reply is built in ctrlpkt, NOT txpkt: this handler runs from
            // pump(), which nests inside resolveMac() while a caller's data
            // segment (SYN, DNS query, echo request) sits fully staged in txpkt
            // waiting for sendIp — building here in txpkt would clobber that
            // in-flight packet (the exact hazard ctrlpkt exists to prevent).
            // The next hop must already be cached. Resolving here would be two
            // defects at once: resolveMac pumps RX, and `p` is a slice of the
            // NIC's single staging buffer, so the refill would make the reply
            // echo another packet's bytes back to the sender; and it waits up to
            // ARP_RESOLVE_TIMEOUT_MS inside the 60 Hz session loop this handler
            // runs in. On a miss, request the address and drop this echo — the
            // peer's retry finds a warm cache.
            const hop = nextHop(src) orelse return;
            const mac = arpLookup(hop) orelse {
                sendArpRequest(hop);
                return;
            };
            // Cap the echoed length to the transmit buffer's payload room: `p`
            // is the inbound ICMP message (attacker-sized, up to a full frame).
            // RFC 792 asks us to echo the data, but a bare-metal responder must
            // bound it to its TX buffer or a crafted oversized ping overruns
            // the buffer.
            const n = wire.icmpEchoReply(ctrlpkt[ETH_IP_HLEN..], p) orelse return;
            buildIpHeader(ctrlpkt[ETH_HLEN..ETH_IP_HLEN], cfg.our_ip, src, PROTO_ICMP, n);
            sendFrame(&ctrlpkt, mac, ETH_IP, IP_HLEN + n);
        },
        ICMP_ECHO_REPLY => {
            // Match a reply to our in-flight ping by identifier + sequence.
            if (wire.icmpEchoReplyMatches(p, ICMP_ID, ping_seq)) ping_reply = true;
        },
        else => {},
    }
}

/// Send one ICMP echo request to `dst` and poll for the matching reply up to
/// `timeout_ms`. Returns the round-trip time in milliseconds, or null on timeout.
/// Used by `net ping`.
pub fn ping(dst: [4]u8, timeout_ms: u64) ?u64 {
    ping_seq +%= 1;
    ping_reply = false;

    // Echo request: type/code/checksum/id/seq + an 8-byte data payload.
    const data_len = 8;
    const len = 8 + data_len;
    const m = txpkt[ETH_IP_HLEN..];
    m[0] = ICMP_ECHO_REQUEST;
    m[1] = 0; // code
    wbe16(m[2..4], 0); // checksum placeholder
    wbe16(m[4..6], ICMP_ID);
    wbe16(m[6..8], ping_seq);
    inline for (0..data_len) |i| m[8 + i] = @intCast('a' + i);
    wbe16(m[2..4], checksum16(m[0..len], 0));

    const start = timer.millis();
    if (!sendIp(dst, PROTO_ICMP, len)) return null;

    const deadline = start + timeout_ms;
    while (timer.millis() < deadline) {
        pump();
        if (ping_reply) return timer.millis() - start;
        sched.waitYield(); // SMP: yield to core 0's system task between polls
    }
    return null;
}

// ---- dispatch ----
/// Validate an inbound IPv4 packet (destined to us, or a DHCP broadcast while
/// binding), then dispatch its payload to ICMP/UDP/TCP by protocol number.
/// A UDP port claimed by something above the stack, and the code that wants its
/// datagrams.
pub const UdpHandler = *const fn (src: [4]u8, payload: []const u8) void;

/// Small and fixed: the ports claimed this way are compiled-in services (the remote
/// debug link is the only one today), not something a program opens at runtime. If this
/// fills up, that is a design change, not a resize.
const MAX_LISTENERS = 4;
var listeners: [MAX_LISTENERS]struct { port: u16, handler: UdpHandler } = undefined;
var listener_n: usize = 0;

/// The bridge port a frame entered from, when that port is a guest — null for
/// the wire and for this host's own stack. Which guest is the only thing
/// forwarding needs from a frame's origin, because the one rule that depends on
/// it is that no frame is ever sent back out the port it came in on, and
/// neither non-guest port is one the guests' side can send back to. The stack
/// treats a guest port as an opaque token: the numbering is the hypervisor's.
pub const Port = ?usize;

/// A guest NIC bridge: kudos' hypervisor shares the one physical NIC with its
/// guests at layer 2, and this is the whole surface the stack sees of that.
/// `offer` is shown every frame entering the bridge, from either side, BEFORE
/// ethertype dispatch; it copies the frame to whichever guests it belongs to
/// and returns true when the frame is wholly theirs (a frame addressed to a
/// guest is not kudos' to parse). Broadcast comes back false — it belongs to
/// the guests AND to this stack. `poll` yields the next guest-transmitted frame
/// into `buf` and reports its port. The same rules as every RX-path handler:
/// never block, never re-enter pump().
pub const Bridge = struct {
    ctx: *anyopaque,
    offer: *const fn (ctx: *anyopaque, from: Port, frame: []const u8) bool,
    poll: *const fn (ctx: *anyopaque, buf: []u8, from: *Port) ?usize,
};

/// The buffer `Bridge.poll` fills — one whole Ethernet frame, the contract's
/// own ceiling.
pub const MAX_BRIDGE_FRAME = inet.ETHER_FRAME_MAX;

var bridge: ?Bridge = null;

/// Connect the guest bridge (same announce-yourself shape as `listenUdp`: the
/// stack stays ignorant of the hypervisor above it). One bridge; connecting
/// again replaces it — there is one guest subsystem.
pub fn connectBridge(b: Bridge) void {
    bridge = b;
}

/// Claim a UDP port: datagrams addressed to it go to `handler` instead of the ordinary
/// receive path.
///
/// This exists so the stack does not have to know who its users are. The alternative is
/// for the demux to name each service and import it, which points the bottom of the
/// network at a diagnostic tool sitting on top of it — a cycle, and backwards. A service
/// announces itself; the stack stays ignorant of what it is carrying.
pub fn listenUdp(port: u16, handler: UdpHandler) void {
    if (listener_n == listeners.len) {
        klog.puts("net: UDP listener table full — port not claimed (grow MAX_LISTENERS)\n");
        return;
    }
    listeners[listener_n] = .{ .port = port, .handler = handler };
    listener_n += 1;
}

fn handleIp(frame_payload: []const u8) void {
    // The VALIDATION lives in wire.classifyIp — pure and host-tested, because every
    // guard in it stops a remotely-triggerable ring-0 panic or a data leak, and any
    // host on the LAN can send the frame that trips one. That is not something to
    // leave in a file no test can compile.
    const pkt = wire.classifyIp(frame_payload, cfg.our_ip, dhcp.active()) orelse return;
    const src = pkt.src;
    const payload = pkt.payload;
    switch (pkt.proto) {
        PROTO_ICMP => handleIcmp(src, payload),
        PROTO_UDP => {
            if (payload.len < UDP_HLEN) return;
            const dport = rbe16(payload[2..4]);
            // DHCP replies (server 67 → client 68) go to the lease machinery, but only
            // while a lease is actually being negotiated — outside a transaction that
            // port is nobody's, and udp.zig stays focused on DNS and HTTP receive.
            if (dhcp.active() and dport == dhcp.CLIENT_PORT) {
                dhcp.handleReply(payload[UDP_HLEN..]);
                return;
            }
            for (listeners[0..listener_n]) |l| {
                if (l.port == dport) {
                    l.handler(src, payload);
                    return;
                }
            }
            udp.handleUdp(src, payload);
        },
        PROTO_TCP => tcp.handleTcp(src, payload),
        else => {},
    }
}

/// Last tx_dropped value reported, so pump logs only on CHANGE. While TX is
/// wedged the report itself is lost with everything else (harmless); the moment
/// TX recovers, the first pump ships the true total — the only post-mortem for a
/// silent gap in the stream.
var tx_dropped_reported: u64 = 0;

/// Dispatch one received Ethernet frame to the protocol that owns it. The one
/// body behind both of this host's ingress paths: the frames the NIC receives,
/// and the frames the bridge switches here from a guest.
fn dispatchFrame(frame: []const u8) void {
    if (frame.len < ETH_HLEN) return;
    const ethertype = rbe16(frame[12..14]);
    const payload = frame[ETH_HLEN..];
    switch (ethertype) {
        ETH_ARP => handleArp(payload),
        ETH_IP => handleIp(payload),
        else => {},
    }
}

/// What this host's bridge port makes of a frame's destination: `ours` alone,
/// `shared` with the wire (broadcast and multicast are everyone's), or
/// `elsewhere` — someone else's, which this stack must not parse. On the wire
/// side the NIC's receive filter answers this in hardware; a frame arriving
/// from a guest passes no hardware, so the same filter is spelled out here.
const HostPort = enum { ours, shared, elsewhere };
fn hostPort(frame: []const u8) HostPort {
    if (frame.len < ETH_HLEN) return .elsewhere;
    const dst = frame[inet.ETHER_DST_OFF..][0..inet.ETHER_ADDR_BYTES];
    if (dst[0] & inet.ETHER_GROUP_BIT != 0) return .shared;
    return if (std.mem.eql(u8, dst, &cfg.our_mac)) .ours else .elsewhere;
}

/// Read one frame from the NIC (if any) and dispatch it.
pub fn pump() void {
    // Another task is mid-request and owns every global this touches — the NIC's
    // staging buffer, the ARP cache, the TCP connection. Skipping is not a lost
    // pump: the holder pumps for both of us, and it is the only one that safely
    // can. Racing it here is what retired the system task's core.
    if (stackHeldByOther()) return;
    // Depth, because a send can legitimately re-enter this: `resolveMac` spins
    // the receive path waiting for an ARP reply, and it MUST make progress there
    // or the address never resolves. What must not happen is the inner pump
    // sending while an outer one has already staged a frame in the shared
    // txpkt — so the sends at the tail below run at depth 1 only.
    pump_depth += 1;
    defer pump_depth -= 1;
    const drops = nic.txDropped();
    if (drops != tx_dropped_reported) {
        tx_dropped_reported = drops;
        dbgx("net: tx_dropped=", drops);
    }
    // Drain up to MAX_DRAIN_PER_PUMP frames — a window-filling burst arrives as
    // many frames back-to-back, and processing ONE per pump() (pump runs once
    // per scheduler pass) capped intake at ~1 MSS / quantum and throttled every
    // large transfer. The bound is the point: pump() runs inside the system
    // task, which owns the 60 Hz compositor, so an UNBOUNDED drain under a
    // sustained flood would degrade rendering (PERF-007) and drop frames
    // (PERF-003). One ring's worth per pump is high throughput AND bounded
    // compositor time; the rest waits for the next pump (the very next
    // session-loop iteration).
    var drained: usize = 0;
    while (drained < MAX_DRAIN_PER_PUMP) : (drained += 1) {
        const frame = nic.poll() orelse break;
        // A guest's frame first: unicast to a guest MAC is not kudos' to parse,
        // and the bridge consuming it here is what keeps two IP stacks from
        // both answering. Broadcast comes back false — copied to the guests AND
        // dispatched below, because an ARP request is everyone's.
        if (bridge) |b| {
            if (b.offer(b.ctx, null, frame)) continue;
        }
        dispatchFrame(frame);
    }
    // The acknowledgement the drain owes the peer, sent HERE — outside the
    // receive dispatch (spec NET-019). Inside it, the send could resolve ARP,
    // and resolving spins the receive path for up to a second while the
    // compositor waits. Cumulative, so one send settles the whole drain.
    if (pump_depth == 1) tcp.serviceDeferredAck();
    // The guests' outbound frames, same per-pump bound for the same reason.
    // After the RX drain so a request the guest just answered goes out on the
    // tick it was made, and through the same single NIC everything else uses.
    if (bridge) |b| {
        var sent: usize = 0;
        var buf: [MAX_BRIDGE_FRAME]u8 = undefined;
        while (sent < MAX_DRAIN_PER_PUMP) : (sent += 1) {
            var from: Port = null;
            const len = b.poll(b.ctx, &buf, &from) orelse break;
            const frame = buf[0..len];
            // A guest's frame enters the bridge exactly as a wire frame does,
            // and has to be SWITCHED, not merely forwarded: an Ethernet switch
            // never reflects a frame back down the port it arrived on, so a
            // frame a guest addressed to kudos itself or to a sibling guest
            // would be sent out and never come back. Offer it to the other
            // guests first; what they wholly own goes no further.
            if (b.offer(b.ctx, from, frame)) continue;
            // Then this host's own port and the wire, as the frame's
            // destination decides between them.
            switch (hostPort(frame)) {
                .ours => dispatchFrame(frame),
                .shared => {
                    dispatchFrame(frame);
                    nic.send(frame);
                },
                .elsewhere => nic.send(frame),
            }
        }
    }
    // Drive the async DHCP bind (a no-op once bound or if it was never started).
    // Placed AFTER the RX dispatch so an OFFER/ACK that just landed is acted on
    // this same tick. This is what completes the lease in the background after the
    // desktop is already up — no spin anywhere on the boot path.
    dhcp.pump();
}

// ── inet.INet implementation (the application-facing seam) ───────────────────
// Apps ask the network four questions — am I up, what is my address, where does this
// name point, and fetch me this. Answering them means reaching across net/udp/tcp,
// which is exactly why the seam lives here at the group's top rather than in any one
// of those files.

const inet = @import("inet");

fn vtBringUp(_: *anyopaque) bool {
    return init();
}
fn vtIsUp(_: *anyopaque) bool {
    return isUp();
}
fn vtLease(_: *anyopaque) inet.Lease {
    return .{
        .mac = cfg.our_mac,
        .ip = cfg.our_ip,
        .netmask = cfg.netmask,
        .gateway = cfg.gateway,
        .dns = cfg.dns_server,
    };
}
fn vtResolve(_: *anyopaque, host: []const u8) ?[4]u8 {
    return resolveHost(host);
}
fn vtPing(_: *anyopaque, dst: [4]u8, timeout_ms: u64) ?u64 {
    return ping(dst, timeout_ms);
}
fn vtFetch(_: *anyopaque, a: std.mem.Allocator, url: []const u8) inet.FetchError![]u8 {
    // One HTTP client (http.zig) serves both schemes; the URL's scheme selects
    // plain TCP vs TLS beneath it.
    if (!claimStack()) return error.Busy;
    defer releaseStack();
    return http.request(a, .GET, url, &.{}, "");
}

// ── backgrounded GET (a job.zig cooperative task) ─────────────────────────────
// One at a time: there is one TCP connection system-wide, and the command that
// starts a fetch returns immediately, so the state must outlive it — static, not
// on the caller's stack. The job runs on the session loop (jobs.pump), stepping
// the FetchJob over tcp.zig while net.pump grows the receive buffer, so the
// download advances a chunk per frame and the render never stalls.
// Background-GET request-head capacity. Smaller than the foreground client's
// http_wire.MAX_REQUEST_HEAD on purpose: this head is GET + Host only (no
// caller headers ride the background path), and the buffer is a static that
// lives for the whole session.
const BG_REQUEST_HEAD = 1024;
var bg_busy: bool = false;
var bg_fj: fetchjob.FetchJob = undefined;
var bg_req: [BG_REQUEST_HEAD]u8 = undefined;
var bg_ip: [4]u8 = undefined;
var bg_port: u16 = 0;
var bg_a: std.mem.Allocator = undefined;
var bg_cb: ?inet.FetchDone = null;
var bg_cb_ctx: *anyopaque = undefined;
var bg_seam: u8 = 0; // a non-null ctx for the seam fns (they use the statics)

fn bgStart(_: *anyopaque) bool {
    tcp.beginRecv(bg_a);
    return tcp.connectStart(bg_ip, bg_port);
}
fn bgPoll(_: *anyopaque) fetchjob.ConnState {
    return switch (tcp.connectState()) {
        .established => .established,
        .refused => .failed,
        .connecting => .connecting,
    };
}
fn bgSend(_: *anyopaque, bytes: []const u8) bool {
    return tcp.send(bytes);
}
fn bgReceived(_: *anyopaque) []const u8 {
    return tcp.received();
}
fn bgReserve(_: *anyopaque, bytes: usize) bool {
    return tcp.reserveRecv(bytes);
}
fn bgClosed(_: *anyopaque) bool {
    return tcp.finished() or tcp.wasReset();
}
fn bgMillis(_: *anyopaque) u64 {
    return timer.millis();
}

fn bgFinish(_: *anyopaque, outcome: job.Step) void {
    const body: ?[]const u8 = if (outcome == .done) bg_fj.body else null;
    if (bg_cb) |cb| cb(bg_cb_ctx, body); // copies before we free the buffer
    tcp.close();
    bg_busy = false;
}

fn vtFetchBackground(_: *anyopaque, a: std.mem.Allocator, url: []const u8, cb_ctx: *anyopaque, on_done: inet.FetchDone) inet.FetchError!void {
    if (bg_busy) return error.Busy;
    if (!isUp()) return error.NoNetwork;
    const u = http_wire.parseUrl(url) catch return error.BadUrl;
    if (u.scheme == .https) return error.TlsFailed; // background HTTPS is a follow-on
    const ip = resolveHost(u.host) orelse return error.DnsFailed;
    const head = http_wire.buildRequestHead(&bg_req, "GET", u.host, u.path, &.{}, 0) catch return error.UrlTooLong;
    bg_ip = ip;
    bg_port = u.port;
    bg_a = a;
    bg_cb = on_done;
    bg_cb_ctx = cb_ctx;
    bg_fj = .{
        .t = .{ .ctx = &bg_seam, .start = bgStart, .poll = bgPoll, .send = bgSend, .received = bgReceived, .reserve = bgReserve, .closed = bgClosed },
        .clock = .{ .ctx = &bg_seam, .millis = bgMillis },
        .request = head,
    };
    if (!jobs.submit(.{ .ctx = &bg_fj, .step = fetchjob.FetchJob.step, .finish = bgFinish })) return error.Busy;
    bg_busy = true;
}

fn vtFetchProgress(_: *anyopaque) ?inet.FetchProgress {
    if (!bg_busy) return null;
    const p = bg_fj.progress();
    return .{ .received = p.received, .total = p.total };
}

fn vtPost(_: *anyopaque, a: std.mem.Allocator, url: []const u8, headers: []const inet.Header, body: []const u8) inet.FetchError![]u8 {
    // Same single client, POST verb: the caller's headers pass through verbatim
    // (NET-013); https URLs go over TLS transparently.
    if (!claimStack()) return error.Busy;
    defer releaseStack();
    return http.request(a, .POST, url, headers, body);
}

fn vtPostStream(_: *anyopaque, a: std.mem.Allocator, url: []const u8, headers: []const inet.Header, body: []const u8, sink: inet.BodySink) inet.FetchError!void {
    // Same single client, streaming delivery: decoded body bytes reach the
    // sink as they arrive (NET-014 — server-sent events).
    //
    // The claim covers the WHOLE request, handshake to last byte, because every
    // global the request touches — the connection, the receive buffer, the TX
    // staging — is shared and none of it is locked. Holding it for the duration
    // is what lets the render loop skip the stack instead of racing it, so the
    // desktop keeps drawing while the agent waits on the network (NET-018).
    if (!claimStack()) return error.Busy;
    defer releaseStack();
    return http.requestStream(a, .POST, url, headers, body, sink);
}

const net_vtable = inet.VTable{
    .bringUp = vtBringUp,
    .isUp = vtIsUp,
    .lease = vtLease,
    .resolve = vtResolve,
    .ping = vtPing,
    .fetch = vtFetch,
    .post = vtPost,
    .postStream = vtPostStream,
    .fetchBackground = vtFetchBackground,
    .fetchProgress = vtFetchProgress,
};
// A stable non-null context: the stack's state is module-global, so the vtable ignores
// this — but `undefined` would be UB to pass around even unused.
var net_ctx: u8 = 0;

/// Publish the stack through `iface/inet.zig` so apps can use the network without
/// naming a driver. Called once at boot, before any app runs.
pub fn publish() void {
    inet.instance = .{ .ctx = @ptrCast(&net_ctx), .vt = &net_vtable };
}
