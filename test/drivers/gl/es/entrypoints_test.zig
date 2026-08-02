//! Host tests of the GL ES 1.1 state entry points through the PUBLIC surface
//! (gles = src/drivers/gl/es/gl.zig): the strings, the capability toggles, the
//! get*v readbacks, and texture parameters — driven against a real context on
//! the software rasteriser, exactly as the state suites drive their halves.
//! These are the paths every GL app crosses first; a wrong default or a
//! swallowed INVALID_ENUM here misdraws everything downstream.

const std = @import("std");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

fn withContext(comptime body: fn (g: *gles.Context) anyerror!void) !void {
    const ta = std.testing.allocator;
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = 64, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    gles.beginFrame(&g, 64, 64);
    try body(&g);
}

test "the strings identify the ES 1.1 pipeline and carry every advertised extension" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            const version = std.mem.span(gles.getString(g, gles.GL_VERSION) orelse return error.NoVersion);
            try expect(std.mem.indexOf(u8, version, "1.1") != null);
            try expect((gles.getString(g, gles.GL_VENDOR) orelse return error.NoVendor)[0] != 0);
            try expect((gles.getString(g, gles.GL_RENDERER) orelse return error.NoRenderer)[0] != 0);
            const ext = std.mem.span(gles.getString(g, gles.GL_EXTENSIONS) orelse return error.NoExtensions);
            for ([_][]const u8{
                "GL_OES_read_format",           "GL_OES_compressed_paletted_texture",
                "GL_OES_point_size_array",      "GL_OES_point_sprite",
                "GL_OES_element_index_uint",    "GL_KUDOS_material_maps",
                "GL_EXT_texture_format_BGRA8888",
            }) |tok| try expect(std.mem.indexOf(u8, ext, tok) != null);
            // An unknown name is an error, not a crash and not a lie.
            try expect(gles.getString(g, 0xBEEF) == null);
            try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(g));
        }
    }.body);
}

test "every capability toggles and reports through enable/disable/isEnabled" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            const caps = [_]gles.GLenum{
                gles.GL_LIGHTING,          gles.GL_DEPTH_TEST,
                gles.GL_BLEND,             gles.GL_CULL_FACE,
                gles.GL_TEXTURE_2D,        gles.GL_SCISSOR_TEST,
                gles.GL_FOG,               gles.GL_STENCIL_TEST,
                gles.GL_ALPHA_TEST,        gles.GL_COLOR_LOGIC_OP,
                gles.GL_NORMALIZE,         gles.GL_RESCALE_NORMAL,
                gles.GL_COLOR_MATERIAL,    gles.GL_POLYGON_OFFSET_FILL,
                gles.GL_MULTISAMPLE,       gles.GL_SAMPLE_ALPHA_TO_COVERAGE,
                gles.GL_SAMPLE_ALPHA_TO_ONE, gles.GL_SAMPLE_COVERAGE,
                gles.GL_POINT_SMOOTH,      gles.GL_LINE_SMOOTH,
                gles.GL_POINT_SPRITE_OES,
            };
            for (caps) |cap| {
                gles.enable(g, cap);
                try expectEqual(@as(gles.GLboolean, 1), gles.isEnabled(g, cap));
                gles.disable(g, cap);
                try expectEqual(@as(gles.GLboolean, 0), gles.isEnabled(g, cap));
            }
            // Dither is the one capability the standard starts ON (§6.2).
            try expectEqual(@as(gles.GLboolean, 1), gles.isEnabled(g, gles.GL_DITHER));
            gles.enable(g, 0xBEEF);
            try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(g));
        }
    }.body);
}

