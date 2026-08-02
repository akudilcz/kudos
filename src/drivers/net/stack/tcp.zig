//! TCP: one connection, in-order, blocking-poll. A raw byte-stream API
//! (connect/send/received/pumpUntil/close) that the one HTTP client (http.zig)
//! drives directly for plain requests and through the TLS session (tls.zig) for
//! https. Built on net's IP layer.

const std = @import("std");
const net = @import("net.zig");
const tcp_tx = @import("tcp_tx.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const sched = @import("../../../kernel/sched/sched.zig");

const State = enum { closed, syn_sent, established };
var state: State = .closed;
var local_port: u16 = 0;
var remote_ip: [4]u8 = undefined;
var remote_port: u16 = 0;
var snd_nxt: u32 = 0;
var rcv_nxt: u32 = 0;
var fin_recv = false;
var reset_recv = false;
// The peer's receive limits, learned from the SYN-ACK and every later segment:
// the MSS it advertised (bounds our segment size) and its currently advertised
// window (bounds how much we may have unacknowledged in flight). Fed to the send
// engine so outbound data is segmented and flow-controlled correctly.
var peer_mss: u16 = tcp_tx.DEFAULT_MSS;
var peer_window: u16 = 0;
// The send in progress, if any. `send()` sets this to its stack Sender so the RX
// path (handleTcp) can deliver the peer's ACKs of our data into it, then clears
// it. One connection system-wide, one send at a time — same single-owner model
// as the rest of this module's globals.
var active_sender: ?*tcp_tx.Sender = null;
// The receive buffer for the in-flight connection. OPTIONAL and nulled the
// moment the connection closes (the HTTP client's cleanup), so a late segment
// reaching handleTcp from an unrelated net.pump() caller (netdebug.drain /
// fileserv / an ARP/DNS wait) after that deinit finds `null` and drops the data
// instead of appending through a freed ArrayList — the `state == .closed` guard
// alone left `recv_buf` pointing at freed memory, one reorder from a UAF.
var recv_buf: ?std.array_list.Managed(u8) = null;

const FIN = 0x01;
const SYN = 0x02;
const RST = 0x04;
const PSH = 0x08;
const ACK = 0x10;

// Advertised receive window (bytes). We buffer the whole response in recv_buf
// (which grows on demand), so we advertise the largest window a 16-bit field can
// carry — there is no window scaling. 8 KiB throttled the peer to ~5 segments in
// flight, so throughput was 8 KiB / effective-RTT (the ACK cadence, which is the
// pump cadence): hundreds of KB/s on the loaded core-0 desktop, and multi-MB
// fetches crawled. A full window lets the peer keep the pipe full.
const TCP_WINDOW: u16 = 0xFFFF;
// Ephemeral local-port allocation: OR the low 12 bits of the clock into a fixed
// high base so each connection picks a different, unprivileged local port.
const EPHEMERAL_PORT_BASE: u16 = 0xD000;
const EPHEMERAL_PORT_MASK: u16 = 0x0FFF;
// Fixed initial send sequence number. A constant ISN is acceptable for this
// single-connection stack (no simultaneous reuse of a 4-tuple to collide with).
const INITIAL_SEND_SEQ: u32 = 0x00112200;
// SYN -> SYN-ACK handshake timeout (ms) before connect() gives up.
const CONNECT_TIMEOUT_MS: u64 = 3000;
// Backstop for a single send() before it gives up: the retransmit engine itself
// declares failure after its own budget, but a next hop that never resolves (the
// segment never leaves) arms no timer, so this bounds that case.
const SEND_TIMEOUT_MS: u64 = 20000;

/// Build and send one TCP segment carrying `data` at sequence `seq` (the ACK
/// field always carries the current rcv_nxt). Returns net.sendIp's result (false
/// if the next hop can't be resolved). Does NOT advance snd_nxt — the caller owns
/// the send sequence.
fn sendSeg(flags: u8, seq: u32, data: []const u8) bool {
    const seg = net.txPayload();
    net.wbe16(seg[0..2], local_port);
    net.wbe16(seg[2..4], remote_port);
    net.wbe32(seg[4..8], seq);
    net.wbe32(seg[8..12], rcv_nxt);
    seg[12] = 5 << 4; // data offset 5 words, no options
    seg[13] = flags;
    net.wbe16(seg[14..16], TCP_WINDOW); // window
    net.wbe16(seg[16..18], 0); // checksum placeholder
    net.wbe16(seg[18..20], 0); // urgent
    @memcpy(seg[net.TCP_HLEN .. net.TCP_HLEN + data.len], data);
    const total = net.TCP_HLEN + data.len;
    const pseudo = net.pseudoSum(remote_ip, net.PROTO_TCP, total);
    const csum = net.checksum16(seg[0..total], pseudo);
    net.wbe16(seg[16..18], csum);
    return net.sendIp(remote_ip, net.PROTO_TCP, total);
}

/// A control/handshake segment (SYN, bare ACK, FIN) at the current snd_nxt.
fn sendTcp(flags: u8, data: []const u8) bool {
    return sendSeg(flags, snd_nxt, data);
}

/// The send engine's transport: emit a data segment (PSH|ACK) at `seq`.
fn txEmit(_: *anyopaque, seq: u32, data: []const u8) bool {
    return sendSeg(PSH | ACK, seq, data);
}

/// The MSS the peer advertised in its SYN-ACK options (RFC 9293 §3.2), or the
/// default if absent. Options run from the fixed header to the data offset:
/// kind 0 ends them, kind 1 is a one-byte NOP, every other kind is
/// kind/len/value. A malformed length stops the walk (no over-read).
fn parseMss(p: []const u8, data_off: usize) u16 {
    var i: usize = net.TCP_HLEN;
    while (i + 1 < data_off) {
        const kind = p[i];
        if (kind == 0) break; // end of options
        if (kind == 1) { // NOP
            i += 1;
            continue;
        }
        const len = p[i + 1];
        if (len < 2 or i + len > data_off) break; // malformed
        if (kind == 2 and len == 4 and i + 4 <= data_off) return net.rbe16(p[i + 2 .. i + 4]);
        i += len;
    }
    return tcp_tx.DEFAULT_MSS;
}

/// Called by net's RX dispatch for TCP segments.
pub fn handleTcp(src: [4]u8, p: []const u8) void {
    if (state == .closed or !net.ipEq(src, remote_ip)) return;
    if (p.len < net.TCP_HLEN) return;
    const sport = net.rbe16(p[0..2]);
    const dport = net.rbe16(p[2..4]);
    if (sport != remote_port or dport != local_port) return;
    const seq = net.rbe32(p[4..8]);
    const flags = p[13];
    // Data-offset field (RFC 793 §3.1): the header length in 32-bit words, so the
    // byte offset of the payload is (p[12]>>4)*4. It is peer-controlled and normally
    // >20 (a real SYN-ACK carries MSS/SACK/window-scale options), so we must accept
    // >TCP_HLEN — but reject anything below the fixed header or past the segment,
    // else `p[data_off..]` slices out of bounds and panics.
    const data_off = @as(usize, p[12] >> 4) * 4;
    if (data_off < net.TCP_HLEN or data_off > p.len) return;
    const payload = p[data_off..];

    if ((flags & RST) != 0) {
        // RFC 9293 §3.5.3 / RFC 5961: in SYN-SENT a RST
        // is validated by its ACK field (must acknowledge our SYN — no peer
        // sequence exists yet); in ESTABLISHED by an exact-match sequence check
        // against rcv_nxt. An acceptable RST aborts the connection (connection
        // refused / connection reset); an unacceptable one is dropped silently.
        // Never respond to a RST.
        const ack = net.rbe32(p[8..12]);
        const acceptable = switch (state) {
            .syn_sent => (flags & ACK) != 0 and ack == snd_nxt +% 1,
            .established => seq == rcv_nxt,
            .closed => false,
        };
        if (acceptable) {
            net.dbg("tcp: RST received, connection aborted\n");
            reset_recv = true;
            state = .closed;
        }
        return;
    }

    if (state == .syn_sent and (flags & SYN) != 0 and (flags & ACK) != 0) {
        rcv_nxt = seq +% 1;
        snd_nxt +%= 1; // our SYN consumed one seq
        peer_window = net.rbe16(p[14..16]);
        peer_mss = parseMss(p, data_off);
        state = .established;
        _ = sendTcp(ACK, "");
        return;
    }

    if (state == .established) {
        // Track the peer's advertised window (for the next send) and feed this
        // ACK to the send engine, so our outbound data advances past what the
        // peer has now received and the retransmit timer follows the ACK.
        peer_window = net.rbe16(p[14..16]);
        if ((flags & ACK) != 0) {
            if (active_sender) |snd| snd.onAck(net.rbe32(p[8..12]), peer_window, timer.millis());
        }
        if (payload.len > 0) {
            // Accept the part of this segment at/after rcv_nxt. `offset`
            // computed mod 2^32 is < len exactly when the segment covers
            // rcv_nxt (handles retransmits and overlapping segments).
            const offset = rcv_nxt -% seq;
            if (offset < payload.len) {
                const fresh = payload[offset..];
                // Only advance rcv_nxt / ACK if the bytes were actually stored:
                // ACKing data we failed to buffer would lose it silently and
                // desync the stream. On a buffer-grow failure, drop the segment
                // (leave it unacked) so the peer retransmits.
                if (recv_buf) |*rb| {
                    if (rb.appendSlice(fresh)) |_| {
                        rcv_nxt +%= @intCast(fresh.len);
                        _ = sendTcp(ACK, ""); // ACK only when new data advances rcv_nxt
                    } else |_| {
                        net.dbg("tcp: recv_buf grow failed; dropping segment\n");
                    }
                } else {
                    // No live connection buffer (a stray segment after close) —
                    // drop without ACKing so we don't touch freed memory.
                    net.dbg("tcp: segment with no recv_buf; dropping\n");
                }
            } else {
                // A data segment that advances nothing is a retransmit or
                // out-of-order — our ACK was lost or data is missing. Re-ACK the
                // current rcv_nxt so the peer repairs (RFC 9293 §3.10.7.4):
                // staying silent wedges a window-limited transfer forever once
                // the window-opening ACK is lost. One ACK
                // per received duplicate cannot storm — the peer's retransmit
                // timer paces it.
                _ = sendTcp(ACK, "");
            }
        }
        // The FIN occupies the sequence number AFTER the segment's data
        // (RFC 793 §3.3), so compare seq+len — not seq —
        // against rcv_nxt. This consumes both a bare FIN (len 0) and one
        // piggybacked on the last data segment (whose retransmits carry the
        // same data+FIN and land here with the payload already consumed above).
        if ((flags & FIN) != 0 and seq +% @as(u32, @intCast(payload.len)) == rcv_nxt) {
            rcv_nxt +%= 1;
            fin_recv = true;
            _ = sendTcp(ACK, "");
        }
    }
}

/// Open the single system-wide connection to `ip`:`port` (blocking): pick an
/// ephemeral local port and ISN, send SYN, then pump RX until established or
/// the connect timeout expires. Returns false on refusal or timeout; the
/// caller must `close()` when done. This is the raw stream the HTTP client and
/// the TLS session build on.
pub fn connect(ip: [4]u8, port: u16) bool {
    if (!connectStart(ip, port)) {
        net.dbg("SYN send failed (no route)\n");
        return false;
    }
    net.dbg("SYN sent, waiting for SYN-ACK\n");

    const deadline = timer.millis() + CONNECT_TIMEOUT_MS;
    while (timer.millis() < deadline) {
        net.pump();
        net.serviceDuringWait(); // keep netdebug/KMR1 alive through the handshake
        switch (connectState()) {
            .established => {
                net.dbg("TCP established\n");
                return true;
            },
            // The peer answered our SYN with RST: connection refused. Fail now,
            // not after the full 3 s deadline.
            .refused => {
                net.dbg("TCP connect refused (RST)\n");
                return false;
            },
            .connecting => sched.waitYield(), // SMP: yield to the system task between polls
        }
    }
    net.dbg("TCP connect timeout\n");
    return false;
}

/// How a handshake begun by `connectStart` stands right now. A resumable caller
/// (a fetch job) polls this each frame while the session loop pumps RX, instead
/// of blocking in `connect`.
pub const ConnState = enum { connecting, established, refused };

/// Begin a connection WITHOUT blocking: set the endpoint up and send the SYN.
/// The handshake completes as RX is pumped (the session loop, or `connect`'s own
/// loop); poll `connectState`. One connection system-wide. False = the SYN never
/// left (no route). The caller must `close()` when done.
pub fn connectStart(ip: [4]u8, port: u16) bool {
    remote_ip = ip;
    remote_port = port;
    local_port = EPHEMERAL_PORT_BASE | @as(u16, @truncate(timer.now() & EPHEMERAL_PORT_MASK));
    snd_nxt = INITIAL_SEND_SEQ;
    rcv_nxt = 0;
    fin_recv = false;
    reset_recv = false;
    peer_mss = tcp_tx.DEFAULT_MSS;
    peer_window = 0;
    active_sender = null;
    state = .syn_sent;
    return sendTcp(SYN, "");
}

/// The current handshake state for a `connectStart` (non-blocking).
pub fn connectState() ConnState {
    if (state == .established) return .established;
    if (reset_recv) return .refused;
    return .connecting;
}

/// Begin buffering received bytes for the current connection. Call once,
/// right after a successful connect(), before any recv/drain.
pub fn beginRecv(a: std.mem.Allocator) void {
    recv_buf = std.array_list.Managed(u8).init(a);
}

/// Send `data` reliably on the established connection: segment it to the peer's
/// MSS, keep it within the peer's window, and retransmit anything the peer does
/// not acknowledge, pumping RX to collect ACKs. Returns true once every byte is
/// acknowledged, false on a lost peer (retransmit budget spent), an unresolved
/// route, or the send timeout. Advances snd_nxt past the delivered data.
pub fn send(data: []const u8) bool {
    if (state != .established) return false;
    if (data.len == 0) return true;

    var sender = tcp_tx.Sender.init(data, snd_nxt, peer_mss, peer_window);
    const transport = tcp_tx.Transport{ .ctx = &sender, .emit = txEmit };
    active_sender = &sender;
    defer active_sender = null;

    const deadline = timer.millis() + SEND_TIMEOUT_MS;
    while (true) {
        const prog = sender.step(timer.millis(), transport);
        // Keep snd_nxt at the current send high-water so a bare ACK emitted by the
        // RX path (handleTcp) mid-send carries a sensible SND.NXT.
        snd_nxt = sender.base_seq +% @as(u32, @intCast(sender.nxt));
        switch (prog) {
            .done => return true, // snd_nxt now == sender.endSeq()
            .failed => {
                net.dbg("tcp: send failed — peer stopped acknowledging\n");
                return false;
            },
            .sending => {},
        }
        if (timer.millis() >= deadline) {
            net.dbg("tcp: send timed out\n");
            return false;
        }
        net.pump(); // collect ACKs (delivered into `sender` via handleTcp)
        net.serviceDuringWait(); // keep netdebug/KMR1 alive through a long send
        sched.waitYield();
    }
}

/// Pump the connection until at least one new received byte is available past
/// `consumed`, or the connection ends / `deadline_ms` passes. Returns the
/// total bytes buffered so far (read them from `received()[consumed..]`).
/// FIN/RST/timeout all surface as "no more will arrive": the caller compares
/// the returned length to what it needs.
pub fn pumpUntil(consumed: usize, deadline_ms: u64) usize {
    while (timer.millis() < deadline_ms and state == .established and !fin_recv) {
        const rb = recv_buf orelse break;
        if (rb.items.len > consumed) break;
        net.pump();
        net.serviceDuringWait(); // keep netdebug/KMR1 alive through a long read
        sched.waitYield();
    }
    return if (recv_buf) |rb| rb.items.len else consumed;
}

/// The bytes received on the current connection so far.
pub fn received() []const u8 {
    return if (recv_buf) |rb| rb.items else &.{};
}

/// True once the peer sent FIN (orderly end) — no more data will arrive.
pub fn finished() bool {
    return fin_recv;
}

/// True if the peer aborted with RST.
pub fn wasReset() bool {
    return reset_recv;
}

/// Close the connection (FIN) and release the receive buffer. Idempotent.
pub fn close() void {
    if (state == .established) _ = sendTcp(FIN | ACK, "");
    state = .closed;
    if (recv_buf) |*rb| rb.deinit();
    recv_buf = null;
}
