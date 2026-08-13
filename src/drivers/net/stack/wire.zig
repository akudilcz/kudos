//! Pure on-wire helpers for the network stack: big-endian
//! field access, the Internet checksum, IPv4 equality + dotted-quad parsing.
//! Depends only on `std`, so it is host-testable directly (`zig build test`) and
//! is the single source of truth for these — net.zig re-exports them and the
//! udp/tcp/dhcp builders call through net.

const std = @import("std");

/// Write `v` big-endian into the first two bytes of `b`.
pub fn wbe16(b: []u8, v: u16) void {
    b[0] = @truncate(v >> 8);
    b[1] = @truncate(v);
}
/// Write `v` big-endian into the first four bytes of `b`.
pub fn wbe32(b: []u8, v: u32) void {
    b[0] = @truncate(v >> 24);
    b[1] = @truncate(v >> 16);
    b[2] = @truncate(v >> 8);
    b[3] = @truncate(v);
}
/// Read a big-endian u16 from the first two bytes of `b`.
pub fn rbe16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}
/// Read a big-endian u32 from the first four bytes of `b`.
pub fn rbe32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

/// The one's-complement Internet checksum (RFC 1071) over `data`, folded onto
/// `initial` (e.g. a transport pseudo-header sum). Used for IP/ICMP/TCP/UDP.
pub fn checksum16(data: []const u8, initial: u32) u16 {
    var sum: u32 = initial;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += (@as(u32, data[i]) << 8) | data[i + 1];
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

/// True if the two IPv4 addresses are byte-for-byte equal.
pub fn ipEq(a: [4]u8, b: [4]u8) bool {
    return std.mem.eql(u8, &a, &b);
}

pub const IP_HLEN: usize = 20;
pub const UDP_HLEN: usize = 8;
pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;
pub const IP_BROADCAST: [4]u8 = .{ 255, 255, 255, 255 };

/// Ethernet II ethertype field: where it sits and the two values this stack
/// speaks (IEEE 802.3 / RFC 894). Owned here so the pure parsers can read a
/// raw frame; net.zig re-exports the values like the byte-order helpers.
pub const ETHERTYPE_OFF: usize = 12;
pub const ETH_ARP: u16 = 0x0806;
pub const ETH_IP: u16 = 0x0800;

/// Lay out a UDP header + payload into `seg` (the transport region of an IPv4
/// frame): ports, length, zero checksum (optional for IPv4 — RFC 768). Returns
/// the segment length to hand to the IP send. The single place the UDP header
/// is spelled; every UDP send path builds through it.
pub fn buildUdp(seg: []u8, src_port: u16, dst_port: u16, payload: []const u8) usize {
    wbe16(seg[0..2], src_port);
    wbe16(seg[2..4], dst_port);
    wbe16(seg[4..6], @intCast(UDP_HLEN + payload.len));
    wbe16(seg[6..8], 0); // checksum optional for IPv4 (RFC 768)
    @memcpy(seg[UDP_HLEN .. UDP_HLEN + payload.len], payload);
    return UDP_HLEN + payload.len;
}

/// What an inbound IPv4 frame is, once validated. `payload` is the transport
/// payload — already trimmed of Ethernet padding and past a bounds-checked IHL.
pub const IpPacket = struct { proto: u8, src: [4]u8, dst: [4]u8, payload: []const u8 };

/// Validate an inbound IPv4 frame and hand back its payload, or null to DROP it.
///
/// EVERY GUARD HERE STOPS A REMOTELY-TRIGGERABLE RING-0 PANIC OR A DATA LEAK, and any
/// host on the LAN can send us the frame that trips one. That is why this is pure and
/// host-tested rather than buried in net.zig, where nothing could reach it:
///
///  - `ihl` is attacker-controlled (0..60) and INDEPENDENT of total_len. An IHL past
///    the end of the packet makes `p[ihl..]` slice out of bounds — a remote halt.
///  - `total_len` below the header or beyond the frame is malformed; parsing the
///    untrimmed frame instead would feed Ethernet trailer padding into the transport
///    payload (short frames are zero-padded to 60 bytes, so a 0-data FIN segment
///    leaks 6 zero bytes of "data").
///  - The broadcast destination is accepted ONLY for UDP, and ONLY while DHCP is
///    still binding (we have no address yet, and the server broadcasts OFFER/ACK).
///    Accepting broadcast ICMP or TCP would feed them into those state machines —
///    answering a broadcast echo request, for one.
pub fn classifyIp(frame: []const u8, our_ip: [4]u8, dhcp_binding: bool) ?IpPacket {
    if (frame.len < IP_HLEN) return null;
    if ((frame[0] >> 4) != 4) return null; // not IPv4

    const total_len = rbe16(frame[2..4]);
    if (total_len < IP_HLEN or total_len > frame.len) return null;
    const p = frame[0..total_len];

    const proto = p[9];
    const src: [4]u8 = p[12..16].*;
    const dst: [4]u8 = p[16..20].*;

    const dhcp_bcast = dhcp_binding and proto == PROTO_UDP and ipEq(dst, IP_BROADCAST);
    if (!ipEq(dst, our_ip) and !dhcp_bcast) return null;

    const ihl: usize = @as(usize, frame[0] & 0x0F) * 4;
    if (ihl < IP_HLEN or ihl > p.len) return null; // the ring-0 halt this prevents

    return .{ .proto = proto, .src = src, .dst = dst, .payload = p[ihl..] };
}

/// Parse a dotted-quad IPv4 address ("a.b.c.d") into 4 bytes, or null if `s` is not a
/// valid dotted-quad (e.g. it is a hostname). Single source of truth for dotted-IP
/// parsing, used by tcp/http and the `net` command.
pub fn parseIp(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null;
}

// --- ICMP echo (NET-006/NET-007) -------------------------------------------

pub const ICMP_ECHO_REQUEST: u8 = 8;
pub const ICMP_ECHO_REPLY: u8 = 0;
/// Minimum ICMP echo message: type, code, checksum, identifier, sequence.
pub const ICMP_ECHO_HLEN: usize = 8;

/// Build the echo REPLY to an inbound echo request `req` into `out`, returning
/// the reply's length, or null when `req` is not a well-formed echo request.
///
/// RFC 792 asks that the request's data be echoed back, so the length is the
/// attacker's to choose: it is bounded to `out` here rather than at the call
/// site, because a responder that trusts an inbound length overruns its own
/// transmit buffer. The checksum is recomputed over the bounded reply with its
/// own field zeroed first — echoing the request's checksum unchanged, or
/// summing over the stale field, yields a reply every host silently drops.
pub fn icmpEchoReply(out: []u8, req: []const u8) ?usize {
    if (req.len < ICMP_ECHO_HLEN or req[0] != ICMP_ECHO_REQUEST) return null;
    if (out.len < ICMP_ECHO_HLEN) return null;
    const n = @min(req.len, out.len);
    @memcpy(out[0..n], req[0..n]);
    out[0] = ICMP_ECHO_REPLY;
    wbe16(out[2..4], 0);
    wbe16(out[2..4], checksum16(out[0..n], 0));
    return n;
}

/// Whether `p` is the echo REPLY our in-flight ping is waiting for: identifier
/// and sequence must both match, so a stale reply from an earlier ping (or
/// another host's traffic) cannot be counted as this one's round trip.
pub fn icmpEchoReplyMatches(p: []const u8, id: u16, seq: u16) bool {
    if (p.len < ICMP_ECHO_HLEN or p[0] != ICMP_ECHO_REPLY) return false;
    return rbe16(p[4..6]) == id and rbe16(p[6..8]) == seq;
}