test "get*v reads limits and current state back as set" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var iv: [4]gles.GLint = undefined;
            gles.getIntegerv(g, gles.GL_MAX_TEXTURE_SIZE, &iv);
            try expect(iv[0] > 0);
            gles.getIntegerv(g, gles.GL_MAX_LIGHTS, &iv);
            try expect(iv[0] >= 8); // the ES 1.1 minimum

            gles.matrixMode(g, gles.GL_TEXTURE);
            gles.getIntegerv(g, gles.GL_MATRIX_MODE, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_TEXTURE)), iv[0]);
            var fv: [4]gles.GLfloat = undefined;
            gles.getFloatv(g, gles.GL_CURRENT_COLOR, &fv);
            try expectEqual([4]gles.GLfloat{ 1, 1, 1, 1 }, fv);
            var bv: [4]gles.GLboolean = undefined;
            gles.getBooleanv(g, gles.GL_DEPTH_WRITEMASK, &bv);
            try expectEqual(@as(gles.GLboolean, 1), bv[0]); // depth writes start ON
            gles.getIntegerv(g, 0xBEEF, &iv);
            try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(g));
        }
    }.body);
}

test "the texture environment mode round-trips" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_REPLACE);
            var iv: [1]gles.GLint = undefined;
            gles.getTexEnviv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_REPLACE)), iv[0]);
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_MODULATE);
            gles.getTexEnviv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_MODULATE)), iv[0]);
        }
    }.body);
}

test "texture parameters round-trip, and non-ES values are refused" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var tex: [1]gles.GLuint = undefined;
            gles.genTextures(g, 1, &tex);
            gles.bindTexture(g, gles.GL_TEXTURE_2D, tex[0]);
            gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
            var iv: [1]gles.GLint = undefined;
            gles.getTexParameteriv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_NEAREST)), iv[0]);
            gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, gles.GL_CLAMP_TO_EDGE);
            gles.getTexParameteriv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_CLAMP_TO_EDGE)), iv[0]);
            // GL_CLAMP (desktop GL) is not in ES 1.1: refused with an error.
            gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, 0x2900);
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
            // The float/fixed/vector spellings land on the same state.
            gles.texParameterf(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MAG_FILTER, @floatFromInt(gles.GL_LINEAR));
            gles.getTexParameteriv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MAG_FILTER, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_LINEAR)), iv[0]);
            const wrap_t = [_]gles.GLint{@intCast(gles.GL_REPEAT)};
            gles.texParameteriv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_T, &wrap_t);
            gles.getTexParameteriv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_T, &iv);
            try expectEqual(wrap_t[0], iv[0]);
        }
    }.body);
}

// Big enough that the frame's vertex staging must GROW mid-frame (the
// geometric-growth + retire arms in state.zig), static so no test allocator
// plumbing is needed.
var big_verts: [30_000 * 3]f32 = undefined;
var big_colors: [30_000 * 4]f32 = undefined;

test "a state-heavy scene DRAWS through the rasteriser: arrays, texture env modes, fog, points" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var i: usize = 0;
            while (i < 30_000) : (i += 1) {
                const f: f32 = @floatFromInt(i % 60);
                big_verts[i * 3 + 0] = (f - 30) / 30.0;
                big_verts[i * 3 + 1] = (@as(f32, @floatFromInt((i / 60) % 60)) - 30) / 30.0;
                big_verts[i * 3 + 2] = 0;
                big_colors[i * 4 + 0] = 0.8;
                big_colors[i * 4 + 1] = 0.4;
                big_colors[i * 4 + 2] = 0.2;
                big_colors[i * 4 + 3] = 1.0;
            }
            gles.enableClientState(g, gles.GL_VERTEX_ARRAY);
            gles.vertexPointer(g, 3, gles.GL_FLOAT, 0, &big_verts);
            gles.enableClientState(g, gles.GL_COLOR_ARRAY);
            gles.colorPointer(g, 4, gles.GL_FLOAT, 0, &big_colors);

            // A tiny texture with a BLEND environment — the env-colour mix arm.
            var tex: [1]gles.GLuint = undefined;
            gles.genTextures(g, 1, &tex);
            gles.bindTexture(g, gles.GL_TEXTURE_2D, tex[0]);
            const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
            gles.texImage2D(g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 2, 2, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &px);
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_BLEND);
            const envc = [_]gles.GLfloat{ 0.2, 0.4, 0.6, 1.0 };
            gles.texEnvfv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_COLOR, &envc);
            gles.enable(g, gles.GL_TEXTURE_2D);
            gles.enableClientState(g, gles.GL_TEXTURE_COORD_ARRAY);
            gles.texCoordPointer(g, 2, gles.GL_FLOAT, 0, &big_verts); // reuse: any uvs do

            gles.enable(g, gles.GL_FOG);
            gles.enable(g, gles.GL_BLEND);
            gles.enable(g, gles.GL_DEPTH_TEST);
            gles.drawArrays(g, gles.GL_TRIANGLES, 0, 30_000);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));

            // Smooth points ride their own raster arm.
            gles.disable(g, gles.GL_TEXTURE_2D);
            gles.enable(g, gles.GL_POINT_SMOOTH);
            gles.drawArrays(g, gles.GL_POINTS, 0, 512);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));

            // And the readback: a small window through readPixels.
            var out: [4 * 4 * 4]u8 = undefined;
            gles.readPixels(g, 0, 0, 4, 4, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &out);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
        }
    }.body);
}

