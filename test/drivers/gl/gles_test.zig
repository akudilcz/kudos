//! OpenGL ES 1.1 end to end, on the host, with no GPU.
//!
//! Every other test in this module tests one file. These drive the API the way an
//! application does — `glEnable`, `glVertexPointer`, `glDrawArrays` — through the whole
//! stack (state -> shader key -> constants -> pipeline -> device), and then ask DrawSim
//! what actually arrived at the silicon seam. That is the chain that matters: each part
//! can be right on its own and still disagree with the next.
//!
//! This runs in milliseconds and needs no 4090. It is why the state machine was made
//! pure and why the seam sits where it does.
//!
//! Grounding: the OpenGL ES 1.1 specification.

const std = @import("std");
const gles = @import("gles");
const idraw = @import("idraw");
const sim = @import("draw_sim");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const DST = idraw.Dst{ .win_base = 0x1000, .stride_px = 640, .off_x = 0, .off_y = 0 };

/// A device and a GL context over it, torn down together.
const Harness = struct {
    dev: sim.DrawSim,
    g: gles.Context,

    fn init(self: *Harness) !void {
        self.dev = sim.DrawSim{};
        // The real path: the driver publishes itself, and gles finds it. An app never
        // touches idraw, so neither does this.
        idraw.device = self.dev.iface();
        self.g = gles.createContext(std.testing.allocator, DST) orelse return error.NoDevice;
        gles.beginFrame(&self.g, 64, 32);
    }

    fn deinit(self: *Harness) void {
        self.g.deinit();
        idraw.device = null;
    }

    /// What the device last saw.
    fn lastPipeline(self: *Harness) idraw.Pipeline {
        const cs: *sim.CtxSim = @ptrCast(@alignCast(self.g.target.ctx));
        return cs.last_pipeline.?;
    }
    fn lastDraw(self: *Harness) idraw.Draw {
        const cs: *sim.CtxSim = @ptrCast(@alignCast(self.g.target.ctx));
        return cs.last_draw.?;
    }
    fn drawCount(self: *Harness) u32 {
        const cs: *sim.CtxSim = @ptrCast(@alignCast(self.g.target.ctx));
        return cs.draws;
    }
    fn noError(self: *Harness) !void {
        try expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&self.g));
    }
};

test "gles advertises OES_element_index_uint, so 32-bit indices are supported (RND-004)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const ext = gles.getString(&h.g, gles.GL_EXTENSIONS) orelse return error.NoExtensions;
    const span = std.mem.span(ext);
    try expect(std.mem.indexOf(u8, span, "GL_OES_element_index_uint") != null);
}

/// Three vertices, positions only, in a buffer object — the fast path.
fn triangleInBuffer(h: *Harness) gles.GLuint {
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    var vb: gles.GLuint = 0;
    gles.genBuffers(&h.g, 1, @ptrCast(&vb));
    gles.bindBuffer(&h.g, gles.GL_ARRAY_BUFFER, vb);
    gles.bufferData(&h.g, gles.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gles.GL_STATIC_DRAW);
    gles.enableClientState(&h.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&h.g, 3, gles.GL_FLOAT, 0, null);
    return vb;
}

// ARCH-007: every gles draw lands on the one draw-device contract — the frame below
// arrives at the idraw fake, and "no device means no context" proves there is no
// other route out of gles.
test "a whole frame: clear, draw a triangle, swap" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    gles.clearColor(&h.g, 0.1, 0.2, 0.3, 1);
    gles.clear(&h.g, gles.GL_COLOR_BUFFER_BIT | gles.GL_DEPTH_BUFFER_BIT);
    _ = triangleInBuffer(&h);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    gles.swapBuffers(&h.g);

    try h.noError();
    try expectEqual(@as(u32, 1), h.drawCount());
    try expect(h.lastDraw().prim == .triangles);
    try expectEqual(@as(u32, 3), h.lastDraw().count);

    const cs: *sim.CtxSim = @ptrCast(@alignCast(h.g.target.ctx));
    try expectEqual(@as(u32, 1), cs.clears);
    try expect(cs.last_clear_mask.color and cs.last_clear_mask.depth);
    try expect(!cs.last_clear_mask.stencil);
    try expectEqual([4]f32{ 0.1, 0.2, 0.3, 1 }, cs.last_clear_color);
    try expectEqual(@as(u32, 1), cs.frames_ended); // swapBuffers ended it
}

