//! Pixels, on the host.
//!
//! These drive the real `gles` API into a software rasterizer that decodes the same
//! constant buffer the shaders will, and then look at what came out. It is the only
//! place in the tree where the question "does this actually draw the right thing?" gets
//! an answer without a 4090.
//!
//! Every test below would pass trivially against DrawSim, because DrawSim reads nothing.
//! That is the point: these check the ARITHMETIC — that the matrix multiplies the way GL
//! says, that light 7 lands where the shader looks for it, that the texture environment
//! decodes to what it encoded. A wrong answer here is a picture that is wrong, and the
//! pixel says so.
//!
//! Grounding: the OpenGL ES 1.1 specification.

const std = @import("std");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const ta = std.testing.allocator;

const W: u32 = 64;
const H: u32 = 64;

const Scene = struct {
    dev: raster.Soft,
    g: gles.Context,

    fn init(self: *Scene) !void {
        self.dev = .{ .alloc = ta };
        idraw.device = self.dev.iface();
        self.g = gles.createContext(ta, .{ .win_base = 0, .stride_px = W, .off_x = 0, .off_y = 0 }) orelse
            return error.NoDevice;
        gles.beginFrame(&self.g, W, H);
        gles.viewport(&self.g, 0, 0, W, H);
        gles.clearColor(&self.g, 0, 0, 0, 1);
        gles.clearDepthf(&self.g, 1);
        gles.clear(&self.g, gles.GL_COLOR_BUFFER_BIT | gles.GL_DEPTH_BUFFER_BIT);
        // A projection that maps [-1, 1] straight onto the viewport, so a test can put a
        // vertex where it wants it and predict the pixel.
        gles.matrixMode(&self.g, gles.GL_PROJECTION);
        gles.loadIdentity(&self.g);
        gles.orthof(&self.g, -1, 1, -1, 1, -1, 1);
        gles.matrixMode(&self.g, gles.GL_MODELVIEW);
        gles.loadIdentity(&self.g);
    }

    fn deinit(self: *Scene) void {
        self.g.deinit();
        self.dev.deinit();
        idraw.device = null;
    }

    fn ctx(self: *Scene) *raster.SoftCtx {
        return @ptrCast(@alignCast(self.g.target.ctx));
    }

    /// BGRA at a pixel.
    fn at(self: *Scene, x: u32, y: u32) [4]u8 {
        return self.ctx().pixel(x, y);
    }

    fn noError(self: *Scene) !void {
        try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&self.g));
    }
};

/// A quad covering the whole clip cube, from client memory, as two triangles.
fn fullQuad(g: *gles.Context) void {
    const S = struct {
        // Counter-clockwise in GL's y-up convention.
        const pos = [_]f32{
            -1, -1, 0, 1, -1, 0, 1,  1, 0,
            -1, -1, 0, 1, 1,  0, -1, 1, 0,
        };
    };
    gles.enableClientState(g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(g, 3, gles.GL_FLOAT, 0, &S.pos);
}

test "a red quad is red — the pipeline draws something at all" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    fullQuad(&s.g);
    gles.color4f(&s.g, 1, 0, 0, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();

    // BGRA: red is (0, 0, 255).
    try expectEqual([4]u8{ 0, 0, 255, 255 }, s.at(32, 32));
    try expectEqual([4]u8{ 0, 0, 255, 255 }, s.at(1, 1));
}

test "the clear reaches the pixels, and a draw covers it" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    // Cleared to black before any draw.
    try expectEqual([4]u8{ 0, 0, 0, 255 }, s.at(32, 32));

    gles.clearColor(&s.g, 0, 1, 0, 1);
    gles.clear(&s.g, gles.GL_COLOR_BUFFER_BIT);
    try expectEqual([4]u8{ 0, 255, 0, 255 }, s.at(32, 32)); // BGRA green
}

