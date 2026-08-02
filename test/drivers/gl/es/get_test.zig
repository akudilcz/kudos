//! Host tests of src/drivers/gl/es/get.zig.

const std = @import("std");
const get = @import("get");
const GLboolean = get.GLboolean;
const GLenum = get.GLenum;
const GLfixed = get.GLfixed;
const GLfloat = get.GLfloat;
const GLint = get.GLint;
const enums = get.enums;
const expectEqual = std.testing.expectEqual;
const getBooleanv = get.getBooleanv;
const getFixedv = get.getFixedv;
const getFloatv = get.getFloatv;
const getIntegerv = get.getIntegerv;
const matrix = get.matrix;

/// A Context wired to nothing (failing allocator — these tests must not
/// allocate) with the real device limits the 4090 driver reports.
fn testContext() get.state.Context {
    return get.state.Context{ .dev = undefined, .target = undefined, .alloc = std.testing.failing_allocator, .dev_limits = .{
        .max_texture_size = 8192,
        .texture_units = 2,
        .samples = 8,
        .subpixel_bits = 8,
    } };
}

test "a float read as an integer ROUNDS — the depth clear value is 1, not 0" {
    var g = testContext();
    var i: [1]GLint = undefined;
    getIntegerv(&g, enums.GL_DEPTH_CLEAR_VALUE, &i);
    try expectEqual(@as(GLint, 1), i[0]); // 1.0 rounds to 1; truncation would give 1 too
    g.clear_depth = 0.6;
    getIntegerv(&g, enums.GL_DEPTH_CLEAR_VALUE, &i);
    try expectEqual(@as(GLint, 1), i[0]); // 0.6 ROUNDS to 1; truncation would give 0
    g.clear_depth = 0.4;
    getIntegerv(&g, enums.GL_DEPTH_CLEAR_VALUE, &i);
    try expectEqual(@as(GLint, 0), i[0]);
}

test "any non-zero value reads as TRUE" {
    var g = testContext();
    var b: [4]GLboolean = undefined;
    getBooleanv(&g, enums.GL_CURRENT_COLOR, &b); // white: 1,1,1,1
    try expectEqual([4]GLboolean{ 1, 1, 1, 1 }, b);
    g.color = .{ 0, 0.004, 0, 1 }; // a value that would ROUND to zero as an integer...
    getBooleanv(&g, enums.GL_CURRENT_COLOR, &b);
    try expectEqual([4]GLboolean{ 0, 1, 0, 1 }, b); // ...is still TRUE, being non-zero
}

test "implementation-dependent values come from the device, not from a constant here" {
    var g = testContext();
    var i: [1]GLint = undefined;
    getIntegerv(&g, enums.GL_MAX_TEXTURE_SIZE, &i);
    try expectEqual(@as(GLint, 8192), i[0]);
    g.dev_limits.max_texture_size = 2048; // a different device
    getIntegerv(&g, enums.GL_MAX_TEXTURE_SIZE, &i);
    try expectEqual(@as(GLint, 2048), i[0]);
}

test "the standard's floors are reported at or above their minimums" {
    var g = testContext();
    var i: [1]GLint = undefined;
    getIntegerv(&g, enums.GL_MAX_LIGHTS, &i);
    try expectEqual(@as(GLint, 8), i[0]);
    getIntegerv(&g, enums.GL_MAX_CLIP_PLANES, &i);
    try expectEqual(@as(GLint, 6), i[0]);
    getIntegerv(&g, enums.GL_MAX_MODELVIEW_STACK_DEPTH, &i);
    try expectEqual(@as(GLint, 16), i[0]);
}

test "a matrix reads back as its 16 components, in the order it was loaded" {
    var g = testContext();
    var f: [16]GLfloat = undefined;
    getFloatv(&g, enums.GL_MODELVIEW_MATRIX, &f);
    try expectEqual(matrix.IDENTITY, f);
}

test "a token read as fixed-point is NOT scaled" {
    var g = testContext();
    var x: [1]GLfixed = undefined;
    getFixedv(&g, enums.GL_MATRIX_MODE, &x);
    // GL_MODELVIEW itself, not GL_MODELVIEW * 65536 (spec §2.3).
    try expectEqual(@as(GLfixed, @intCast(enums.GL_MODELVIEW)), x[0]);
}

test "a float read as fixed-point IS scaled" {
    var g = testContext();
    var x: [1]GLfixed = undefined;
    getFixedv(&g, enums.GL_LINE_WIDTH, &x);
    try expectEqual(@as(GLfixed, 65536), x[0]); // 1.0
}

test "an unknown token records INVALID_ENUM and writes nothing" {
    var g = testContext();
    var i: [1]GLint = .{0x5A};
    getIntegerv(&g, 0xDEAD, &i);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
    try expectEqual(@as(GLint, 0x5A), i[0]); // untouched
}

test "OES_read_format names a second format, as the mandatory extension requires" {
    var g = testContext();
    var i: [1]GLint = undefined;
    getIntegerv(&g, enums.GL_IMPLEMENTATION_COLOR_READ_FORMAT_OES, &i);
    try expectEqual(@as(GLint, @intCast(get.unpack.GL_BGRA_EXT)), i[0]);
    getIntegerv(&g, enums.GL_IMPLEMENTATION_COLOR_READ_TYPE_OES, &i);
    try expectEqual(@as(GLint, @intCast(enums.GL_UNSIGNED_BYTE)), i[0]);
}