test "the simplest program: no lights, no textures, no fog" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const k = h.lastPipeline().key;
    try expectEqual(@as(u4, 0), k.lights);
    try expectEqual(@as(u2, 0), k.units);
    try expect(k.fog == .off);
    try expect(!k.two_sided);
}

test "enabling lighting reaches the shader key, and the light count is what is enabled" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    gles.enable(&h.g, gles.GL_LIGHTING);
    gles.enable(&h.g, gles.GL_LIGHT0);
    gles.enable(&h.g, gles.GL_LIGHT3);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expectEqual(@as(u4, 2), h.lastPipeline().key.lights);

    // Turning the master switch off folds every light away — one program, not three.
    gles.disable(&h.g, gles.GL_LIGHTING);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expectEqual(@as(u4, 0), h.lastPipeline().key.lights);
    try h.noError();
}

test "a light's parameters reach the constant buffer, compacted to its slot" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    gles.enable(&h.g, gles.GL_LIGHTING);
    gles.enable(&h.g, gles.GL_LIGHT3); // the only one: it must land in slot 0
    const diffuse = [_]f32{ 0.25, 0.5, 0.75, 1 };
    gles.lightfv(&h.g, gles.GL_LIGHT0 + 3, gles.GL_DIFFUSE, &diffuse);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const u = h.lastPipeline().uniforms;
    const uniforms = gles.uniforms;
    const at = uniforms.OFF_LIGHTS + 0x10; // slot 0's diffuse
    try expectEqual(@as(f32, 0.25), @as(f32, @bitCast(std.mem.readInt(u32, u[at..][0..4], .little))));
    try expectEqual(@as(f32, 0.75), @as(f32, @bitCast(std.mem.readInt(u32, u[at + 8 ..][0..4], .little))));
}

test "a bound texture reaches the key and the pipeline's unit" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    var tex: gles.GLuint = 0;
    gles.genTextures(&h.g, 1, @ptrCast(&tex));
    gles.bindTexture(&h.g, gles.GL_TEXTURE_2D, tex);
    gles.enable(&h.g, gles.GL_TEXTURE_2D);

    // Bound and enabled, but texImage2D has given it no pixels: the standard leaves it
    // incomplete, so it contributes nothing.
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expectEqual(@as(u2, 0), h.lastPipeline().key.units);

    // Give it storage the way the device would see it, and it counts.
    const l0 = [_]u8{ 255, 255, 255, 255 };
    const dh = try h.dev.iface().textureCreate(.{ .format = .bgra8, .levels = &.{.{ .w = 1, .h = 1, .pixels = &l0 }} });
    h.g.textures.setDeviceHandle(tex, dh, 4, .static);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expectEqual(@as(u2, 1), h.lastPipeline().key.units);
    try expectEqual(dh, h.lastPipeline().units[0].?.texture);
    try h.noError();
}

test "glTexParameter reaches the sampler the draw is issued with" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    var tex: gles.GLuint = 0;
    gles.genTextures(&h.g, 1, @ptrCast(&tex));
    gles.bindTexture(&h.g, gles.GL_TEXTURE_2D, tex);
    gles.enable(&h.g, gles.GL_TEXTURE_2D);
    const l0 = [_]u8{ 255, 255, 255, 255 };
    const dh = try h.dev.iface().textureCreate(.{ .format = .bgra8, .levels = &.{.{ .w = 1, .h = 1, .pixels = &l0 }} });
    h.g.textures.setDeviceHandle(tex, dh, 4, .static);

    gles.texParameteri(&h.g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, gles.GL_CLAMP_TO_EDGE);
    gles.texParameteri(&h.g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const unit = h.lastPipeline().units[0].?;
    try expect(unit.wrap_s == .clamp_to_edge);
    try expect(unit.wrap_t == .repeat); // untouched
    try expect(unit.min == .nearest);
    try expect(unit.mip == .none); // GL_NEAREST reads no mip chain
    try h.noError();
}