test "limits, matrices, stacks and pointers all read back through get*v" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var iv: [4]gles.GLint = undefined;
            var fv: [16]gles.GLfloat = undefined;
            for ([_]gles.GLenum{
                gles.GL_SUBPIXEL_BITS,             gles.GL_SAMPLES,
                gles.GL_SAMPLE_BUFFERS,            gles.GL_MAX_CLIP_PLANES,
                gles.GL_MAX_MODELVIEW_STACK_DEPTH, gles.GL_MAX_PROJECTION_STACK_DEPTH,
                gles.GL_MAX_TEXTURE_STACK_DEPTH,   gles.GL_MAX_TEXTURE_UNITS,
                gles.GL_MODELVIEW_STACK_DEPTH,     gles.GL_PROJECTION_STACK_DEPTH,
                gles.GL_TEXTURE_STACK_DEPTH,       gles.GL_ARRAY_BUFFER_BINDING,
                gles.GL_ELEMENT_ARRAY_BUFFER_BINDING, gles.GL_TEXTURE_BINDING_2D,
                gles.GL_IMPLEMENTATION_COLOR_READ_FORMAT_OES,
            }) |pname| gles.getIntegerv(g, pname, &iv);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            for ([_]gles.GLenum{
                gles.GL_POINT_SIZE,        gles.GL_LINE_WIDTH,
                gles.GL_DEPTH_RANGE,       gles.GL_COLOR_CLEAR_VALUE,
                gles.GL_DEPTH_CLEAR_VALUE, gles.GL_MODELVIEW_MATRIX,
                gles.GL_PROJECTION_MATRIX, gles.GL_TEXTURE_MATRIX,
            }) |pname| gles.getFloatv(g, pname, &fv);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            var fx: [16]gles.GLfixed = undefined;
            gles.getFixedv(g, gles.GL_LINE_WIDTH, &fx);
            var pt: [1]?*anyopaque = undefined;
            gles.getPointerv(g, gles.GL_VERTEX_ARRAY_POINTER, &pt);
            var bv: [1]gles.GLboolean = undefined;
            gles.getBooleanv(g, gles.GL_SAMPLE_BUFFERS, &bv);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
        }
    }.body);
}

test "every texture-environment spelling and mode lands on the same state" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var iv: [1]gles.GLint = undefined;
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_DECAL);
            gles.getTexEnviv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_DECAL)), iv[0]);
            gles.texEnvf(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, @floatFromInt(gles.GL_ADD));
            var fv: [4]gles.GLfloat = undefined;
            gles.getTexEnvfv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, &fv);
            try expectEqual(@as(gles.GLfloat, @floatFromInt(gles.GL_ADD)), fv[0]);
            gles.texEnvx(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, @intCast(gles.GL_REPLACE));
            var xv: [4]gles.GLfixed = undefined;
            gles.getTexEnvxv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, &xv);
            try expectEqual(@as(gles.GLfixed, @intCast(gles.GL_REPLACE)), xv[0]);
            // Fixed-point texture parameters ride the same route.
            var tex: [1]gles.GLuint = undefined;
            gles.genTextures(g, 1, &tex);
            gles.bindTexture(g, gles.GL_TEXTURE_2D, tex[0]);
            gles.texParameterx(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, @intCast(gles.GL_REPEAT));
            var pxv: [1]gles.GLfixed = undefined;
            gles.getTexParameterxv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, &pxv);
            try expectEqual(@as(gles.GLfixed, @intCast(gles.GL_REPEAT)), pxv[0]);
            var pfv: [1]gles.GLfloat = undefined;
            gles.getTexParameterfv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, &pfv);
            gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_GENERATE_MIPMAP, 1);
        }
    }.body);
}