test "y is not flipped end to end: GL's TOP is the framebuffer's top row" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    // A triangle in the UPPER half of GL's clip space (y > 0).
    const pos = [_]f32{ -1, 0.1, 0, 1, 0.1, 0, 0, 1, 0 };
    gles.enableClientState(&s.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&s.g, 3, gles.GL_FLOAT, 0, &pos);
    gles.color4f(&s.g, 1, 1, 1, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 3);
    try s.noError();

    // GL's +y is UP, and the framebuffer's row 0 is the TOP. So this must land in the
    // low rows and leave the high ones black. Get the clip correction backwards and this
    // is exactly inverted — the bug a picture catches and a unit test does not.
    try expect(s.at(32, 8)[1] > 128); // near the top: drawn
    try expectEqual(@as(u8, 0), s.at(32, 56)[1]); // near the bottom: untouched
}

test "the modelview matrix actually moves geometry" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    // A small quad at the origin, translated to the right.
    const pos = [_]f32{ -0.2, -0.2, 0, 0.2, -0.2, 0, 0.2, 0.2, 0, -0.2, -0.2, 0, 0.2, 0.2, 0, -0.2, 0.2, 0 };
    gles.enableClientState(&s.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&s.g, 3, gles.GL_FLOAT, 0, &pos);
    gles.color4f(&s.g, 1, 1, 1, 1);
    gles.translatef(&s.g, 0.5, 0, 0);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();

    // It moved: the centre is empty, and x = +0.5 (pixel 48) is lit.
    try expectEqual(@as(u8, 0), s.at(32, 32)[0]);
    try expect(s.at(48, 32)[0] > 128);
}

