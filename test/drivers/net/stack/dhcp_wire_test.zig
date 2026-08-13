//! Host tests of src/drivers/net/stack/dhcp_wire.zig.

const std = @import("std");
const dhcp_wire = @import("dhcp_wire");
const inet = @import("inet");
const BOOTP_FIXED = dhcp_wire.BOOTP_FIXED;
const DHCPACK = dhcp_wire.DHCPACK;
const Lease = dhcp_wire.Lease;
const OFF_YIADDR = dhcp_wire.OFF_YIADDR;
const OPT_DNS = dhcp_wire.OPT_DNS;
const OPT_END = dhcp_wire.OPT_END;
const OPT_MSGTYPE = dhcp_wire.OPT_MSGTYPE;
const OPT_PAD = dhcp_wire.OPT_PAD;
const OPT_ROUTER = dhcp_wire.OPT_ROUTER;
const OPT_SERVERID = dhcp_wire.OPT_SERVERID;
const OPT_SUBNET = dhcp_wire.OPT_SUBNET;
const acceptAck = dhcp_wire.acceptAck;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const parseOptions = dhcp_wire.parseOptions;
const yiaddr = dhcp_wire.yiaddr;

/// Test fixture: a minimal DHCP reply — BOOTP fixed header with yiaddr, then options.
fn mkReply(ip: [4]u8, opts: []const u8) [512]u8 {
    var m: [512]u8 = @splat(0);
    @memcpy(m[OFF_YIADDR..][0..4], &ip);
    @memcpy(m[BOOTP_FIXED..][0..opts.len], opts);
    return m;
}

test "regression: an ACK with NO gateway and NO DNS is still a valid lease" {
    // Demanding mask AND gateway AND DNS throws away a usable address when a server
    // simply omits one — and with no address the machine answers no ARP, so it is
    // unreachable and indistinguishable from a wedge while being perfectly healthy.
    const msg = mkReply(.{ 192, 168, 20, 55 }, &[_]u8{
        OPT_MSGTYPE, 1,   DHCPACK,
        OPT_SUBNET,  4,   255,
        255,         255, 0,
        OPT_END, // no router, no DNS
    });
    const o = parseOptions(&msg);
    try expectEqual(@as(?u8, DHCPACK), o.msg_type);
    try expectEqual(@as(?[4]u8, null), o.gateway);
    try expectEqual(@as(?[4]u8, null), o.dns);

    // Asserted BEFORE the unwrap, so reintroducing the old rule fails with this
    // sentence rather than an unexplained null-unwrap panic. A gate whose failure
    // is illegible is a gate people learn to route around.
    try expect(acceptAck(yiaddr(&msg), o) != null); // an ACK without gw/DNS IS a lease
    const lease = acceptAck(yiaddr(&msg), o).?;
    try expectEqual([4]u8{ 192, 168, 20, 55 }, lease.ip);
    try expectEqual([4]u8{ 255, 255, 255, 0 }, lease.mask);
    try expectEqual([4]u8{ 0, 0, 0, 0 }, lease.gateway); // absent, not invalid
    try expectEqual([4]u8{ 0, 0, 0, 0 }, lease.dns);
    try expect(!lease.assumed_mask);
}

test "a bare ACK — address only, no options at all — is still a lease" {
    const msg = mkReply(.{ 10, 55, 0, 77 }, &[_]u8{ OPT_MSGTYPE, 1, DHCPACK, OPT_END });
    const lease = acceptAck(yiaddr(&msg), parseOptions(&msg)).?;
    try expectEqual([4]u8{ 10, 55, 0, 77 }, lease.ip);
    try expectEqual([4]u8{ 255, 255, 255, 0 }, lease.mask); // assumed /24
    try expect(lease.assumed_mask); // and the caller is told so
}

test "only a missing ADDRESS rejects the ACK" {
    const msg = mkReply(.{ 0, 0, 0, 0 }, &[_]u8{
        OPT_MSGTYPE, 1,   DHCPACK,
        OPT_SUBNET,  4,   255,
        255,         255, 0,
        OPT_ROUTER,  4,   192,
        168,         20,  1,
        OPT_END,
    });
    // Every option present, and it is STILL not a lease: there is no address.
    try expectEqual(@as(?Lease, null), acceptAck(yiaddr(&msg), parseOptions(&msg)));
}

