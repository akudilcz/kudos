//! Host tests of src/drivers/gpu/core/push.zig (reached through the gpu_root module-root shim).

const std = @import("std");
const push = @import("testroot").gpu.push;
const Push = push.Push;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "mthd packs OPCODE_METHOD | count=1 | method offset, then the data dword" {
    var buf: [2]u32 = undefined;
    var p = Push.init(&buf);
    p.mthd(0x0200, 0x00000001); // NVC37D_UPDATE = 0x1
    // header = 0 | (1 << 18) | 0x200
    try expectEqualSlices(u32, &[_]u32{ 0x00040200, 0x00000001 }, buf[0..p.n]);
    try expectEqual(@as(u64, 8), p.bytes());
}

test "mthd method offset occupies bits 13:2 (offset >> 2 << 2 drops nothing for dword-aligned methods)" {
    var buf: [2]u32 = undefined;
    var p = Push.init(&buf);
    p.mthd(0x2074, (0 << 16) | 1); // HEAD_SET_RASTER_BLANK2(head 0)
    try expectEqualSlices(u32, &[_]u32{ 0x00042074, 0x00000001 }, buf[0..p.n]);
}

test "mthdRun packs the run length into METHOD_COUNT and appends the values in order" {
    var buf: [5]u32 = undefined;
    var p = Push.init(&buf);
    p.mthdRun(0x2064, &[_]u32{ 0xAAAA0001, 0xBBBB0002, 0xCCCC0003, 0xDDDD0004 });
    // header = 0 | (4 << 18) | 0x2064
    try expectEqualSlices(u32, &[_]u32{ 0x00102064, 0xAAAA0001, 0xBBBB0002, 0xCCCC0003, 0xDDDD0004 }, buf[0..p.n]);
    try expectEqual(@as(u64, 20), p.bytes());
}

test "mthdNonInc uses OPCODE_NONINC (2 << 29) with the same count/offset fields" {
    var buf: [4]u32 = undefined;
    var p = Push.init(&buf);
    p.mthdNonInc(0x0208, &[_]u32{ 0x11, 0x22, 0x33 });
    // header = (2 << 29) | (3 << 18) | 0x208
    try expectEqualSlices(u32, &[_]u32{ 0x400C0208, 0x00000011, 0x00000022, 0x00000033 }, buf[0..p.n]);
}

test "multi-method stream: headers and data interleave in emission order, cursor advances" {
    var buf: [7]u32 = undefined;
    var p = Push.init(&buf);
    p.mthd(0x0300, 0x00000801); // SOR_SET_CONTROL(0)
    p.mthdRun(0x0224, &[_]u32{ 0x05A00D70, 0x00000000 });
    p.mthd(0x0200, 0x00000001); // UPDATE
    try expectEqualSlices(u32, &[_]u32{
        0x00040300, 0x00000801,
        0x00080224, 0x05A00D70,
        0x00000000, 0x00040200,
        0x00000001,
    }, buf[0..p.n]);
    try expectEqual(@as(usize, 7), p.n);
    try expectEqual(@as(u64, 28), p.bytes());
}

test "buffer-full contract: an exactly-sized staging buffer is filled to the last dword" {
    // Push's contract (see init doc comment) is that the CALLER sizes `buf` for the
    // worst case; Push writes through buf[n] with no spare slot required. Filling a
    // buffer to exactly its length must succeed and leave n == buf.len (one dword
    // more would be a safety-checked out-of-bounds panic, i.e. a caller sizing bug).
    var buf: [6]u32 = undefined;
    var p = Push.init(&buf);
    p.mthd(0x0200, 1); // 2 dwords
    p.mthdRun(0x0204, &[_]u32{ 2, 3, 4 }); // 4 dwords
    try expectEqual(@as(usize, buf.len), p.n);
    try expectEqual(@as(u64, 24), p.bytes());
    try expectEqualSlices(u32, &[_]u32{ 0x00040200, 1, 0x000C0204, 2, 3, 4 }, buf[0..]);
}