test "buffer and texture objects live full lives: data, sub-data, copies, deletion" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var b: [1]gles.GLuint = undefined;
            gles.genBuffers(g, 1, &b);
            gles.bindBuffer(g, gles.GL_ARRAY_BUFFER, b[0]);
            const data = [_]f32{ 0, 1, 2, 3, 4, 5, 6, 7 };
            gles.bufferData(g, gles.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(data)), &data, gles.GL_STATIC_DRAW);
            const sub = [_]f32{ 9, 9 };
            gles.bufferSubData(g, gles.GL_ARRAY_BUFFER, 8, @sizeOf(@TypeOf(sub)), &sub);
            try expectEqual(@as(gles.GLboolean, 1), gles.isBuffer(g, b[0]));
            var iv: [1]gles.GLint = undefined;
            gles.getBufferParameteriv(g, gles.GL_ARRAY_BUFFER, gles.GL_BUFFER_SIZE, &iv);
            try expectEqual(@as(gles.GLint, @sizeOf(@TypeOf(data))), iv[0]);
            gles.deleteBuffers(g, 1, &b);
            try expectEqual(@as(gles.GLboolean, 0), gles.isBuffer(g, b[0]));

            var t: [1]gles.GLuint = undefined;
            gles.genTextures(g, 1, &t);
            gles.bindTexture(g, gles.GL_TEXTURE_2D, t[0]);
            try expectEqual(@as(gles.GLboolean, 1), gles.isTexture(g, t[0]));
            var px4 = [_]u8{128} ** (4 * 4 * 4);
            gles.texImage2D(g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 4, 4, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &px4);
            gles.texSubImage2D(g, gles.GL_TEXTURE_2D, 0, 1, 1, 2, 2, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, px4[0 .. 2 * 2 * 4].ptr);
            gles.copyTexImage2D(g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 0, 0, 4, 4, 0);
            gles.pixelStorei(g, gles.GL_UNPACK_ALIGNMENT, 1);
            gles.deleteTextures(g, 1, &t);
            try expectEqual(@as(gles.GLboolean, 0), gles.isTexture(g, t[0]));
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
        }
    }.body);
}

test "point sprites, material maps and 32-bit elements draw through their arms" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            gles.enableClientState(g, gles.GL_VERTEX_ARRAY);
            gles.vertexPointer(g, 3, gles.GL_FLOAT, 0, &big_verts);
            var tex: [1]gles.GLuint = undefined;
            gles.genTextures(g, 1, &tex);
            gles.bindTexture(g, gles.GL_TEXTURE_2D, tex[0]);
            const px = [_]u8{200} ** (2 * 2 * 4);
            gles.texImage2D(g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 2, 2, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &px);
            gles.enable(g, gles.GL_TEXTURE_2D);
            // Sprites: per-point sizes through the OES pointer, coord replacement on.
            gles.enable(g, gles.GL_POINT_SPRITE_OES);
            var sizes = [_]f32{4} ** 256;
            gles.enableClientState(g, gles.GL_POINT_SIZE_ARRAY_OES);
            gles.pointSizePointerOES(g, gles.GL_FLOAT, 0, &sizes);
            gles.drawArrays(g, gles.GL_POINTS, 0, 256);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            // The PBR material maps extension: bind a metal-rough map and draw
            // lit WITH normals — the interpolated-normal fragment path.
            gles.materialMap(g, gles.GL_METAL_ROUGH_MAP_KUDOS, tex[0]);
            gles.enable(g, gles.GL_LIGHTING);
            gles.enableClientState(g, gles.GL_NORMAL_ARRAY);
            gles.normalPointer(g, gles.GL_FLOAT, 0, &big_verts); // unit-ish normals suffice
            gles.drawArrays(g, gles.GL_TRIANGLES, 0, 300);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            // 32-bit indices: the OES_element_index_uint path.
            var idx: [300]u32 = undefined;
            for (&idx, 0..) |*v, i| v.* = @intCast(i);
            gles.drawElements(g, gles.GL_TRIANGLES, 300, gles.GL_UNSIGNED_INT, &idx);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
        }
    }.body);
}