test "gles advertises GL_KUDOS_material_maps, so lit draws can attach glTF maps (RND-005)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const ext = gles.getString(&h.g, gles.GL_EXTENSIONS) orelse return error.NoExtensions;
    try expect(std.mem.indexOf(u8, std.mem.span(ext), "GL_KUDOS_material_maps") != null);
}

test "a material map reaches its pipeline slot, and only its slot (RND-005)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    var tex: gles.GLuint = 0;
    gles.genTextures(&h.g, 1, @ptrCast(&tex));
    gles.bindTexture(&h.g, gles.GL_TEXTURE_2D, tex);
    const l0 = [_]u8{ 255, 255, 255, 255 };
    const dh = try h.dev.iface().textureCreate(.{ .format = .bgra8, .levels = &.{.{ .w = 1, .h = 1, .pixels = &l0 }} });
    h.g.textures.setDeviceHandle(tex, dh, 4, .static);

    gles.materialMap(&h.g, gles.GL_EMISSIVE_MAP_KUDOS, tex);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const p = h.lastPipeline();
    try expectEqual(dh, p.mat_maps[@intFromEnum(idraw.MatMap.emissive)].?.texture);
    try expect(p.mat_maps[@intFromEnum(idraw.MatMap.metal_rough)] == null);
    try expect(p.mat_maps[@intFromEnum(idraw.MatMap.normal)] == null);
    try expect(p.mat_maps[@intFromEnum(idraw.MatMap.occlusion)] == null);
    // The maps are not combiner units: the fixed-function key is untouched.
    try expectEqual(@as(u2, 0), p.key.units);
    try h.noError();
}

test "a material map slot clears on zero and stays null while incomplete (RND-005)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    // A name with no storage is incomplete: the slot resolves null, and the
    // backend shades that map's neutral identity rather than erroring.
    var tex: gles.GLuint = 0;
    gles.genTextures(&h.g, 1, @ptrCast(&tex));
    gles.bindTexture(&h.g, gles.GL_TEXTURE_2D, tex);
    gles.materialMap(&h.g, gles.GL_NORMAL_MAP_KUDOS, tex);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expect(h.lastPipeline().mat_maps[@intFromEnum(idraw.MatMap.normal)] == null);

    // Complete it, and the slot resolves; rebind zero, and it clears.
    const l0 = [_]u8{ 255, 255, 255, 255 };
    const dh = try h.dev.iface().textureCreate(.{ .format = .bgra8, .levels = &.{.{ .w = 1, .h = 1, .pixels = &l0 }} });
    h.g.textures.setDeviceHandle(tex, dh, 4, .static);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expect(h.lastPipeline().mat_maps[@intFromEnum(idraw.MatMap.normal)] != null);
    gles.materialMap(&h.g, gles.GL_NORMAL_MAP_KUDOS, 0);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expect(h.lastPipeline().mat_maps[@intFromEnum(idraw.MatMap.normal)] == null);
    try h.noError();
}

test "a bogus material-map selector records GL_INVALID_ENUM and no state (RND-005)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    gles.materialMap(&h.g, 0x1234, 7);
    try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(&h.g));
    for (h.g.mat_maps) |m| try expectEqual(@as(u32, 0), m);
}

test "fog mode reaches the key only while fog is enabled" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    gles.fogf(&h.g, gles.GL_FOG_MODE, @floatFromInt(gles.GL_LINEAR));
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expect(h.lastPipeline().key.fog == .off); // set but not enabled

    gles.enable(&h.g, gles.GL_FOG);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expect(h.lastPipeline().key.fog == .linear);
    try h.noError();
}

