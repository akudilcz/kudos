//! Host tests of src/drivers/net/debug/fileproto.zig.

const std = @import("std");
const fileproto = @import("fileproto");
const Dedup = fileproto.Dedup;
const HDR_LEN = fileproto.HDR_LEN;
const KEY_F12 = fileproto.KEY_F12;
const KEY_NONE = fileproto.KEY_NONE;
const ListEntry = fileproto.ListEntry;
const OP_KEY = fileproto.OP_KEY;
const OP_LIST = fileproto.OP_LIST;
const OP_MOUSE = fileproto.OP_MOUSE;
const OP_READ = fileproto.OP_READ;
const OP_SHOT = fileproto.OP_SHOT;
const parseHeader = fileproto.parseHeader;
const parseReadReq = fileproto.parseReadReq;
const writeHeader = fileproto.writeHeader;
const writeKeyReq = fileproto.writeKeyReq;
const writeListResp = fileproto.writeListResp;
const writeMouseReq = fileproto.writeMouseReq;
const writeReadReq = fileproto.writeReadReq;
const writeReadResp = fileproto.writeReadResp;
const writeShotReq = fileproto.writeShotReq;

test "header round-trip and rejection" {
    var buf: [64]u8 = undefined;
    const n = writeHeader(&buf, OP_LIST, 0xbeef);
    try std.testing.expectEqual(HDR_LEN, n);
    const h = parseHeader(buf[0..n]).?;
    try std.testing.expectEqual(OP_LIST, h.op);
    try std.testing.expectEqual(@as(u16, 0xbeef), h.request_id);
    try std.testing.expect(parseHeader(&[_]u8{ 1, 2, 3 }) == null);
    buf[0] = 0; // break magic
    try std.testing.expect(parseHeader(buf[0..n]) == null);
}

test "read request round-trip" {
    var buf: [128]u8 = undefined;
    const n = writeReadReq(&buf, 7, .{ .name = "screenshot.ppm", .generation = 3, .offset = 4800, .len = 1200 });
    const h = parseHeader(buf[0..n]).?;
    try std.testing.expectEqual(OP_READ, h.op);
    const r = parseReadReq(buf[HDR_LEN..n]).?;
    try std.testing.expectEqualStrings("screenshot.ppm", r.name);
    try std.testing.expectEqual(@as(u32, 3), r.generation);
    try std.testing.expectEqual(@as(u32, 4800), r.offset);
    try std.testing.expectEqual(@as(u16, 1200), r.len);
    // Truncated body rejected.
    try std.testing.expect(parseReadReq(buf[HDR_LEN .. n - 1]) == null);
}

test "list + read responses have the documented layout" {
    var buf: [256]u8 = undefined;
    const entries = [_]ListEntry{
        .{ .name = "a.txt", .generation = 1, .size = 10, .crc = 0x11223344 },
        .{ .name = "bb", .generation = 2, .size = 0x1000, .crc = 0x55667788 },
    };
    const n = writeListResp(&buf, 9, &entries).?;
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[8..10], .little));
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, buf[10..12], .little));
    try std.testing.expectEqualStrings("a.txt", buf[12..17]);
    try std.testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, buf[25..29], .little));
    _ = n;

    var rb: [64]u8 = undefined;
    const rn = writeReadResp(&rb, 5, 3, 4800, "hello");
    try std.testing.expectEqual(@as(usize, HDR_LEN + 10 + 5), rn);
    try std.testing.expectEqual(@as(u32, 4800), std.mem.readInt(u32, rb[12..16], .little));
    try std.testing.expectEqualStrings("hello", rb[18..23]);
}

test "tiny buffer makes writeListResp return null" {
    var buf: [16]u8 = undefined;
    const entries = [_]ListEntry{.{ .name = "long-name.bin", .generation = 1, .size = 1, .crc = 1 }};
    try std.testing.expect(writeListResp(&buf, 1, &entries) == null);
}

test "injection request encoders have the documented layout" {
    var buf: [32]u8 = undefined;
    var n = writeKeyReq(&buf, 11, 'x', KEY_NONE);
    try std.testing.expectEqual(HDR_LEN + 2, n);
    try std.testing.expectEqual(OP_KEY, parseHeader(buf[0..n]).?.op);
    try std.testing.expectEqual(@as(u8, 'x'), buf[HDR_LEN]);
    try std.testing.expectEqual(KEY_NONE, buf[HDR_LEN + 1]);
    // A named key carries no character: F12 is how the suite drives the WM.
    n = writeKeyReq(&buf, 12, 0, KEY_F12);
    try std.testing.expectEqual(KEY_F12, buf[HDR_LEN + 1]);
    try std.testing.expectEqual(@as(u8, 0), buf[HDR_LEN]); // a named key has no character

    n = writeMouseReq(&buf, 12, -300, 25, 0b101);
    try std.testing.expectEqual(HDR_LEN + 5, n);
    try std.testing.expectEqual(OP_MOUSE, parseHeader(buf[0..n]).?.op);
    try std.testing.expectEqual(@as(i16, -300), std.mem.readInt(i16, buf[HDR_LEN..][0..2], .little));
    try std.testing.expectEqual(@as(i16, 25), std.mem.readInt(i16, buf[HDR_LEN + 2 ..][0..2], .little));
    try std.testing.expectEqual(@as(u8, 0b101), buf[HDR_LEN + 4]);

    n = writeShotReq(&buf, 13);
    try std.testing.expectEqual(HDR_LEN, n);
    try std.testing.expectEqual(OP_SHOT, parseHeader(buf[0..n]).?.op);
}

test "Dedup remembers the last CAP ids and evicts the oldest" {
    var d = Dedup{};
    try std.testing.expect(!d.seen(0)); // id 0 is a valid, initially-unseen id
    for (0..Dedup.CAP) |i| {
        const rid: u16 = @intCast(i);
        try std.testing.expect(!d.seen(rid));
        d.record(rid);
        try std.testing.expect(d.seen(rid));
    }
    d.record(1000); // evicts id 0 (the oldest)
    try std.testing.expect(d.seen(1000));
    try std.testing.expect(!d.seen(0));
    try std.testing.expect(d.seen(1));
}