test "matrices, lights, materials, fog and clip planes take their parameters" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            // The TEXTURE matrix arm: ops route to the active unit's matrix.
            gles.matrixMode(g, gles.GL_TEXTURE);
            gles.loadIdentity(g);
            gles.translatef(g, 0.5, 0.5, 0);
            gles.pushMatrix(g);
            gles.popMatrix(g);
            gles.matrixMode(g, gles.GL_MODELVIEW);
            gles.pushMatrix(g);
            gles.translatef(g, 1, 2, 3);
            gles.popMatrix(g);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            // Lights: a valid parameter lands; an out-of-range light errors.
            const white = [_]gles.GLfloat{ 1, 1, 1, 1 };
            gles.lightfv(g, gles.GL_LIGHT0, gles.GL_DIFFUSE, &white);
            gles.lightfv(g, gles.GL_LIGHT0, gles.GL_POSITION, &white);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            gles.lightfv(g, gles.GL_LIGHT0 - 1, gles.GL_DIFFUSE, &white);
            try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(g));
            gles.lightfv(g, gles.GL_LIGHT0 + 32, gles.GL_DIFFUSE, &white);
            try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(g));
            // Materials: every pname arm, front-and-back only.
            gles.materialfv(g, gles.GL_FRONT_AND_BACK, gles.GL_AMBIENT, &white);
            gles.materialfv(g, gles.GL_FRONT_AND_BACK, gles.GL_DIFFUSE, &white);
            gles.materialfv(g, gles.GL_FRONT_AND_BACK, gles.GL_AMBIENT_AND_DIFFUSE, &white);
            gles.materialfv(g, gles.GL_FRONT_AND_BACK, gles.GL_SPECULAR, &white);
            gles.materialfv(g, gles.GL_FRONT_AND_BACK, gles.GL_EMISSION, &white);
            gles.materialf(g, gles.GL_FRONT_AND_BACK, gles.GL_SHININESS, 32);
            gles.lightModelfv(g, gles.GL_LIGHT_MODEL_AMBIENT, &white);
            const plane = [_]gles.GLfloat{ 0, 1, 0, 0 };
            gles.clipPlanef(g, gles.GL_CLIP_PLANE0, &plane);
            const fog = [_]gles.GLfloat{ 0.5, 0, 0, 0 };
            gles.fogfv(g, gles.GL_FOG_DENSITY, &fog);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
        }
    }.body);
}

test "every minification filter maps, and buffer misuse errors instead of corrupting" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var tex: [1]gles.GLuint = undefined;
            gles.genTextures(g, 1, &tex);
            gles.bindTexture(g, gles.GL_TEXTURE_2D, tex[0]);
            for ([_]gles.GLenum{
                gles.GL_NEAREST,                gles.GL_LINEAR,
                gles.GL_NEAREST_MIPMAP_NEAREST, gles.GL_LINEAR_MIPMAP_NEAREST,
                gles.GL_NEAREST_MIPMAP_LINEAR,  gles.GL_LINEAR_MIPMAP_LINEAR,
            }) |f| {
                gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, @intCast(f));
                var iv: [1]gles.GLint = undefined;
                gles.getTexParameteriv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, &iv);
                try expectEqual(@as(gles.GLint, @intCast(f)), iv[0]);
            }
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            // Buffer misuse: bad target, sub-data past the end, data on no binding.
            var b: [1]gles.GLuint = undefined;
            gles.genBuffers(g, 1, &b);
            gles.bufferData(g, 0xBEEF, 16, null, gles.GL_STATIC_DRAW);
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
            gles.bindBuffer(g, gles.GL_ARRAY_BUFFER, b[0]);
            gles.bufferData(g, gles.GL_ARRAY_BUFFER, 16, null, gles.GL_STATIC_DRAW);
            const four = [_]u8{ 1, 2, 3, 4 };
            gles.bufferSubData(g, gles.GL_ARRAY_BUFFER, 14, 4, &four);
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
            gles.deleteBuffers(g, 1, &b);
        }
    }.body);
}