test "parseOptions reads a full option set (NET-001)" {
    const msg = mkReply(.{ 192, 168, 20, 30 }, &[_]u8{
        OPT_MSGTYPE, 1,   DHCPACK,
        OPT_SUBNET,  4,   255,
        255,         254, 0,
        OPT_ROUTER,  4,   192,
        168,         20,  1,
        OPT_DNS,      8, 1,   1,   1,  1, 8,       8, 8, 8, // two servers: take the first
        OPT_SERVERID, 4, 192, 168, 20, 1, OPT_END,
    });
    const o = parseOptions(&msg);
    try expectEqual(@as(?u8, DHCPACK), o.msg_type);
    try expectEqual(@as(?[4]u8, .{ 255, 255, 254, 0 }), o.mask);
    try expectEqual(@as(?[4]u8, .{ 192, 168, 20, 1 }), o.gateway);
    try expectEqual(@as(?[4]u8, .{ 1, 1, 1, 1 }), o.dns);
    try expectEqual(@as(?[4]u8, .{ 192, 168, 20, 1 }), o.server_id);

    const lease = acceptAck(yiaddr(&msg), o).?;
    try expectEqual([4]u8{ 255, 255, 254, 0 }, lease.mask); // the OFFERED mask, not /24
    try expect(!lease.assumed_mask);
}

test "PAD bytes are skipped and END stops the walk" {
    const msg = mkReply(.{ 10, 0, 0, 1 }, &[_]u8{
        OPT_PAD,    OPT_PAD, OPT_MSGTYPE, 1, DHCPACK, OPT_PAD,
        OPT_ROUTER, 4,       10,          0, 0,       254,
        OPT_END,
        // Anything after END must not be read — a router option here would be a lie.
           OPT_DNS, 4,           9, 9,       9,
        9,
    });
    const o = parseOptions(&msg);
    try expectEqual(@as(?[4]u8, .{ 10, 0, 0, 254 }), o.gateway);
    try expectEqual(@as(?[4]u8, null), o.dns); // past END: never parsed
}

test "a truncated option length does not read past the datagram" {
    // Adversary-facing: any host on the LAN can send this. A length byte that runs
    // off the end must stop the walk, not index out of bounds.
    var m: [BOOTP_FIXED + 4]u8 = @splat(0);
    @memcpy(m[OFF_YIADDR..][0..4], &[_]u8{ 10, 0, 0, 5 });
    m[BOOTP_FIXED] = OPT_ROUTER;
    m[BOOTP_FIXED + 1] = 200; // claims 200 bytes; only 2 remain
    const o = parseOptions(&m);
    try expectEqual(@as(?[4]u8, null), o.gateway); // refused, not misread

    // A short buffer with no room for options at all is handled too.
    const o2 = parseOptions(&[_]u8{ 1, 2, 3 });
    try expectEqual(@as(?u8, null), o2.msg_type);
}

test "yiaddr on a runt datagram is zero, not a panic" {
    try expectEqual([4]u8{ 0, 0, 0, 0 }, yiaddr(&[_]u8{ 1, 2, 3 }));
}

// ── snoopAck: a guest's lease read off a raw bridged frame ───────────────────

const ETH_HLEN = inet.ETHER_HEADER_BYTES;
const IP_HLEN = 20; // RFC 791 header, no options (the fixture writes IHL=5)
const UDP_HLEN = 8;
const GUEST_MAC = [6]u8{ 0x52, 0x54, 0x00, 0xAA, 0xBB, 0x01 };
const GUEST_IP = [4]u8{ 10, 0, 2, 16 };