test "depth test: the near quad wins wherever they overlap" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    gles.enable(&s.g, gles.GL_DEPTH_TEST);

    // glOrtho(near = -1, far = 1) maps eye z = +1 onto the NEAR plane and z = -1 onto
    // the far one — the sign catches everybody. Both quads sit INSIDE the range: a
    // fragment exactly at the far plane has depth 1.0, and GL_LESS against a 1.0 clear
    // rejects it, which is correct and would make this test about the wrong thing.
    // Draw FAR red first, then NEAR green.
    const far = [_]f32{ -1, -1, -0.5, 1, -1, -0.5, 1, 1, -0.5, -1, -1, -0.5, 1, 1, -0.5, -1, 1, -0.5 };
    gles.enableClientState(&s.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&s.g, 3, gles.GL_FLOAT, 0, &far);
    gles.color4f(&s.g, 1, 0, 0, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try expectEqual([4]u8{ 0, 0, 255, 255 }, s.at(32, 32)); // red

    const near = [_]f32{ -1, -1, 0.5, 1, -1, 0.5, 1, 1, 0.5, -1, -1, 0.5, 1, 1, 0.5, -1, 1, 0.5 };
    gles.vertexPointer(&s.g, 3, gles.GL_FLOAT, 0, &near);
    gles.color4f(&s.g, 0, 1, 0, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try expectEqual([4]u8{ 0, 255, 0, 255 }, s.at(32, 32)); // green won

    // And the far one cannot come back over it.
    gles.vertexPointer(&s.g, 3, gles.GL_FLOAT, 0, &far);
    gles.color4f(&s.g, 1, 0, 0, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try expectEqual([4]u8{ 0, 255, 0, 255 }, s.at(32, 32)); // still green
    try s.noError();
}

test "blending: half alpha over black is half brightness" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    gles.enable(&s.g, gles.GL_BLEND);
    gles.blendFunc(&s.g, gles.GL_SRC_ALPHA, gles.GL_ONE_MINUS_SRC_ALPHA);
    fullQuad(&s.g);
    gles.color4f(&s.g, 1, 1, 1, 0.5);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();

    const p = s.at(32, 32);
    try expect(p[0] > 120 and p[0] < 136); // ~half of 255, over black
}

test "a texture is sampled, and MODULATE multiplies it by the colour" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    // A 1x1 mid-grey texture.
    var tex: gles.GLuint = 0;
    gles.genTextures(&s.g, 1, @ptrCast(&tex));
    gles.bindTexture(&s.g, gles.GL_TEXTURE_2D, tex);
    const grey = [_]u8{ 128, 128, 128, 255 };
    gles.pixelStorei(&s.g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(&s.g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 1, 1, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &grey);
    gles.texParameteri(&s.g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    gles.enable(&s.g, gles.GL_TEXTURE_2D);

    const uv = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    fullQuad(&s.g);
    gles.enableClientState(&s.g, gles.GL_TEXTURE_COORD_ARRAY);
    gles.texCoordPointer(&s.g, 2, gles.GL_FLOAT, 0, &uv);
    gles.color4f(&s.g, 1, 1, 1, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();

    // MODULATE is the DEFAULT environment: white x grey = grey.
    const p = s.at(32, 32);
    try expect(p[0] > 120 and p[0] < 136);

    // Halve the colour and it modulates again: grey x half = quarter.
    gles.color4f(&s.g, 0.5, 0.5, 0.5, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    const q = s.at(32, 32);
    try expect(q[0] > 56 and q[0] < 72);
}

test "REPLACE ignores the colour entirely — the environment is really read" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    var tex: gles.GLuint = 0;
    gles.genTextures(&s.g, 1, @ptrCast(&tex));
    gles.bindTexture(&s.g, gles.GL_TEXTURE_2D, tex);
    const red = [_]u8{ 255, 0, 0, 255 }; // RGBA red
    gles.pixelStorei(&s.g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(&s.g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 1, 1, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &red);
    gles.texParameteri(&s.g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    gles.enable(&s.g, gles.GL_TEXTURE_2D);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_REPLACE);

    const uv = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    fullQuad(&s.g);
    gles.enableClientState(&s.g, gles.GL_TEXTURE_COORD_ARRAY);
    gles.texCoordPointer(&s.g, 2, gles.GL_FLOAT, 0, &uv);
    gles.color4f(&s.g, 0, 0, 1, 1); // blue, which REPLACE must ignore
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();

    // The texel wins: red, not blue, not magenta.
    try expectEqual([4]u8{ 0, 0, 255, 255 }, s.at(32, 32));
}

test "the COMBINE bytecode round-trips through a real fragment — the loop is closed" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    var tex: gles.GLuint = 0;
    gles.genTextures(&s.g, 1, @ptrCast(&tex));
    gles.bindTexture(&s.g, gles.GL_TEXTURE_2D, tex);
    const half = [_]u8{ 128, 128, 128, 255 };
    gles.pixelStorei(&s.g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(&s.g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 1, 1, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &half);
    gles.texParameteri(&s.g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    gles.enable(&s.g, gles.GL_TEXTURE_2D);

    // COMBINE: ADD the texture to the primary colour. uniforms.zig encodes this into
    // four words; Soft decodes them. Nothing else in the tree reads that encoding.
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_COMBINE);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_COMBINE_RGB, gles.GL_ADD);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_SRC0_RGB, gles.GL_TEXTURE);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_OPERAND0_RGB, gles.GL_SRC_COLOR);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_SRC1_RGB, gles.GL_PRIMARY_COLOR);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_OPERAND1_RGB, gles.GL_SRC_COLOR);

    const uv = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    fullQuad(&s.g);
    gles.enableClientState(&s.g, gles.GL_TEXTURE_COORD_ARRAY);
    gles.texCoordPointer(&s.g, 2, gles.GL_FLOAT, 0, &uv);
    gles.color4f(&s.g, 0.25, 0.25, 0.25, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();

    // 0.5 + 0.25 = 0.75 -> ~191. Neither operand alone, and not their product.
    const p = s.at(32, 32);
    try expect(p[0] > 182 and p[0] < 200);
}

test "RGB_SCALE really scales — the shift survives the encoding" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    var tex: gles.GLuint = 0;
    gles.genTextures(&s.g, 1, @ptrCast(&tex));
    gles.bindTexture(&s.g, gles.GL_TEXTURE_2D, tex);
    const quarter = [_]u8{ 64, 64, 64, 255 };
    gles.pixelStorei(&s.g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(&s.g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 1, 1, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &quarter);
    gles.texParameteri(&s.g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    gles.enable(&s.g, gles.GL_TEXTURE_2D);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_COMBINE);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_COMBINE_RGB, gles.GL_REPLACE);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_SRC0_RGB, gles.GL_TEXTURE);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_OPERAND0_RGB, gles.GL_SRC_COLOR);
    gles.texEnvf(&s.g, gles.GL_TEXTURE_ENV, gles.GL_RGB_SCALE, 4.0);

    const uv = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    fullQuad(&s.g);
    gles.enableClientState(&s.g, gles.GL_TEXTURE_COORD_ARRAY);
    gles.texCoordPointer(&s.g, 2, gles.GL_FLOAT, 0, &uv);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();

    // 0.25 x 4 = 1.0. Without the scale it would be 64.
    try expect(s.at(32, 32)[0] > 250);
}

