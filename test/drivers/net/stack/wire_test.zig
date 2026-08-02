//! Host tests of src/drivers/net/stack/wire.zig.

const std = @import("std");
const wire = @import("wire");
const IP_BROADCAST = wire.IP_BROADCAST;
const PROTO_ICMP = wire.PROTO_ICMP;
const PROTO_TCP = wire.PROTO_TCP;
const PROTO_UDP = wire.PROTO_UDP;
const checksum16 = wire.checksum16;
const classifyIp = wire.classifyIp;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const ipEq = wire.ipEq;
const parseIp = wire.parseIp;
const rbe16 = wire.rbe16;
const rbe32 = wire.rbe32;
const wbe16 = wire.wbe16;
const wbe32 = wire.wbe32;

/// Test fixture: a 64-byte frame holding an IPv4 header with the given IHL,
/// total length, protocol and destination; src fixed at 10.0.0.9.
fn mkIp(ihl_words: u8, total_len: u16, proto: u8, dst: [4]u8) [64]u8 {
    var f: [64]u8 = @splat(0);
    f[0] = 0x40 | (ihl_words & 0x0F); // version 4 + IHL
    wbe16(f[2..4], total_len);
    f[9] = proto;
    f[12] = 10;
    f[13] = 0;
    f[14] = 0;
    f[15] = 9; // src
    @memcpy(f[16..20], &dst);
    return f;
}

test "wbe/rbe 16/32 round-trip and byte order" {
    var b: [4]u8 = undefined;
    wbe16(b[0..2], 0x1234);
    try expectEqual(@as(u8, 0x12), b[0]);
    try expectEqual(@as(u8, 0x34), b[1]);
    try expectEqual(@as(u16, 0x1234), rbe16(b[0..2]));
    wbe32(b[0..4], 0xDEADBEEF);
    try expectEqual(@as(u8, 0xDE), b[0]);
    try expectEqual(@as(u8, 0xEF), b[3]);
    try expectEqual(@as(u32, 0xDEADBEEF), rbe32(b[0..4]));
    // edge values
    wbe16(b[0..2], 0);
    try expectEqual(@as(u16, 0), rbe16(b[0..2]));
    wbe16(b[0..2], 0xFFFF);
    try expectEqual(@as(u16, 0xFFFF), rbe16(b[0..2]));
}

test "checksum16: a header with its own checksum inserted verifies to 0" {
    // Property (RFC 1071): sum the header with the checksum field zero, insert
    // the result, and a re-sum over the whole header is 0 — no memorized magic
    // number needed. Bytes 10..12 are the IPv4 header checksum field.
    var hdr = [_]u8{ 0x45, 0x00, 0x00, 0x30, 0x44, 0x22, 0x40, 0x00, 0x80, 0x06, 0x00, 0x00, 0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7 };
    const ck = checksum16(&hdr, 0);
    hdr[10] = @truncate(ck >> 8);
    hdr[11] = @truncate(ck);
    try expectEqual(@as(u16, 0), checksum16(&hdr, 0));
}

test "checksum16: folding + odd length + initial fold-in" {
    // All-0xFF words carry, exercising the end-around carry fold.
    const ff = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    try expectEqual(@as(u16, 0), checksum16(&ff, 0)); // ~0xFFFF folded = 0
    // Odd-length data exercises the trailing-byte branch (must not read OOB).
    const odd = [_]u8{ 0x01, 0x02, 0x03 };
    const a = checksum16(&odd, 0);
    // Same three bytes padded with a trailing zero → identical sum (the code
    // treats the last odd byte as the high byte of a zero-padded word).
    const padded = [_]u8{ 0x01, 0x02, 0x03, 0x00 };
    try expectEqual(a, checksum16(&padded, 0));
    // A non-zero `initial` (pseudo-header sum) folds in.
    try expectEqual(checksum16(&odd, 0x0001), checksum16(&([_]u8{ 0x00, 0x01 } ++ odd), 0));
}

test "ipEq" {
    try expect(ipEq(.{ 192, 168, 0, 1 }, .{ 192, 168, 0, 1 }));
    try expect(!ipEq(.{ 192, 168, 0, 1 }, .{ 192, 168, 0, 2 }));
}

test "parseIp: valid dotted-quad, rejects malformed / hostnames" {
    try expectEqual([4]u8{ 192, 168, 1, 254 }, parseIp("192.168.1.254").?);
    try expectEqual([4]u8{ 0, 0, 0, 0 }, parseIp("0.0.0.0").?);
    try expectEqual([4]u8{ 255, 255, 255, 255 }, parseIp("255.255.255.255").?);
    try expect(parseIp("192.168.1") == null); // too few octets
    try expect(parseIp("192.168.1.2.3") == null); // too many
    try expect(parseIp("192.168.1.256") == null); // octet > 255
    try expect(parseIp("example.com") == null); // hostname
    try expect(parseIp("192.168.1.x") == null); // non-numeric
    try expect(parseIp("") == null);
}