test "texture parameter and environment misuse errors on every spelling" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var tex: [1]gles.GLuint = undefined;
            gles.genTextures(g, 1, &tex);
            gles.bindTexture(g, gles.GL_TEXTURE_2D, tex[0]);
            gles.texParameteri(g, gles.GL_TEXTURE_2D, 0xBEEF, 1);
            try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(g));
            gles.texParameteri(g, 0xBEEF, gles.GL_TEXTURE_WRAP_S, @intCast(gles.GL_REPEAT));
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
            var iv: [1]gles.GLint = undefined;
            gles.getTexParameteriv(g, gles.GL_TEXTURE_2D, 0xBEEF, &iv);
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
            const wrap = [_]gles.GLfloat{@floatFromInt(gles.GL_CLAMP_TO_EDGE)};
            gles.texParameterfv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_T, &wrap);
            var fx = [_]gles.GLfixed{@intCast(gles.GL_REPEAT)};
            gles.texParameterxv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, &fx);
            gles.getTexParameterxv(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MAG_FILTER, &fx);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));

            gles.texEnvi(g, 0xBEEF, gles.GL_TEXTURE_ENV_MODE, gles.GL_MODULATE);
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, 0xBEEF, 1);
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
            var fv: [4]gles.GLfloat = undefined;
            gles.getTexEnvfv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_COLOR, &fv);
            var xv: [4]gles.GLfixed = undefined;
            gles.getTexEnvxv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_COLOR, &xv);
            const envx = [_]gles.GLfixed{ 1 << 16, 0, 0, 1 << 16 };
            gles.texEnvxv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_COLOR, &envx);
            const envi = [_]gles.GLint{@intCast(gles.GL_DECAL)};
            gles.texEnviv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, &envi);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
        }
    }.body);
}

test "combine sources, scales and the sprite coord-replace getter round-trip" {
    try withContext(struct {
        fn body(g: *gles.Context) !void {
            var iv: [1]gles.GLint = undefined;
            // The COMBINE machine: mode, an alpha source, and a bad source.
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_COMBINE);
            gles.getTexEnviv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_COMBINE)), iv[0]);
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, gles.GL_SRC0_ALPHA, gles.GL_TEXTURE);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, gles.GL_SRC0_ALPHA, 0xBEEF);
            try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(g));
            // BLEND read-back rides the getter's own mode switch.
            gles.texEnvi(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_BLEND);
            gles.getTexEnviv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, &iv);
            try expectEqual(@as(gles.GLint, @intCast(gles.GL_BLEND)), iv[0]);
            // Scales through every spelling; scalar vectors fall through.
            gles.texEnvx(g, gles.GL_TEXTURE_ENV, gles.GL_RGB_SCALE, 2 << 16);
            const onef = [_]gles.GLfloat{1};
            gles.texEnvfv(g, gles.GL_TEXTURE_ENV, gles.GL_RGB_SCALE, &onef);
            const onex = [_]gles.GLfixed{1 << 16};
            gles.texEnvxv(g, gles.GL_TEXTURE_ENV, gles.GL_ALPHA_SCALE, &onex);
            const colx = [_]gles.GLfixed{ 1 << 16, 0, 0, 1 << 16 };
            gles.texEnvxv(g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_COLOR, &colx);
            try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
            // The sprite half: coord replace set + read through the fixed getter.
            gles.texEnvi(g, gles.GL_POINT_SPRITE_OES, gles.GL_COORD_REPLACE_OES, 1);
            var xv: [1]gles.GLfixed = undefined;
            gles.getTexEnvxv(g, gles.GL_POINT_SPRITE_OES, gles.GL_COORD_REPLACE_OES, &xv);
            try expectEqual(@as(gles.GLfixed, 1 << 16), xv[0]);
            // Bad get target and pname: errors, not lies.
            gles.getTexEnviv(g, 0xBEEF, gles.GL_TEXTURE_ENV_MODE, &iv);
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
            gles.getTexEnviv(g, gles.GL_TEXTURE_ENV, 0xBEEF, &iv);
            try expect(gles.getError(g) != gles.GL_NO_ERROR);
        }
    }.body);
}