test "lighting: a lit quad facing the light is bright, and facing away is not" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    gles.enable(&s.g, gles.GL_LIGHTING);
    gles.enable(&s.g, gles.GL_LIGHT0);
    // A directional light straight down +Z, at the quad's face.
    const dir = [_]f32{ 0, 0, 1, 0 };
    gles.lightfv(&s.g, gles.GL_LIGHT0, gles.GL_POSITION, &dir);
    const white = [_]f32{ 1, 1, 1, 1 };
    gles.lightfv(&s.g, gles.GL_LIGHT0, gles.GL_DIFFUSE, &white);
    gles.materialfv(&s.g, gles.GL_FRONT_AND_BACK, gles.GL_DIFFUSE, &white);

    fullQuad(&s.g);
    gles.enableClientState(&s.g, gles.GL_NORMAL_ARRAY);
    const facing = [_]f32{ 0, 0, 1 } ** 6;
    gles.normalPointer(&s.g, gles.GL_FLOAT, 0, &facing);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();
    try expect(s.at(32, 32)[0] > 240); // N.L = 1

    // Turn the normals away and the diffuse term vanishes.
    gles.clear(&s.g, gles.GL_COLOR_BUFFER_BIT);
    const away = [_]f32{ 0, 0, -1 } ** 6;
    gles.normalPointer(&s.g, gles.GL_FLOAT, 0, &away);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    // Not black: the standard's default scene ambient (0.2) times the default material
    // ambient (0.2) is 0.04, and every lit fragment gets it whatever the normal does.
    // Asserting zero here would be asserting a bug.
    try expect(s.at(32, 32)[0] < 20);
    try expect(s.at(32, 32)[0] > 0);
}

test "light 7 alone lights the scene — the compaction is real, not just encoded" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    gles.enable(&s.g, gles.GL_LIGHTING);
    // ONLY light 7. The shader's slot 0 must receive it, or this renders black.
    gles.enable(&s.g, gles.GL_LIGHT0 + 7);
    const dir = [_]f32{ 0, 0, 1, 0 };
    gles.lightfv(&s.g, gles.GL_LIGHT0 + 7, gles.GL_POSITION, &dir);
    const white = [_]f32{ 1, 1, 1, 1 };
    gles.lightfv(&s.g, gles.GL_LIGHT0 + 7, gles.GL_DIFFUSE, &white);
    gles.materialfv(&s.g, gles.GL_FRONT_AND_BACK, gles.GL_DIFFUSE, &white);

    fullQuad(&s.g);
    gles.enableClientState(&s.g, gles.GL_NORMAL_ARRAY);
    const facing = [_]f32{ 0, 0, 1 } ** 6;
    gles.normalPointer(&s.g, gles.GL_FLOAT, 0, &facing);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();
    try expect(s.at(32, 32)[0] > 240);
}

test "culling removes the back face, and front-face winding decides which that is" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    gles.enable(&s.g, gles.GL_CULL_FACE);
    gles.cullFace(&s.g, gles.GL_BACK);

    fullQuad(&s.g); // wound counter-clockwise in GL's convention
    gles.color4f(&s.g, 1, 1, 1, 1);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try expect(s.at(32, 32)[0] > 240); // CCW is front by default: drawn

    // Declare CW to be the front, and the same quad is now a back face.
    gles.clear(&s.g, gles.GL_COLOR_BUFFER_BIT);
    gles.frontFace(&s.g, gles.GL_CW);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try expectEqual(@as(u8, 0), s.at(32, 32)[0]); // culled
    try s.noError();
}

