//! The blob-window scene replay, against real pixels (MOD-015): the GL sequence
//! `apps/blobwin.zig` issues for the reference cube
//! (scripts/agent/samples/cube.zig), driven into the software rasteriser. The
//! cube-run track proves the loop end to end in QEMU; this test judges the drawn
//! geometry cheaply — a solid lit cube over the viewport centre, its lit faces
//! shading apart.

const std = @import("std");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");

const ta = std.testing.allocator;
const W: u32 = 96;
const H: u32 = 96;

const NVERTS: u32 = 36;

fn cubeVertex(i: u32) [3]f32 {
    // The sample's generator, duplicated: the sample lives outside the module
    // tree, so neither file can import the other. Drift shows as this test
    // drawing a different shape.
    const f = i / 6;
    const corners = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const corner = corners[i % 6];
    const u: f32 = if (corner == 1 or corner == 2) 1 else -1;
    const v: f32 = if (corner == 2 or corner == 3) 1 else -1;
    return switch (f) {
        0 => .{ u, v, 1 },
        1 => .{ -u, v, -1 },
        2 => .{ 1, v, -u },
        3 => .{ -1, v, u },
        4 => .{ u, 1, -v },
        else => .{ u, -1, v },
    };
}

fn cubeNormal(i: u32) [3]f32 {
    return switch (i / 6) {
        0 => .{ 0, 0, 1 },
        1 => .{ 0, 0, -1 },
        2 => .{ 1, 0, 0 },
        3 => .{ -1, 0, 0 },
        4 => .{ 0, 1, 0 },
        else => .{ 0, -1, 0 },
    };
}

fn projection(aspect: f32) [16]f32 {
    const near: f32 = 1.0;
    const far: f32 = 20.0;
    const top: f32 = 0.5;
    const right = top * aspect;
    var m = [_]f32{0} ** 16;
    m[0] = near / right;
    m[5] = near / top;
    m[10] = -(far + near) / (far - near);
    m[11] = -1;
    m[14] = -2 * far * near / (far - near);
    return m;
}

fn pixel(g: *gles.Context, x: u32, y: u32) [4]u8 {
    const ctx: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
    return ctx.pixel(x, y);
}

test "the reference cube renders as a solid lit body, not fragments (MOD-015)" {
    var dev: raster.Soft = .{ .alloc = ta };
    idraw.device = dev.iface();
    defer {
        dev.deinit();
        idraw.device = null;
    }
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = W, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    gles.beginFrame(&g, W, H);

    // ── the replay prologue, as blobwin.drawInline does it ──────────────────
    gles.viewport(&g, 0, 0, W, H);
    gles.clearDepthf(&g, 1.0);
    gles.clearColor(&g, 0.07, 0.08, 0.11, 1.0);
    gles.clear(&g, gles.GL_COLOR_BUFFER_BIT | gles.GL_DEPTH_BUFFER_BIT);
    gles.matrixMode(&g, gles.GL_PROJECTION);
    gles.loadIdentity(&g);
    gles.matrixMode(&g, gles.GL_MODELVIEW);
    gles.loadIdentity(&g);
    gles.enableClientState(&g, gles.GL_VERTEX_ARRAY);
    // The replay's stale-painter-state disarm (see blobwin.drawInline): a
    // no-op on this fresh context, kept so the sequence stays the replay's.
    gles.disableClientState(&g, gles.GL_COLOR_ARRAY);
    gles.disableClientState(&g, gles.GL_TEXTURE_COORD_ARRAY);
    gles.disable(&g, gles.GL_TEXTURE_2D);
    const spin = @import("spin");
    gles.enable(&g, gles.GL_LIGHT0);
    gles.enable(&g, gles.GL_NORMALIZE);
    gles.lightfv(&g, gles.GL_LIGHT0, gles.GL_POSITION, &spin.LAMP_DIR);
    gles.lightfv(&g, gles.GL_LIGHT0, gles.GL_DIFFUSE, &spin.LAMP_COLOR);
    gles.lightfv(&g, gles.GL_LIGHT0, gles.GL_SPECULAR, &spin.LAMP_COLOR);
    gles.lightModelfv(&g, gles.GL_LIGHT_MODEL_AMBIENT, &spin.LAMP_AMBIENT);
    gles.materialf(&g, gles.GL_FRONT_AND_BACK, gles.GL_SHININESS, spin.LAMP_SHININESS);

    // ── the cube's own recorded commands, replayed ──────────────────────────
    var verts: [NVERTS * 3]f32 = undefined;
    var norms: [NVERTS * 3]f32 = undefined;
    var i: u32 = 0;
    while (i < NVERTS) : (i += 1) {
        const p = cubeVertex(i);
        const n = cubeNormal(i);
        verts[i * 3 + 0] = p[0];
        verts[i * 3 + 1] = p[1];
        verts[i * 3 + 2] = p[2];
        norms[i * 3 + 0] = n[0];
        norms[i * 3 + 1] = n[1];
        norms[i * 3 + 2] = n[2];
    }
    gles.enable(&g, gles.GL_DEPTH_TEST);
    gles.enable(&g, gles.GL_CULL_FACE);
    gles.enable(&g, gles.GL_LIGHTING);
    const proj = projection(1.0);
    gles.matrixMode(&g, gles.GL_PROJECTION);
    gles.loadMatrixf(&g, &proj);
    gles.matrixMode(&g, gles.GL_MODELVIEW);
    gles.loadIdentity(&g);
    gles.translatef(&g, 0, 0, -5);
    gles.rotatef(&g, 20, 1, 0, 0);
    gles.rotatef(&g, 30, 0, 1, 0);
    const col = [4]f32{ 0.30, 0.55, 0.95, 1.0 };
    gles.color4f(&g, col[0], col[1], col[2], col[3]);
    gles.materialfv(&g, gles.GL_FRONT_AND_BACK, gles.GL_AMBIENT_AND_DIFFUSE, &col);
    gles.vertexPointer(&g, 3, gles.GL_FLOAT, 0, &verts);
    gles.enableClientState(&g, gles.GL_NORMAL_ARRAY);
    gles.normalPointer(&g, gles.GL_FLOAT, 0, &norms);
    gles.drawArrays(&g, gles.GL_TRIANGLES, 0, NVERTS);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));

    // ── judgement: a solid body, centred, shaded ───────────────────────────
    const bg = pixel(&g, 2, 2);
    const centre = pixel(&g, W / 2, H / 2);
    // The centre of the viewport is INSIDE the cube's silhouette (it fills
    // ~2/5 of a 96px frame at distance 5 with fov ~53°) and must not be the
    // clear colour.
    try std.testing.expect(!std.mem.eql(u8, &centre, &bg));
    // Solidity: every pixel of the centre 20x20 patch is body, none is
    // background — fragments/tearing puncture this immediately.
    var holes: u32 = 0;
    var y: u32 = H / 2 - 10;
    while (y < H / 2 + 10) : (y += 1) {
        var x: u32 = W / 2 - 10;
        while (x < W / 2 + 10) : (x += 1) {
            if (std.mem.eql(u8, &pixel(&g, x, y), &bg)) holes += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 0), holes);
    // Lit: at yaw 30° two faces show, and the lamp shades them apart. Compare
    // a left-of-centre and right-of-centre sample: same material, different
    // normals, so different brightness.
    const left = pixel(&g, W / 2 - 14, H / 2);
    const right = pixel(&g, W / 2 + 14, H / 2);
    const lb = @as(u32, left[0]) + left[1] + left[2];
    const rb = @as(u32, right[0]) + right[1] + right[2];
    try std.testing.expect(lb != rb);
}