test "the matrix stack reaches the constant buffer's mvp" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    gles.matrixMode(&h.g, gles.GL_MODELVIEW);
    gles.loadIdentity(&h.g);
    gles.translatef(&h.g, 5, 0, 0);
    gles.pushMatrix(&h.g);
    gles.translatef(&h.g, 100, 0, 0); // only the copy moves
    gles.popMatrix(&h.g);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const u = h.lastPipeline().uniforms;
    // Column-major: the translation column starts at byte 48 of the mvp.
    const tx: f32 = @bitCast(std.mem.readInt(u32, u[48..][0..4], .little));
    try expectEqual(@as(f32, 5), tx); // the push/pop restored 5, not 105
    try h.noError();
}

test "the viewport reaches the pipeline FLIPPED into the framebuffer's convention" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    // GL's origin is bottom-left; a viewport at y=0 is at the BOTTOM of a 32-high frame.
    gles.viewport(&h.g, 0, 0, 64, 10);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expectEqual(@as(i32, 22), h.lastPipeline().viewport.y); // 32 - (0 + 10)
    try expectEqual(@as(u32, 10), h.lastPipeline().viewport.h);
    try h.noError();
}

test "a buffer-resident float array is drawn IN PLACE — no staging copy" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const vb = triangleInBuffer(&h);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const pos = h.lastDraw().attribs[@intFromEnum(idraw.AttribSlot.position)];
    try expect(pos == .array);
    // The device handle is the buffer's own, not a scratch one: the whole point of a
    // buffer object is that a frame does no per-draw work for it.
    try expectEqual(h.g.buffers.deviceHandle(vb).?, pos.array.buffer);
    try expect(pos.array.format == .f32x3);
    try expect(h.g.staging_buf == null); // nothing was staged at all
    try h.noError();
}

test "a client-side array is staged into a scratch buffer the GPU can read" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // No glBindBuffer: the data stays in the application's memory, which the GPU cannot
    // reach. It has to be gathered and uploaded.
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    gles.enableClientState(&h.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&h.g, 3, gles.GL_FLOAT, 0, &verts);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    try expect(h.g.staging_buf != null);
    const pos = h.lastDraw().attribs[@intFromEnum(idraw.AttribSlot.position)];
    try expectEqual(h.g.staging_buf.?, pos.array.buffer);
    try expectEqual(@as(u32, 12), pos.array.stride); // gathered tightly
    try h.noError();
}

test "the staging buffer is reused, so a steady frame allocates nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    gles.enableClientState(&h.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&h.g, 3, gles.GL_FLOAT, 0, &verts);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    const first = h.g.staging_buf.?;
    const created = h.dev.buffers_created;

    // Ten more identical draws: the same scratch, no new device buffers.
    for (0..10) |_| gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expectEqual(first, h.g.staging_buf.?);
    try expectEqual(created, h.dev.buffers_created);
    try h.noError();
}

test "GL_FIXED is widened to float on the way to the GPU" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    // 16.16: no vertex fetcher decodes it, so this must arrive as floats.
    const one: i32 = 1 << 16;
    const verts = [_]i32{ 0, 0, 0, one, 0, 0, 0, one, 0 };
    gles.enableClientState(&h.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&h.g, 3, gles.GL_FIXED, 0, &verts);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const pos = h.lastDraw().attribs[@intFromEnum(idraw.AttribSlot.position)];
    try expect(pos.array.format == .f32x3); // not "i32x3": there is no such thing
    // And the bytes really were converted: 1<<16 is 1.0, not 65536.0.
    const staged = std.mem.bytesAsSlice(f32, h.g.staging[0..36]);
    try expectEqual(@as(f32, 0), staged[0]);
    try expectEqual(@as(f32, 1), staged[3]);
    try h.noError();
}

test "a disabled array still gives every vertex a value — the current one" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    gles.color4f(&h.g, 1, 0, 0, 1); // no colour ARRAY, but every vertex is red
    gles.normal3f(&h.g, 0, 1, 0);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const d = h.lastDraw();
    const col = d.attribs[@intFromEnum(idraw.AttribSlot.color)];
    try expect(col == .constant);
    try expectEqual([4]f32{ 1, 0, 0, 1 }, col.constant);
    const nrm = d.attribs[@intFromEnum(idraw.AttribSlot.normal)];
    try expectEqual(@as(f32, 1), nrm.constant[1]);
    try h.noError();
}

