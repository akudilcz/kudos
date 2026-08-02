//! Host tests of src/drivers/gl/es/frame.zig.

const std = @import("std");
const frame = @import("frame");
const GLenum = frame.GLenum;
const GLint = frame.GLint;
const enums = frame.enums;
const expectEqual = std.testing.expectEqual;
const pixelStorei = frame.pixelStorei;
const readPixels = frame.readPixels;

/// A Context wired to nothing: no device, no target, and an allocator that
/// fails on use — these tests must not allocate.
fn testContext() frame.state.Context {
    return frame.state.Context{ .dev = undefined, .target = undefined, .dev_limits = undefined, .alloc = std.testing.failing_allocator };
}

test "pixelStorei takes only powers of two up to 8" {
    var g = testContext();
    for ([_]GLint{ 1, 2, 4, 8 }) |v| {
        pixelStorei(&g, enums.GL_PACK_ALIGNMENT, v);
        try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
        try expectEqual(@as(u32, @intCast(v)), g.pack_alignment);
    }
    pixelStorei(&g, enums.GL_PACK_ALIGNMENT, 3);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
    pixelStorei(&g, enums.GL_PACK_ALIGNMENT, 16);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
}

test "ES has only the two pixel-store parameters" {
    var g = testContext();
    pixelStorei(&g, enums.GL_UNPACK_ALIGNMENT, 1);
    try expectEqual(@as(u32, 1), g.unpack_alignment);
    pixelStorei(&g, 0x0D02, 4); // GL_PACK_ROW_LENGTH — desktop GL only
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}

test "readPixels refuses a pair the standard does not guarantee" {
    var g = testContext();
    var buf: [16]u8 = undefined;
    readPixels(&g, 0, 0, 2, 2, enums.GL_RGB, enums.GL_UNSIGNED_BYTE, &buf);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
    readPixels(&g, 0, 0, -1, 2, enums.GL_RGBA, enums.GL_UNSIGNED_BYTE, &buf);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
}

/// A target that only records which ReadFormat the frontend asked for.
const RecordingTarget = struct {
    var got: ?frame.idraw.ReadFormat = null;
    fn readPixels(_: *anyopaque, _: frame.idraw.Rect, fmt: frame.idraw.ReadFormat, _: []u8) frame.idraw.Error!void {
        got = fmt;
    }
};

test "readPixels maps the OES_read_format pair to the swizzle-free read" {
    RecordingTarget.got = null;
    var vt: frame.idraw.IDrawCtx.VTable = undefined;
    vt.readPixels = &RecordingTarget.readPixels;
    var sink: u8 = 0;
    var g = testContext();
    g.target = .{ .ctx = @ptrCast(&sink), .vtable = &vt };
    var buf: [16]u8 = undefined;
    readPixels(&g, 0, 0, 2, 2, frame.unpack.GL_BGRA_EXT, enums.GL_UNSIGNED_BYTE, &buf);
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
    try expectEqual(frame.idraw.ReadFormat.bgra8, RecordingTarget.got.?);
    // The extension names BGRA with UNSIGNED_BYTE only; any other type is refused.
    readPixels(&g, 0, 0, 2, 2, frame.unpack.GL_BGRA_EXT, enums.GL_FLOAT, &buf);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}