/// Test fixture: the frame QEMU's slirp answers a guest's REQUEST with —
/// Ethernet + IPv4 + UDP 67→68 wrapping a BOOTREPLY whose chaddr is the
/// guest's MAC. Raw adversary-shaped input, built byte-by-byte on purpose.
fn mkAckFrame(msg_type: u8, ip: [4]u8) [ETH_HLEN + IP_HLEN + UDP_HLEN + 512]u8 {
    var f: [ETH_HLEN + IP_HLEN + UDP_HLEN + 512]u8 = @splat(0);
    f[12] = 0x08; // ethertype IPv4
    f[13] = 0x00;
    const p = f[ETH_HLEN..];
    p[0] = 0x45; // version 4, IHL 5
    const total = IP_HLEN + UDP_HLEN + 512;
    p[2] = @intCast(total >> 8);
    p[3] = @intCast(total & 0xFF);
    p[9] = 17; // UDP
    const seg = p[IP_HLEN..];
    seg[1] = dhcp_wire.SERVER_PORT; // 67 → 68, big-endian low bytes
    seg[3] = dhcp_wire.CLIENT_PORT;
    var msg = mkReply(ip, &[_]u8{ OPT_MSGTYPE, 1, msg_type, OPT_END });
    msg[dhcp_wire.OFF_OP] = dhcp_wire.BOOTREPLY;
    msg[dhcp_wire.OFF_HTYPE] = dhcp_wire.HTYPE_ETHER;
    msg[dhcp_wire.OFF_HLEN] = inet.ETHER_ADDR_BYTES;
    @memcpy(msg[dhcp_wire.OFF_CHADDR..][0..6], &GUEST_MAC);
    @memcpy(seg[UDP_HLEN..][0..512], &msg);
    return f;
}

test "a bridged DHCP ACK yields the client MAC and the leased address" {
    const f = mkAckFrame(DHCPACK, GUEST_IP);
    const l = dhcp_wire.snoopAck(&f) orelse return error.AckNotSnooped;
    // chaddr is the key, NOT the Ethernet destination: a server answering on
    // broadcast names nobody in the frame header (the fixture's dst is zeros).
    try expectEqual(GUEST_MAC, l.mac);
    try expectEqual(GUEST_IP, l.ip);
}

test "only a server→client ACK with a real address is a lease" {
    // An OFFER is a proposal, not a lease.
    try expect(dhcp_wire.snoopAck(&mkAckFrame(dhcp_wire.DHCPOFFER, GUEST_IP)) == null);
    // An ACK granting 0.0.0.0 grants nothing.
    try expect(dhcp_wire.snoopAck(&mkAckFrame(DHCPACK, .{ 0, 0, 0, 0 })) == null);

    var f = mkAckFrame(DHCPACK, GUEST_IP);
    f[13] = 0x06; // ethertype ARP, not IPv4
    try expect(dhcp_wire.snoopAck(&f) == null);

    f = mkAckFrame(DHCPACK, GUEST_IP);
    f[ETH_HLEN + 9] = 6; // TCP, not UDP
    try expect(dhcp_wire.snoopAck(&f) == null);

    f = mkAckFrame(DHCPACK, GUEST_IP);
    f[ETH_HLEN + IP_HLEN + 1] = dhcp_wire.CLIENT_PORT; // 68 → 68: not a server's reply
    try expect(dhcp_wire.snoopAck(&f) == null);

    f = mkAckFrame(DHCPACK, GUEST_IP);
    f[ETH_HLEN + IP_HLEN + 3] = dhcp_wire.SERVER_PORT; // 67 → 67: not for a client
    try expect(dhcp_wire.snoopAck(&f) == null);

    f = mkAckFrame(DHCPACK, GUEST_IP);
    f[ETH_HLEN + IP_HLEN + UDP_HLEN + dhcp_wire.OFF_OP] = 1; // BOOTREQUEST, not a reply
    try expect(dhcp_wire.snoopAck(&f) == null);
}

test "an out-of-bounds IHL or any truncation is refused, not read past" {
    // Adversary-facing: this parser reads frames that are NOT addressed to this
    // host, so classifyIp's guards never ran on them.
    var f = mkAckFrame(DHCPACK, GUEST_IP);
    f[ETH_HLEN] = 0x4F; // IHL claims 60 header bytes
    try expect(dhcp_wire.snoopAck(&f) == null);

    // Every strict prefix of a valid frame must be a clean refusal.
    const whole = mkAckFrame(DHCPACK, GUEST_IP);
    var len: usize = 0;
    while (len < whole.len) : (len += 1) {
        try expect(dhcp_wire.snoopAck(whole[0..len]) == null);
    }
}