test "a colour array of unsigned bytes is normalized; a position array of bytes is not" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const pos = [_]i8{ 0, 0, 0, 10, 0, 0, 0, 10, 0 };
    const col = [_]u8{255} ** 12;
    gles.enableClientState(&h.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&h.g, 3, gles.GL_BYTE, 0, &pos);
    gles.enableClientState(&h.g, gles.GL_COLOR_ARRAY);
    gles.colorPointer(&h.g, 4, gles.GL_UNSIGNED_BYTE, 0, &col);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    const d = h.lastDraw();
    // The same byte width, two meanings — this is the distinction that renders a model
    // 127 times too large when it is got wrong.
    try expect(d.attribs[@intFromEnum(idraw.AttribSlot.position)].array.format == .i8x3);
    try expect(d.attribs[@intFromEnum(idraw.AttribSlot.color)].array.format == .u8x4_unorm);
    try h.noError();
}

test "a normal array of bytes IS normalized, unlike a position's" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    const nrm = [_]i8{ 0, 0, 127, 0, 0, 127, 0, 0, 127 };
    gles.enableClientState(&h.g, gles.GL_NORMAL_ARRAY);
    gles.normalPointer(&h.g, gles.GL_BYTE, 0, &nrm);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    // The specification says a normal's integer components convert as a SIGNED
    // NORMALIZED type (2.8), so 127 must mean 1.0 and not 127.0.
    try expect(h.lastDraw().attribs[@intFromEnum(idraw.AttribSlot.normal)].array.format == .i8x3_snorm);
    try h.noError();
}

test "an indexed draw stages enough vertices for the highest index it names" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const verts = [_]f32{0} ** (3 * 8); // eight vertices
    const idx = [_]u16{ 0, 5, 2 }; // reaches vertex 5
    gles.enableClientState(&h.g, gles.GL_VERTEX_ARRAY);
    gles.vertexPointer(&h.g, 3, gles.GL_FLOAT, 0, &verts);
    gles.drawElements(&h.g, gles.GL_TRIANGLES, 3, gles.GL_UNSIGNED_SHORT, &idx);

    const d = h.lastDraw();
    try expect(d.index != null);
    try expect(d.index.?.type == .u16);
    try expectEqual(@as(u32, 3), d.count);
    // Six vertices staged (0..5), not three: an index may reach anywhere.
    try expect(h.g.staging.len >= 6 * 12);
    try h.noError();
}

test "state that is set but disabled does not reach the pipeline" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    gles.blendFunc(&h.g, gles.GL_SRC_ALPHA, gles.GL_ONE_MINUS_SRC_ALPHA);
    gles.depthFunc(&h.g, gles.GL_LEQUAL);
    gles.cullFace(&h.g, gles.GL_FRONT);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);

    var p = h.lastPipeline();
    try expect(!p.blend.enable);
    try expect(!p.depth.test_enable);
    try expect(p.raster.cull == null);

    gles.enable(&h.g, gles.GL_BLEND);
    gles.enable(&h.g, gles.GL_DEPTH_TEST);
    gles.enable(&h.g, gles.GL_CULL_FACE);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    p = h.lastPipeline();
    try expect(p.blend.enable and p.blend.src == .src_alpha and p.blend.dst == .one_minus_src_alpha);
    try expect(p.depth.test_enable and p.depth.func == .lequal);
    try expect(p.raster.cull.? == .front);
    try h.noError();
}

test "an error from deep in the stack surfaces through glGetError, and nothing is drawn" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);
    const before = h.drawCount();

    gles.drawArrays(&h.g, 0x0007, 0, 3); // GL_QUADS: not an ES primitive
    try expectEqual(@as(gles.GLenum, gles.GL_INVALID_ENUM), gles.getError(&h.g));
    try expectEqual(before, h.drawCount()); // the command did nothing else

    // And the flag is clear again afterwards.
    try h.noError();
}

