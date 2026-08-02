//! Host tests of src/drivers/gl/es/draw.zig.

const std = @import("std");
const draw = @import("draw");
const GLenum = draw.GLenum;
const drawArrays = draw.drawArrays;
const drawElements = draw.drawElements;
const enums = draw.enums;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const gather = draw.gather;
const highestIndex = draw.highestIndex;
const mapIndexType = draw.mapIndexType;
const mapPrim = draw.mapPrim;
const mustStage = draw.mustStage;
const offsetOf = draw.offsetOf;
const stagedSize = draw.stagedSize;
const state = draw.state;

/// A Context wired to nothing: no device, no target, and an allocator that
/// fails on use — these tests must not allocate.
fn testContext() draw.state.Context {
    return draw.state.Context{ .dev = undefined, .target = undefined, .dev_limits = undefined, .alloc = std.testing.failing_allocator };
}

test "all seven primitives are accepted, and desktop GL's quads are not" {
    for ([_]GLenum{
        enums.GL_POINTS,       enums.GL_LINES,     enums.GL_LINE_LOOP,
        enums.GL_LINE_STRIP,   enums.GL_TRIANGLES, enums.GL_TRIANGLE_STRIP,
        enums.GL_TRIANGLE_FAN,
    }) |p| try expect(mapPrim(p) != null);
    try expect(mapPrim(0x0007) == null); // GL_QUADS
    try expect(mapPrim(0x0009) == null); // GL_POLYGON
}

test "8-, 16- and 32-bit indices all map; 32-bit rides OES_element_index_uint (RND-004)" {
    // The extension gles advertises makes GL_UNSIGNED_INT a valid index type, so a
    // model past 65,536 vertices draws instead of falling back to a placeholder.
    try expect(mapIndexType(enums.GL_UNSIGNED_BYTE).? == .u8);
    try expect(mapIndexType(enums.GL_UNSIGNED_SHORT).? == .u16);
    try expect(mapIndexType(enums.GL_UNSIGNED_INT).? == .u32);
    // An unknown token is still INVALID_ENUM — the extension widens the set, not the door.
    try expect(mapIndexType(enums.GL_FLOAT) == null);
    var g = testContext();
    drawElements(&g, enums.GL_TRIANGLES, 3, enums.GL_FLOAT, null);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}

test "a negative count is INVALID_VALUE; a zero count draws nothing, quietly" {
    var g = testContext();
    drawArrays(&g, enums.GL_TRIANGLES, 0, -1);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
    drawArrays(&g, enums.GL_TRIANGLES, -1, 3);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
    drawElements(&g, enums.GL_TRIANGLES, -1, enums.GL_UNSIGNED_SHORT, null);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());

    // Zero is legal and means nothing to do — note the allocator would panic if this
    // reached the staging path.
    drawArrays(&g, enums.GL_TRIANGLES, 0, 0);
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
}

test "no position array means no geometry — and that is not an error" {
    var g = testContext();
    drawArrays(&g, enums.GL_TRIANGLES, 0, 3); // nothing enabled
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
}

test "an array in a buffer, in a native format, is drawn in place" {
    var a = state.ArrayPointer{ .enabled = true, .size = 3, .type = .float, .stride = 12, .buffer = 4 };
    try expect(!mustStage(a)); // the fast path: no copy, no per-frame work
    a.buffer = 0; // client memory
    try expect(mustStage(a));
    a.buffer = 4;
    a.type = .fixed; // no fetcher decodes 16.16, buffer or not
    try expect(mustStage(a));
}

test "gather widens GL_FIXED to float and packs a strided array tightly" {
    // Two 16.16 values per element, 16 bytes apart; the gather must pull them together
    // AND convert. Both are needed and each hides the other's absence.
    var src: [32]u8 = @splat(0);
    std.mem.writeInt(i32, src[0..4], 1 << 16, .little); // 1.0
    std.mem.writeInt(i32, src[4..8], -(1 << 15), .little); // -0.5
    std.mem.writeInt(i32, src[16..20], 2 << 16, .little); // 2.0
    std.mem.writeInt(i32, src[20..24], 3 << 16, .little); // 3.0

    const a = state.ArrayPointer{ .enabled = true, .size = 2, .type = .fixed, .stride = 16 };
    var dst: [16]u8 = undefined;
    gather(&dst, &src, a, 0, 2);

    const f = std.mem.bytesAsSlice(f32, dst[0..16]);
    try expectEqual(@as(f32, 1.0), f[0]);
    try expectEqual(@as(f32, -0.5), f[1]);
    try expectEqual(@as(f32, 2.0), f[2]); // packed at 8, not 16: the stride is gone
    try expectEqual(@as(f32, 3.0), f[3]);
}

test "gather honours `first`, so a draw can start part-way in" {
    var src: [24]u8 = @splat(0);
    for (0..6) |i| std.mem.writeInt(u32, src[i * 4 ..][0..4], @bitCast(@as(f32, @floatFromInt(i))), .little);
    const a = state.ArrayPointer{ .enabled = true, .size = 1, .type = .float, .stride = 4 };
    var dst: [8]u8 = undefined;
    gather(&dst, &src, a, 4, 2); // elements 4 and 5
    const f = std.mem.bytesAsSlice(f32, dst[0..8]);
    try expectEqual(@as(f32, 4), f[0]);
    try expectEqual(@as(f32, 5), f[1]);
}

test "staged size counts the WIDENED element, not the stored one" {
    const fx = state.ArrayPointer{ .enabled = true, .size = 3, .type = .fixed, .stride = 12 };
    try expectEqual(@as(usize, 12 * 4), stagedSize(fx, 4)); // 3 floats x 4
    const b = state.ArrayPointer{ .enabled = true, .size = 3, .type = .byte, .stride = 3 };
    try expectEqual(@as(usize, 3 * 4), stagedSize(b, 4)); // bytes stay bytes
}

test "highestIndex finds the true maximum, whatever order the indices are in" {
    var g = testContext();
    const idx = [_]u16{ 3, 41, 7, 0, 12 };
    const hi = highestIndex(&g, 5, .u16, &idx).?;
    try expectEqual(@as(u32, 41), hi); // an indexed draw must stage 42 vertices

    const b = [_]u8{ 9, 2, 200, 4 };
    try expectEqual(@as(u32, 200), highestIndex(&g, 4, .u8, &b).?);
}

test "highestIndex of a client pointer that is null draws nothing" {
    var g = testContext();
    try expect(highestIndex(&g, 3, .u16, null) == null);
}

test "an array pointer is an OFFSET when a buffer is bound, and an address when not" {
    // Same field, two meanings — the classic GL trap.
    const with_buffer = state.ArrayPointer{ .buffer = 2, .ptr = @ptrFromInt(64) };
    try expectEqual(@as(usize, 64), offsetOf(with_buffer)); // 64 bytes in
    const client = state.ArrayPointer{ .buffer = 0, .ptr = null };
    try expectEqual(@as(usize, 0), offsetOf(client));
}