test "regression: an IHL past the end of the packet must DROP, not panic" {
    // p[ihl..] with ihl > p.len is an out-of-bounds slice — a ring-0 halt that any
    // host on the LAN can trigger by sending one malformed datagram. IHL is 4 bits,
    // so it reaches 60 bytes, entirely independent of total_len.
    const me = [4]u8{ 10, 0, 0, 1 };
    var f = mkIp(15, 24, PROTO_UDP, me); // IHL = 15*4 = 60, but total_len = 24
    try std.testing.expect(classifyIp(f[0..40], me, false) == null);

    // IHL below the 20-byte minimum is malformed too.
    f = mkIp(4, 24, PROTO_UDP, me);
    try std.testing.expect(classifyIp(f[0..40], me, false) == null);
}

test "regression: total_len bounds — Ethernet padding must not leak into the payload" {
    const me = [4]u8{ 10, 0, 0, 1 };
    // A frame zero-padded to 60 bytes carrying a 24-byte packet: the payload must be
    // 4 bytes (24 - 20), NOT 40. Trusting the frame size leaks the padding as data.
    const f = mkIp(5, 24, PROTO_UDP, me);
    const pkt = classifyIp(f[0..60], me, false).?;
    try expectEqual(@as(usize, 4), pkt.payload.len);

    // total_len beyond the frame, or below the header: drop.
    const big = mkIp(5, 900, PROTO_UDP, me);
    try std.testing.expect(classifyIp(big[0..60], me, false) == null);
    const tiny = mkIp(5, 8, PROTO_UDP, me);
    try std.testing.expect(classifyIp(tiny[0..60], me, false) == null);
}

test "regression: broadcast is accepted for UDP while binding — and for NOTHING else" {
    const me = [4]u8{ 10, 0, 0, 1 };
    const bcast = IP_BROADCAST;

    // While DHCP binds we have no address, so the broadcast OFFER/ACK must land.
    const udp_b = mkIp(5, 24, PROTO_UDP, bcast);
    try std.testing.expect(classifyIp(udp_b[0..60], me, true) != null);

    // But a broadcast ICMP echo must NOT reach the ICMP state machine — answering
    // one makes us a reflector. Same for TCP.
    const icmp_b = mkIp(5, 24, PROTO_ICMP, bcast);
    try std.testing.expect(classifyIp(icmp_b[0..60], me, true) == null);
    const tcp_b = mkIp(5, 24, PROTO_TCP, bcast);
    try std.testing.expect(classifyIp(tcp_b[0..60], me, true) == null);

    // And once bound, broadcast UDP is no longer special: drop it.
    try std.testing.expect(classifyIp(udp_b[0..60], me, false) == null);
}

test "classifyIp: a normal unicast packet to us is accepted" {
    const me = [4]u8{ 10, 0, 0, 1 };
    const f = mkIp(5, 28, PROTO_UDP, me);
    const pkt = classifyIp(f[0..60], me, false).?;
    try expectEqual(@as(u8, PROTO_UDP), pkt.proto);
    try expectEqual([4]u8{ 10, 0, 0, 9 }, pkt.src);
    try expectEqual(@as(usize, 8), pkt.payload.len);

    // A packet addressed to someone else is not ours.
    const other = mkIp(5, 28, PROTO_UDP, .{ 10, 0, 0, 2 });
    try std.testing.expect(classifyIp(other[0..60], me, false) == null);
}

test "classifyIp: a runt frame and a non-IPv4 version are dropped" {
    const me = [4]u8{ 10, 0, 0, 1 };
    try std.testing.expect(classifyIp(&[_]u8{ 0x45, 0, 0 }, me, false) == null);
    var f = mkIp(5, 28, PROTO_UDP, me);
    f[0] = 0x65; // version 6 in an IPv4 handler
    try std.testing.expect(classifyIp(f[0..60], me, false) == null);
}

test "buildUdp: header layout, length field, zero checksum, payload copy" {
    var seg: [64]u8 = @splat(0xAA);
    const payload = "kudos";
    const len = wire.buildUdp(&seg, 0xC123, 53, payload);
    try expectEqual(wire.UDP_HLEN + payload.len, len);
    try expectEqual(@as(u16, 0xC123), rbe16(seg[0..2])); // source port
    try expectEqual(@as(u16, 53), rbe16(seg[2..4])); // destination port
    try expectEqual(@as(u16, @intCast(len)), rbe16(seg[4..6])); // UDP length covers header + payload
    try expectEqual(@as(u16, 0), rbe16(seg[6..8])); // checksum optional for IPv4
    try expect(std.mem.eql(u8, payload, seg[wire.UDP_HLEN..len]));
}

