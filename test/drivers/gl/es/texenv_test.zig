//! Host tests of src/drivers/gl/es/texenv.zig.

const std = @import("std");
const texenv = @import("texenv");
const GLenum = texenv.GLenum;
const enums = texenv.enums;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const texEnvf = texenv.texEnvf;
const texEnvi = texenv.texEnvi;
const getTexEnvfv = texenv.getTexEnvfv;
const getTexEnviv = texenv.getTexEnviv;

/// A Context wired to nothing: no device, no target, and an allocator that
/// fails on use — these tests must not allocate.
fn testContext() texenv.state.Context {
    return texenv.state.Context{ .dev = undefined, .target = undefined, .dev_limits = undefined, .alloc = std.testing.failing_allocator };
}

test "the scales accept only 1, 2 and 4" {
    var g = testContext();
    texEnvf(&g, enums.GL_TEXTURE_ENV, enums.GL_RGB_SCALE, 2.0);
    try expectEqual(@as(f32, 2.0), g.texenv[0].rgb_scale);
    texEnvf(&g, enums.GL_TEXTURE_ENV, enums.GL_RGB_SCALE, 3.0); // not a legal scale
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), g.err.get());
    try expectEqual(@as(f32, 2.0), g.texenv[0].rgb_scale); // unchanged
}

test "the alpha combiner has no DOT3 — a dot product has no alpha to give" {
    var g = testContext();
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_COMBINE_RGB, enums.GL_DOT3_RGB);
    try expect(g.texenv[0].combine_rgb == .dot3_rgb);
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_COMBINE_ALPHA, enums.GL_DOT3_RGB);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}

test "an alpha operand can only read alpha" {
    var g = testContext();
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_OPERAND0_ALPHA, enums.GL_SRC_COLOR);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_OPERAND0_ALPHA, enums.GL_ONE_MINUS_SRC_ALPHA);
    try expect(g.texenv[0].operand_alpha[0] == .one_minus_src_alpha);
}

test "the three sources are addressed by consecutive tokens" {
    var g = testContext();
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_SRC0_RGB, enums.GL_TEXTURE);
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_SRC1_RGB, enums.GL_PRIMARY_COLOR);
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_SRC2_RGB, enums.GL_PREVIOUS);
    try expect(g.texenv[0].src_rgb[0] == .texture);
    try expect(g.texenv[0].src_rgb[1] == .primary_color);
    try expect(g.texenv[0].src_rgb[2] == .previous);
}

test "the environment is per-unit" {
    var g = testContext();
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_TEXTURE_ENV_MODE, enums.GL_REPLACE);
    g.active_texture = 1;
    try expect(g.texenv[1].mode == .modulate); // untouched default
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_TEXTURE_ENV_MODE, enums.GL_ADD);
    try expect(g.texenv[0].mode == .replace);
    try expect(g.texenv[1].mode == .add);
}

test "OES_point_sprite: COORD_REPLACE sets and reads back per unit" {
    var g = testContext();
    // Set on unit 0, read it back through both numeric flavours.
    texEnvi(&g, enums.GL_POINT_SPRITE_OES, enums.GL_COORD_REPLACE_OES, 1);
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
    try expect(g.texenv[0].coord_replace);
    var i: [1]enums.GLint = undefined;
    getTexEnviv(&g, enums.GL_POINT_SPRITE_OES, enums.GL_COORD_REPLACE_OES, &i);
    try expectEqual(@as(enums.GLint, 1), i[0]);
    var f: [1]enums.GLfloat = undefined;
    getTexEnvfv(&g, enums.GL_POINT_SPRITE_OES, enums.GL_COORD_REPLACE_OES, &f);
    try expectEqual(@as(enums.GLfloat, 1), f[0]);
    // The flag is per unit: unit 1 is untouched...
    g.active_texture = 1;
    getTexEnviv(&g, enums.GL_POINT_SPRITE_OES, enums.GL_COORD_REPLACE_OES, &i);
    try expectEqual(@as(enums.GLint, 0), i[0]);
    // ...and clears independently of unit 1's state.
    g.active_texture = 0;
    texEnvf(&g, enums.GL_POINT_SPRITE_OES, enums.GL_COORD_REPLACE_OES, 0);
    try expect(!g.texenv[0].coord_replace);
}

test "OES_point_sprite: the target carries exactly one pname" {
    var g = testContext();
    // Any other pname on the point-sprite target is INVALID_ENUM (the extension
    // defines only COORD_REPLACE there)...
    texEnvi(&g, enums.GL_POINT_SPRITE_OES, enums.GL_TEXTURE_ENV_MODE, @bitCast(enums.GL_MODULATE));
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
    // ...and COORD_REPLACE on the ordinary texenv target is equally refused.
    texEnvi(&g, enums.GL_TEXTURE_ENV, enums.GL_COORD_REPLACE_OES, 1);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}
