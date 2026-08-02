//! Host tests of src/drivers/gl/es/enable.zig.

const std = @import("std");
const mod = @import("enable");
const GLboolean = mod.GLboolean;
const GLenum = mod.GLenum;
const disable = mod.disable;
const disableClientState = mod.disableClientState;
const enable = mod.enable;
const enableClientState = mod.enableClientState;
const enums = mod.enums;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const idraw = mod.idraw;
const isEnabled = mod.isEnabled;
const limits = mod.limits;

/// A Context wired to nothing: no device, no target, and an allocator that
/// fails on use — these tests must not allocate.
fn testContext() mod.state.Context {
    return mod.state.Context{ .dev = undefined, .target = undefined, .dev_limits = undefined, .alloc = std.testing.failing_allocator };
}

test "enable and disable move the bit isEnabled reports" {
    var g = testContext();
    try expectEqual(@as(GLboolean, enums.GL_FALSE), isEnabled(&g, enums.GL_DEPTH_TEST));
    enable(&g, enums.GL_DEPTH_TEST);
    try expect(g.caps.depth_test);
    try expectEqual(@as(GLboolean, enums.GL_TRUE), isEnabled(&g, enums.GL_DEPTH_TEST));
    disable(&g, enums.GL_DEPTH_TEST);
    try expectEqual(@as(GLboolean, enums.GL_FALSE), isEnabled(&g, enums.GL_DEPTH_TEST));
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
}

test "dither is the one capability that starts enabled" {
    var g = testContext();
    try expectEqual(@as(GLboolean, enums.GL_TRUE), isEnabled(&g, enums.GL_DITHER));
}

test "GL_LIGHTi is a range, and one past the end is INVALID_ENUM not a clamp" {
    var g = testContext();
    enable(&g, enums.GL_LIGHT0);
    enable(&g, enums.GL_LIGHT0 + 7);
    try expect(g.caps.light[0] and g.caps.light[7]);
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());

    enable(&g, enums.GL_LIGHT0 + limits.MAX_LIGHTS); // one too far
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}

test "GL_CLIP_PLANEi likewise" {
    var g = testContext();
    enable(&g, enums.GL_CLIP_PLANE0 + 5); // the standard's 6th, and its floor
    try expect(g.caps.clip_plane[5]);
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), g.err.get());
    enable(&g, enums.GL_CLIP_PLANE0 + limits.MAX_CLIP_PLANES);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}

test "GL_TEXTURE_2D follows the ACTIVE texture unit, so it is not one global bit" {
    var g = testContext();
    enable(&g, enums.GL_TEXTURE_2D); // unit 0 is active
    try expect(g.caps.texture_2d[0]);
    try expect(!g.caps.texture_2d[1]);

    g.active_texture = 1;
    try expectEqual(@as(GLboolean, enums.GL_FALSE), isEnabled(&g, enums.GL_TEXTURE_2D));
    enable(&g, enums.GL_TEXTURE_2D);
    try expect(g.caps.texture_2d[1]);
}

test "a token that is not a capability is refused and changes nothing" {
    var g = testContext();
    enable(&g, enums.GL_TRIANGLES); // a primitive, not a capability
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
    // Client-array tokens are NOT server capabilities, and vice versa.
    enable(&g, enums.GL_VERTEX_ARRAY);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
    enableClientState(&g, enums.GL_DEPTH_TEST);
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}

test "isEnabled on a bad token reports FALSE as well as recording the error" {
    var g = testContext();
    try expectEqual(@as(GLboolean, enums.GL_FALSE), isEnabled(&g, 0xDEAD));
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), g.err.get());
}

test "client arrays enable independently" {
    var g = testContext();
    enableClientState(&g, enums.GL_VERTEX_ARRAY);
    enableClientState(&g, enums.GL_NORMAL_ARRAY);
    try expect(g.arrays[@intFromEnum(idraw.AttribSlot.position)].enabled);
    try expect(g.arrays[@intFromEnum(idraw.AttribSlot.normal)].enabled);
    try expect(!g.arrays[@intFromEnum(idraw.AttribSlot.color)].enabled);
    disableClientState(&g, enums.GL_VERTEX_ARRAY);
    try expect(!g.arrays[@intFromEnum(idraw.AttribSlot.position)].enabled);
}

test "GL_TEXTURE_COORD_ARRAY follows the CLIENT active unit, not the server one" {
    var g = testContext();
    g.active_texture = 1; // must not matter here
    enableClientState(&g, enums.GL_TEXTURE_COORD_ARRAY);
    try expect(g.arrays[@intFromEnum(idraw.AttribSlot.texcoord0)].enabled);
    try expect(!g.arrays[@intFromEnum(idraw.AttribSlot.texcoord1)].enabled);

    g.client_active_texture = 1;
    enableClientState(&g, enums.GL_TEXTURE_COORD_ARRAY);
    try expect(g.arrays[@intFromEnum(idraw.AttribSlot.texcoord1)].enabled);
}

test "the point-size array is a mandatory extension, and enables like any other" {
    var g = testContext();
    enableClientState(&g, enums.GL_POINT_SIZE_ARRAY_OES);
    try expect(g.arrays[@intFromEnum(idraw.AttribSlot.point_size)].enabled);
}