test "the scissor box clips, in the framebuffer's convention" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    gles.enable(&s.g, gles.GL_SCISSOR_TEST);
    // GL's y is up: this is the BOTTOM-left quarter.
    gles.scissor(&s.g, 0, 0, 32, 32);
    gles.clearColor(&s.g, 1, 1, 1, 1);
    gles.clear(&s.g, gles.GL_COLOR_BUFFER_BIT);
    try s.noError();

    // Which is the framebuffer's BOTTOM-left: high rows, low columns.
    try expectEqual(@as(u8, 255), s.at(16, 48)[0]);
    try expectEqual(@as(u8, 0), s.at(16, 16)[0]); // top-left: untouched
    try expectEqual(@as(u8, 0), s.at(48, 48)[0]); // bottom-right: untouched
}

test "a fixed-point program draws the same picture as a floating-point one" {
    // The Common profile's whole promise: a Common-Lite program runs unchanged.
    var a: Scene = undefined;
    try a.init();
    fullQuad(&a.g);
    gles.color4f(&a.g, 1, 0.5, 0.25, 1);
    gles.translatef(&a.g, 0.25, 0, 0);
    gles.drawArrays(&a.g, gles.GL_TRIANGLES, 0, 6);
    const float_px = a.at(40, 32);
    a.deinit();

    var b: Scene = undefined;
    try b.init();
    defer b.deinit();
    fullQuad(&b.g);
    gles.color4x(&b.g, 1 << 16, 1 << 15, 1 << 14, 1 << 16); // 1.0, 0.5, 0.25, 1.0
    gles.translatex(&b.g, 1 << 14, 0, 0); // 0.25
    gles.drawArrays(&b.g, gles.GL_TRIANGLES, 0, 6);
    const fixed_px = b.at(40, 32);

    try expectEqual(float_px, fixed_px);
}

test "an indexed draw from buffer objects paints the same quad as a client array" {
    var a: Scene = undefined;
    try a.init();
    fullQuad(&a.g);
    gles.color4f(&a.g, 0.2, 0.4, 0.6, 1);
    gles.drawArrays(&a.g, gles.GL_TRIANGLES, 0, 6);
    const client_px = a.at(32, 32);
    a.deinit();

    var b: Scene = undefined;
    try b.init();
    defer b.deinit();
    // The same four corners, indexed, out of VRAM.
    const verts = [_]f32{ -1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0 };
    const idx = [_]u16{ 0, 1, 2, 0, 2, 3 };
    var bufs = [_]gles.GLuint{ 0, 0 };
    gles.genBuffers(&b.g, 2, &bufs);
    gles.bindBuffer(&b.g, gles.GL_ARRAY_BUFFER, bufs[0]);
    gles.bufferData(&b.g, gles.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gles.GL_STATIC_DRAW);
    gles.bindBuffer(&b.g, gles.GL_ELEMENT_ARRAY_BUFFER, bufs[1]);
    gles.bufferData(&b.g, gles.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(idx)), &idx, gles.GL_STATIC_DRAW);
    gles.enableClientState(&b.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&b.g, 3, gles.GL_FLOAT, 0, null);
    gles.color4f(&b.g, 0.2, 0.4, 0.6, 1);
    gles.drawElements(&b.g, gles.GL_TRIANGLES, 6, gles.GL_UNSIGNED_SHORT, null);
    try b.noError();

    // The fast path and the staged path must agree, or one of them is lying.
    try expectEqual(client_px, b.at(32, 32));
}

// ── the physically-based maps path (GL_KUDOS_material_maps, APP-011) ─────────

/// A 1×1 RGBA texture, uploaded and left bound to GL_TEXTURE_2D.
fn tex1x1(g: *gles.Context, rgba: [4]u8) gles.GLuint {
    var t: gles.GLuint = 0;
    gles.genTextures(g, 1, @ptrCast(&t));
    gles.bindTexture(g, gles.GL_TEXTURE_2D, t);
    gles.pixelStorei(g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 1, 1, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &rgba);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    return t;
}

