//! Host tests of src/drivers/gl/es/vertex.zig.

const std = @import("std");
const vertex = @import("vertex");
const GLenum = vertex.GLenum;
const colorPointer = vertex.colorPointer;
const enums = vertex.enums;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const normalPointer = vertex.normalPointer;
const pointSizePointerOES = vertex.pointSizePointerOES;
const texCoordPointer = vertex.texCoordPointer;
const typeSize = vertex.typeSize;
const vertexPointer = vertex.vertexPointer;

/// A Context wired to nothing: no device, no target, and an allocator that
/// fails on use — these tests must not allocate.
fn testContext() vertex.state.Context {
    return vertex.state.Context{ .dev = undefined, .target = undefined, .dev_limits = undefined, .alloc = std.testing.failing_allocator };
}

/// The array-pointer record the context holds for one attribute slot.
fn arrayOf(g: *vertex.state.Context, s: vertex.idraw.AttribSlot) vertex.state.ArrayPointer {
    return g.arrays[@intFromEnum(s)];
}

test "a stride of zero means tightly packed, and is resolved here" {
    var g = testContext();
    var data: [64]u8 = undefined;
    vertexPointer(&g, 3, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(u32, 12), arrayOf(&g, .position).stride); // 3 floats
    colorPointer(&g, 4, enums.GL_UNSIGNED_BYTE, 0, &data);
    try expectEqual(@as(u32, 4), arrayOf(&g, .color).stride); // 4 bytes
    normalPointer(&g, enums.GL_SHORT, 0, &data);
    try expectEqual(@as(u32, 6), arrayOf(&g, .normal).stride); // 3 shorts
}

test "an explicit stride is kept as given" {
    var g = testContext();
    var data: [64]u8 = undefined;
    vertexPointer(&g, 3, enums.GL_FLOAT, 32, &data);
    try expectEqual(@as(u32, 32), arrayOf(&g, .position).stride);
}

test "the buffer binding is captured when the pointer is set, not at draw time" {
    var g = testContext();
    var data: [64]u8 = undefined;
    g.array_buffer = 7;
    vertexPointer(&g, 3, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(u32, 7), arrayOf(&g, .position).buffer);

    g.array_buffer = 9; // rebinding afterwards must NOT move the array
    try expectEqual(@as(u32, 7), arrayOf(&g, .position).buffer);

    // The next pointer set does pick up the new binding.
    normalPointer(&g, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(u32, 9), arrayOf(&g, .normal).buffer);
}

test "zero binding means client memory, and the pointer is kept" {
    var g = testContext();
    var data: [64]u8 = undefined;
    vertexPointer(&g, 3, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(u32, 0), arrayOf(&g, .position).buffer);
    try expect(arrayOf(&g, .position).ptr != null);
}

test "each attribute accepts only its own sizes" {
    var g = testContext();
    var data: [64]u8 = undefined;
    // Position: 2..4, never 1.
    vertexPointer(&g, 1, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
    vertexPointer(&g, 5, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
    // Colour: exactly 4.
    colorPointer(&g, 3, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
}

test "each attribute accepts only its own types" {
    var g = testContext();
    var data: [64]u8 = undefined;
    // A colour may not be signed bytes.
    colorPointer(&g, 4, enums.GL_BYTE, 0, &data);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
    // A point size may not be an integer type.
    pointSizePointerOES(&g, enums.GL_SHORT, 0, &data);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
    // But a position may be shorts.
    vertexPointer(&g, 3, enums.GL_SHORT, 0, &data);
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
}

test "a negative stride is refused" {
    var g = testContext();
    var data: [64]u8 = undefined;
    vertexPointer(&g, 3, enums.GL_FLOAT, -4, &data);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
}

test "texCoordPointer follows the client active unit" {
    var g = testContext();
    var data: [64]u8 = undefined;
    texCoordPointer(&g, 2, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(u32, 8), arrayOf(&g, .texcoord0).stride);
    g.client_active_texture = 1;
    texCoordPointer(&g, 4, enums.GL_FLOAT, 0, &data);
    try expectEqual(@as(u32, 16), arrayOf(&g, .texcoord1).stride);
    try expectEqual(@as(u32, 8), arrayOf(&g, .texcoord0).stride); // untouched
}

test "setting a pointer does not enable the array — that is glEnableClientState's job" {
    var g = testContext();
    var data: [64]u8 = undefined;
    vertexPointer(&g, 3, enums.GL_FLOAT, 0, &data);
    try expect(!arrayOf(&g, .position).enabled);
}

test "typeSize matches the standard's widths" {
    try expectEqual(@as(u32, 1), typeSize(.byte));
    try expectEqual(@as(u32, 1), typeSize(.ubyte));
    try expectEqual(@as(u32, 2), typeSize(.short));
    try expectEqual(@as(u32, 2), typeSize(.ushort));
    try expectEqual(@as(u32, 4), typeSize(.fixed)); // 16.16 is 32 bits
    try expectEqual(@as(u32, 4), typeSize(.float));
}