test "glGetIntegerv answers from the device for the values the device decides" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    var v: [1]gles.GLint = undefined;
    gles.getIntegerv(&h.g, gles.GL_MAX_TEXTURE_SIZE, &v);
    try expectEqual(@as(gles.GLint, @intCast(sim.SIM_LIMITS.max_texture_size)), v[0]);
    gles.getIntegerv(&h.g, gles.GL_MAX_LIGHTS, &v);
    try expectEqual(@as(gles.GLint, 8), v[0]); // ours: it sizes our arrays
    try h.noError();
}

// RND-001: the rendering pipeline IS OpenGL ES 1.1 (GL_VERSION below);
// RND-006: the required extensions are advertised — dropping one fails here.
test "glGetString names the four mandatory extensions" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const ext = std.mem.span(gles.getString(&h.g, gles.GL_EXTENSIONS).?);
    for ([_][]const u8{
        "GL_OES_read_format",
        "GL_OES_compressed_paletted_texture",
        "GL_OES_point_size_array",
        "GL_OES_point_sprite",
    }) |name| try expect(std.mem.indexOf(u8, ext, name) != null);

    const ver = std.mem.span(gles.getString(&h.g, gles.GL_VERSION).?);
    try expect(std.mem.indexOf(u8, ver, "OpenGL ES-CM 1.1") != null);
    try h.noError();
}

test "the fixed-point entry points reach the same state as the float ones" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = triangleInBuffer(&h);

    // A Common-Lite program says translatex; it must land where translatef would.
    gles.matrixMode(&h.g, gles.GL_MODELVIEW);
    gles.loadIdentity(&h.g);
    gles.translatex(&h.g, 5 << 16, 0, 0); // 5.0 in 16.16
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    const tx: f32 = @bitCast(std.mem.readInt(u32, h.lastPipeline().uniforms[48..][0..4], .little));
    try expectEqual(@as(f32, 5), tx);
    try h.noError();
}

test "deleting a bound buffer unbinds it, and the next draw makes no geometry" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const vb = triangleInBuffer(&h);
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    const before = h.drawCount();

    // The standard requires a deleted buffer to be unbound as if bindBuffer(target, 0).
    gles.deleteBuffers(&h.g, 1, @ptrCast(&vb));
    var bound: [1]gles.GLint = undefined;
    gles.getIntegerv(&h.g, gles.GL_ARRAY_BUFFER_BINDING, &bound);
    try expectEqual(@as(gles.GLint, 0), bound[0]);

    // The array still points at the dead buffer, so the draw resolves to nothing rather
    // than to a use-after-free on the GPU.
    gles.drawArrays(&h.g, gles.GL_TRIANGLES, 0, 3);
    try expectEqual(before, h.drawCount());
}

test "two contexts draw independently — N windows, no shared current context" {
    var dev = sim.DrawSim{};
    idraw.device = dev.iface();
    defer idraw.device = null;

    var a = gles.createContext(std.testing.allocator, DST).?;
    defer a.deinit();
    var b = gles.createContext(std.testing.allocator, DST).?;
    defer b.deinit();

    gles.beginFrame(&a, 64, 32);
    gles.beginFrame(&b, 64, 32);
    gles.enable(&a, gles.GL_LIGHTING);
    gles.enable(&a, gles.GL_LIGHT0);

    // B's state is untouched by A's: there is no current context to fight over.
    try expectEqual(@as(gles.GLboolean, gles.GL_FALSE), gles.isEnabled(&b, gles.GL_LIGHTING));
    try expectEqual(@as(gles.GLboolean, gles.GL_TRUE), gles.isEnabled(&a, gles.GL_LIGHTING));
    try expectEqual(@as(u32, 2), dev.acquires);
}

test "no device means no context, and an app can ask without crashing" {
    idraw.device = null;
    try expect(gles.createContext(std.testing.allocator, DST) == null);
}

test "gles advertises GL_EXT_texture_format_BGRA8888, so decoders upload swap-free (RND-008)" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const ext = gles.getString(&h.g, gles.GL_EXTENSIONS) orelse return error.NoExtensions;
    try expect(std.mem.indexOf(u8, std.mem.span(ext), "GL_EXT_texture_format_BGRA8888") != null);
}
