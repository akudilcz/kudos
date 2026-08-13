//! UDP datagrams + a DNS resolver. Built on net's IP layer.

const net = @import("net.zig");
const dns_wire = @import("dns_wire.zig");
const cfg = @import("config.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const klog = @import("../../../kernel/debug/klog.zig");
const gate = @import("../../../kernel/debug/gate.zig");
const sched = @import("../../../kernel/sched/sched.zig");

// Fixed DNS transaction id: this resolver runs one query at a time on core 0, so a
// constant id suffices — but a late/duplicate answer from a *previous* query on a
// reused local_port must not be accepted for the current one, so the reply's id is
// matched against this before use.
const DNS_TXID: u16 = 0x1234;

// Well-known UDP port for DNS servers (RFC 1035).
const DNS_SERVER_PORT: u16 = 53;
// DNS response timeout (ms) before dnsResolve gives up.
const DNS_TIMEOUT_MS: u64 = 2000;
// Ephemeral source-port allocation for DNS queries: OR the low 14 bits of the
// clock into a fixed high base so each query uses a fresh unprivileged port.
const EPHEMERAL_PORT_BASE: u16 = 0xC000;
const EPHEMERAL_PORT_MASK: u16 = 0x3FFF;

var local_port: u16 = 0;
// Response scratch sized to one Ethernet MTU (a DNS reply fits within one frame).
var resp: [1500]u8 = undefined;
var resp_len: usize = 0;
var got = false;

/// Send a UDP datagram carrying `data` from `src_port` to `dst`:`dst_port`.
/// Checksum is left 0 (optional for IPv4). Returns net.sendIp's result.
fn sendUdp(dst: [4]u8, src_port: u16, dst_port: u16, data: []const u8) bool {
    const len = net.buildUdp(net.txPayload(), src_port, dst_port, data);
    return net.sendIp(dst, net.PROTO_UDP, len);
}

/// Called by net's RX dispatch for UDP datagrams addressed to us.
pub fn handleUdp(src: [4]u8, p: []const u8) void {
    _ = src;
    if (p.len < net.UDP_HLEN) return;
    const dport = net.rbe16(p[2..4]);
    if (dport != local_port) return;
    const len = @min(p.len - net.UDP_HLEN, resp.len);
    @memcpy(resp[0..len], p[net.UDP_HLEN .. net.UDP_HLEN + len]);
    resp_len = len;
    got = true;
}

/// Resolve a hostname to an IPv4 address via DNS (A record). The wire codec is
/// the pure, host-tested dns_wire.zig; this function owns only the IO — the
/// ephemeral port, the send, the timed pump, and the debug logging.
pub fn dnsResolve(host: []const u8) ?[4]u8 {
    local_port = EPHEMERAL_PORT_BASE | @as(u16, @truncate(timer.now() & EPHEMERAL_PORT_MASK));
    got = false;

    var q: [512]u8 = undefined;
    const n = dns_wire.buildQuery(&q, DNS_TXID, host) orelse return null;
    if (!sendUdp(cfg.dns_server, local_port, DNS_SERVER_PORT, q[0..n])) return null;

    const deadline = timer.millis() + DNS_TIMEOUT_MS;
    while (timer.millis() < deadline) {
        net.pump();
        if (got) break;
        if (sched.cancelled()) return null; // ^C: the asker stopped wanting the answer
        sched.waitYield(); // SMP: yield to core 0's system task between polls
    }
    if (!got) return null;

    const ip = dns_wire.parseAnswer(resp[0..resp_len], DNS_TXID) catch |e| {
        switch (e) {
            error.TxidMismatch => net.dbg("dns: txid mismatch\n"),
            error.NoARecord => net.dbg("dns: no A record\n"),
        }
        return null;
    };
    if (gate.on(.net)) {
        klog.puts("dns resolved -> ");
        inline for (0..4) |k| {
            klog.putHex(ip[k]);
            if (k < 3) klog.putc('.');
        }
        klog.putc('\n');
    }
    return ip;
}