test "buildUdp: empty payload is a bare 8-byte header" {
    var seg: [16]u8 = @splat(0xAA);
    const len = wire.buildUdp(&seg, 68, 67, "");
    try expectEqual(wire.UDP_HLEN, len);
    try expectEqual(@as(u16, @intCast(wire.UDP_HLEN)), rbe16(seg[4..6]));
}

// ── ICMP echo (NET-006 reply, NET-007 ping matching) ─────────────────────────

/// One echo request: type 8, code 0, checksum, id, seq, then `data`.
fn echoRequest(buf: []u8, id: u16, seq: u16, data: []const u8) []u8 {
    buf[0] = wire.ICMP_ECHO_REQUEST;
    buf[1] = 0;
    wire.wbe16(buf[2..4], 0);
    wire.wbe16(buf[4..6], id);
    wire.wbe16(buf[6..8], seq);
    @memcpy(buf[8 .. 8 + data.len], data);
    const n = 8 + data.len;
    wire.wbe16(buf[2..4], wire.checksum16(buf[0..n], 0));
    return buf[0..n];
}

test "an echo request is answered with a checksum-valid reply that echoes the data (NET-006)" {
    var req_buf: [64]u8 = undefined;
    const req = echoRequest(&req_buf, 0x4B55, 7, "kudos-payload");
    var out: [128]u8 = @splat(0xAA);
    const n = wire.icmpEchoReply(&out, req) orelse return error.NoReply;

    try expectEqual(req.len, n);
    try expectEqual(wire.ICMP_ECHO_REPLY, out[0]);
    // Identifier, sequence and data come back untouched — a peer matches the
    // reply to its request by exactly these.
    try expectEqual(@as(u16, 0x4B55), rbe16(out[4..6]));
    try expectEqual(@as(u16, 7), rbe16(out[6..8]));
    try std.testing.expectEqualSlices(u8, "kudos-payload", out[8..n]);
    // A correct ICMP checksum makes the whole message sum to zero; a stale or
    // copied checksum leaves a reply every peer silently drops.
    try expectEqual(@as(u16, 0), wire.checksum16(out[0..n], 0));
}

test "an oversized echo request is bounded to the transmit buffer, never overrunning it (NET-006)" {
    // RFC 792 echoes the request's data, so its length is the sender's to
    // choose: a crafted full-frame ping must not write past the reply buffer.
    var req_buf: [1500]u8 = undefined;
    const req = echoRequest(&req_buf, 1, 1, &[_]u8{0x5A} ** 1400);
    var out: [64]u8 = @splat(0xAA);
    var guard: [16]u8 = @splat(0xEE);
    const n = wire.icmpEchoReply(&out, req) orelse return error.NoReply;

    try expectEqual(out.len, n); // truncated to what fits, not to what was asked
    try std.testing.expectEqualSlices(u8, &[_]u8{0xEE} ** 16, &guard);
    try expectEqual(@as(u16, 0), wire.checksum16(out[0..n], 0)); // still valid
}

test "a malformed or non-request ICMP message yields no reply (NET-006)" {
    var out: [64]u8 = undefined;
    // Too short to carry an echo header.
    try std.testing.expectEqual(@as(?usize, null), wire.icmpEchoReply(&out, &[_]u8{ 8, 0, 0 }));
    // An echo REPLY is not a request: answering one is how two hosts ping-pong
    // forever off a single spoofed packet.
    var reply_buf: [16]u8 = undefined;
    const req = echoRequest(&reply_buf, 1, 1, "");
    reply_buf[0] = wire.ICMP_ECHO_REPLY;
    try std.testing.expectEqual(@as(?usize, null), wire.icmpEchoReply(&out, req));
}

test "a ping reply counts only when identifier AND sequence match (NET-007)" {
    var buf: [32]u8 = undefined;
    const req = echoRequest(&buf, 0x4B55, 9, "x");
    var reply: [64]u8 = undefined;
    const n = wire.icmpEchoReply(&reply, req).?;

    try std.testing.expect(wire.icmpEchoReplyMatches(reply[0..n], 0x4B55, 9));
    // A reply to the PREVIOUS ping must not be timed as this one's round trip.
    try std.testing.expect(!wire.icmpEchoReplyMatches(reply[0..n], 0x4B55, 8));
    // Nor another host's echo traffic carrying a different identifier.
    try std.testing.expect(!wire.icmpEchoReplyMatches(reply[0..n], 0x1234, 9));
    // A request is not a reply, however well its fields line up.
    try std.testing.expect(!wire.icmpEchoReplyMatches(req, 0x4B55, 9));
}
