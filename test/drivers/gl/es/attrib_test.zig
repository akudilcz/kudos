//! Host tests of src/drivers/gl/es/attrib.zig.

const std = @import("std");
const attrib = @import("attrib");
const DataType = attrib.DataType;
const componentSize = attrib.componentSize;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const idraw = attrib.idraw;
const needsWidening = attrib.needsWidening;
const resolve = attrib.resolve;
const stagedElementSize = attrib.stagedElementSize;

test "a colour's unsigned bytes are normalized — 255 must mean 1.0, not 255.0" {
    const r = resolve(.color, 4, .ubyte).?;
    try expect(r == .native);
    try expect(r.native == .u8x4_unorm);
}

test "a normal's signed bytes are normalized — the specification says so for normals only" {
    // §2.8: "for the normal array... converted as indicated for the corresponding
    // (signed) type in table 2.7". 127 means 1.0.
    try expect(resolve(.normal, 3, .byte).?.native == .i8x3_snorm);
    try expect(resolve(.normal, 3, .short).?.native == .i16x3_snorm);
}

test "a POSITION's signed bytes are RAW — normalizing would collapse the model" {
    // The same GL_BYTE, a different meaning, decided by which attribute it feeds.
    const n = resolve(.normal, 3, .byte).?;
    const p = resolve(.position, 3, .byte).?;
    try expect(n.native == .i8x3_snorm); // -> [-1, 1]
    try expect(p.native == .i8x3); // -> [-128, 127]
    try expect(n.native != p.native); // the distinction this file exists for
}

test "texture coordinates are coordinates, so they are raw too" {
    try expect(resolve(.texcoord0, 2, .short).?.native == .i16x2);
    try expect(resolve(.texcoord1, 4, .byte).?.native == .i8x4);
}

test "GL_FIXED is widened on the CPU whatever it feeds — no fetcher decodes 16.16" {
    for ([_]idraw.AttribSlot{ .position, .normal, .color, .texcoord0, .point_size }) |slot| {
        const r = resolve(slot, if (slot == .point_size) 1 else 3, .fixed).?;
        try expect(r == .widen);
    }
    try expect(needsWidening(.fixed));
    // Everything else the hardware eats as it is.
    for ([_]DataType{ .byte, .ubyte, .short, .ushort, .float }) |t| try expect(!needsWidening(t));
}

test "floats pass straight through at every size" {
    try expect(resolve(.point_size, 1, .float).?.native == .f32x1);
    try expect(resolve(.texcoord0, 2, .float).?.native == .f32x2);
    try expect(resolve(.position, 3, .float).?.native == .f32x3);
    try expect(resolve(.position, 4, .float).?.native == .f32x4);
}

test "a widened array becomes floats, so it grows if it was bytes" {
    try expectEqual(@as(u32, 12), stagedElementSize(3, .fixed)); // 3 x 16.16 -> 3 floats
    try expectEqual(@as(u32, 12), stagedElementSize(3, .float)); // already floats
    try expectEqual(@as(u32, 3), stagedElementSize(3, .byte)); // untouched
    try expectEqual(@as(u32, 6), stagedElementSize(3, .short));
    try expectEqual(@as(u32, 4), stagedElementSize(4, .ubyte));
}

test "componentSize matches the standard's widths — fixed is 32 bits, not 16" {
    try expectEqual(@as(u32, 1), componentSize(.byte));
    try expectEqual(@as(u32, 2), componentSize(.short));
    try expectEqual(@as(u32, 4), componentSize(.fixed)); // 16.16 is a 32-bit integer
    try expectEqual(@as(u32, 4), componentSize(.float));
}

test "every combination table 2.4 allows resolves to something" {
    // If vertex.zig accepts it, this must know what to do with it — a null here is the
    // two files disagreeing, which would surface as a draw that silently vanishes.
    const cases = [_]struct { slot: idraw.AttribSlot, sizes: []const u32, types: []const DataType }{
        .{ .slot = .position, .sizes = &.{ 2, 3, 4 }, .types = &.{ .byte, .short, .fixed, .float } },
        .{ .slot = .normal, .sizes = &.{3}, .types = &.{ .byte, .short, .fixed, .float } },
        .{ .slot = .color, .sizes = &.{4}, .types = &.{ .ubyte, .fixed, .float } },
        .{ .slot = .texcoord0, .sizes = &.{ 2, 3, 4 }, .types = &.{ .byte, .short, .fixed, .float } },
        .{ .slot = .point_size, .sizes = &.{1}, .types = &.{ .fixed, .float } },
    };
    for (cases) |c| {
        for (c.sizes) |size| {
            for (c.types) |t| try expect(resolve(c.slot, size, t) != null);
        }
    }
}