/// One directional head-on light and a scene ambient, the quad pushed to z=-2
/// so the fragment's eye vector is well defined. Depth test stays off: the
/// ortho projection maps z=-2 outside [0,1] and this suite tests shading.
fn litSetup(g: *gles.Context, light_rgb: f32, ambient_rgb: f32) void {
    gles.enable(g, gles.GL_LIGHTING);
    gles.enable(g, gles.GL_LIGHT0);
    const dir = [4]f32{ 0, 0, 1, 0 }; // FROM the surface TOWARD the light: head-on
    gles.lightfv(g, gles.GL_LIGHT0, gles.GL_POSITION, &dir);
    const lc = [4]f32{ light_rgb, light_rgb, light_rgb, 1 };
    gles.lightfv(g, gles.GL_LIGHT0, gles.GL_DIFFUSE, &lc);
    const amb = [4]f32{ ambient_rgb, ambient_rgb, ambient_rgb, 1 };
    gles.lightModelfv(g, gles.GL_LIGHT_MODEL_AMBIENT, &amb);
    gles.translatef(g, 0, 0, -2);
}

/// The quad's texcoords, shared by every maps test.
fn quadUv(g: *gles.Context) void {
    const S = struct {
        const uv = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    };
    gles.enableClientState(g, gles.GL_TEXTURE_COORD_ARRAY);
    gles.texCoordPointer(g, 2, gles.GL_FLOAT, 0, &S.uv);
}

test "an emissive map adds light of its own — black light, red glow (APP-011)" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    // No light, and occlusion 0 shuts the analytic environment (its one
    // off-switch): only emission can produce colour. Emissive is defined to
    // bypass the occlusion gate, so the glow survives it.
    litSetup(&s.g, 0, 0);
    const em = tex1x1(&s.g, .{ 255, 0, 0, 255 });
    gles.materialMap(&s.g, gles.GL_EMISSIVE_MAP_KUDOS, em);
    const ao_shut = tex1x1(&s.g, .{ 0, 0, 0, 255 });
    gles.materialMap(&s.g, gles.GL_OCCLUSION_MAP_KUDOS, ao_shut);
    fullQuad(&s.g);
    quadUv(&s.g);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();
    // Full red emission through the ACES roll-off and the sRGB encode reads
    // just under full (aces(1.0) ≈ 0.80 → sRGB ≈ 232); the unlit channels
    // stay exactly black.
    const px = s.at(32, 32);
    try expect(px[2] > 224 and px[2] <= 242);
    try expectEqual(@as(u8, 0), px[1]);
    try expectEqual(@as(u8, 0), px[0]);
}

test "an occlusion map gates the environment terms (APP-011)" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    litSetup(&s.g, 0, 0); // no direct light: only the environment shades
    // Fully-rough dielectric, so the environment's diffuse irradiance (not
    // its Fresnel reflection) carries the pixel.
    const mr = tex1x1(&s.g, .{ 0, 255, 0, 255 });
    gles.materialMap(&s.g, gles.GL_METAL_ROUGH_MAP_KUDOS, mr);
    fullQuad(&s.g);
    quadUv(&s.g);

    const ao_open = tex1x1(&s.g, .{ 255, 255, 255, 255 });
    gles.materialMap(&s.g, gles.GL_OCCLUSION_MAP_KUDOS, ao_open);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    const open = s.at(32, 32)[0]; // white albedo under the full sky irradiance
    try expect(open > 170 and open < 205);

    const ao_shut = tex1x1(&s.g, .{ 0, 0, 0, 255 });
    gles.materialMap(&s.g, gles.GL_OCCLUSION_MAP_KUDOS, ao_shut);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try expect(s.at(32, 32)[0] < 10);
    try s.noError();
}

test "the metal-rough map's metallic channel kills diffuse (APP-011)" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    litSetup(&s.g, 1, 0);
    // All textures first — tex1x1 leaves itself bound, and the BASE must end
    // up on unit 0. Occlusion 0 shuts the environment, so the pixel is the
    // direct lobe alone — a metal's environment reflection would otherwise
    // partly refill what its dead diffuse lobe loses.
    const dielectric = tex1x1(&s.g, .{ 0, 255, 0, 255 }); // G rough=1, B metal=0
    const metal = tex1x1(&s.g, .{ 0, 255, 255, 255 }); // B metal=1
    const ao_shut = tex1x1(&s.g, .{ 0, 0, 0, 255 });
    gles.materialMap(&s.g, gles.GL_OCCLUSION_MAP_KUDOS, ao_shut);
    // Mid-grey albedo, NOT saturated: at full metal a saturated channel puts
    // f0 at 1.0 and Fresnel alone zeroes the diffuse term, which would mask a
    // dropped (1 - metallic) energy-conservation factor.
    const base = tex1x1(&s.g, .{ 204, 204, 204, 255 });
    gles.bindTexture(&s.g, gles.GL_TEXTURE_2D, base);
    gles.enable(&s.g, gles.GL_TEXTURE_2D);
    fullQuad(&s.g);
    quadUv(&s.g);

    gles.materialMap(&s.g, gles.GL_METAL_ROUGH_MAP_KUDOS, dielectric);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    const r_diel = s.at(32, 32)[2]; // R of BGRA

    gles.materialMap(&s.g, gles.GL_METAL_ROUGH_MAP_KUDOS, metal);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    const r_metal = s.at(32, 32)[2];

    // A metal has no diffuse lobe: the same grey surface reflects far less
    // under the same white light...
    try expect(r_diel > r_metal + 30);
    // ...and the metal pixel is EXACTLY the specular lobe, read through the
    // exposure/ACES/sRGB output chain (linear ≈ 0.037 → ~46). Diffuse leaking
    // through (a dropped 1-metallic) reads ~96.
    try expect(r_metal > 36 and r_metal < 58);
    try s.noError();
}

test "a normal map bends the surface away from the light (APP-011)" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();
    litSetup(&s.g, 1, 0);
    // Dielectric fully-rough surface, so diffuse N·L dominates the pixel;
    // occlusion 0 shuts the environment so the bent normal reads truly dark.
    const mr = tex1x1(&s.g, .{ 0, 255, 0, 255 });
    gles.materialMap(&s.g, gles.GL_METAL_ROUGH_MAP_KUDOS, mr);
    const ao_shut = tex1x1(&s.g, .{ 0, 0, 0, 255 });
    gles.materialMap(&s.g, gles.GL_OCCLUSION_MAP_KUDOS, ao_shut);
    fullQuad(&s.g);
    quadUv(&s.g);

    const flat = tex1x1(&s.g, .{ 128, 128, 255, 255 }); // tangent-space +Z
    gles.materialMap(&s.g, gles.GL_NORMAL_MAP_KUDOS, flat);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    const bright = s.at(32, 32)[2];

    const bent = tex1x1(&s.g, .{ 255, 128, 128, 255 }); // bent to the tangent: +x
    gles.materialMap(&s.g, gles.GL_NORMAL_MAP_KUDOS, bent);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    const dark = s.at(32, 32)[2];

    // Head-on light: the flat normal faces it (bright); the bent one is
    // near-perpendicular to it (dark).
    try expect(bright > dark + 40);
    try s.noError();
}

test "GL_BGRA_EXT stores blue-first bytes verbatim — decoders upload swap-free (RND-008)" {
    var s: Scene = undefined;
    try s.init();
    defer s.deinit();

    // Pure RED as a decoder would hand it: BGRA bytes {B=0, G=0, R=255, A=255}.
    var tex: gles.GLuint = 0;
    gles.genTextures(&s.g, 1, @ptrCast(&tex));
    gles.bindTexture(&s.g, gles.GL_TEXTURE_2D, tex);
    const bgra_red = [_]u8{ 0, 0, 255, 255 };
    gles.pixelStorei(&s.g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(&s.g, gles.GL_TEXTURE_2D, 0, gles.GL_BGRA_EXT, 1, 1, 0, gles.GL_BGRA_EXT, gles.GL_UNSIGNED_BYTE, &bgra_red);
    gles.texParameteri(&s.g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    gles.enable(&s.g, gles.GL_TEXTURE_2D);
    gles.texEnvi(&s.g, gles.GL_TEXTURE_ENV, gles.GL_TEXTURE_ENV_MODE, gles.GL_REPLACE);

    const uv = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1 };
    fullQuad(&s.g);
    gles.enableClientState(&s.g, gles.GL_TEXTURE_COORD_ARRAY);
    gles.texCoordPointer(&s.g, 2, gles.GL_FLOAT, 0, &uv);
    gles.drawArrays(&s.g, gles.GL_TRIANGLES, 0, 6);
    try s.noError();

    // RED out — a channel swap on this path renders it blue.
    try expectEqual([4]u8{ 0, 0, 255, 255 }, s.at(32, 32));
}
