//! The reference-render oracle, host half (spec TEST-004/TEST-006): every
//! feature-tier fixture model renders through the REAL loader — vfs.read →
//! glb.parse → png/jpeg.decode → gles — into the software rasteriser, and the
//! frame is held to two references:
//!
//!   1. REGRESSION (TEST-004): one fixed pose (the model viewer's own camera,
//!      spin frozen) byte-compared against a committed self-blessed golden.
//!      The soft backend is deterministic, so a drifted pixel is a changed
//!      renderer, loader, or asset — never noise. Fresh frames land in
//!      build/renders/<stem>.ppm; inspect, then bless with
//!      scripts/gl/bless_renders.sh and commit.
//!
//!   2. CONFORMANCE (TEST-006): the feature-validation models re-rendered at
//!      each one's PUBLISHED-screenshot framing (test/ui/assets/fixtures/reference/,
//!      from KhronosGroup/glTF-Sample-Assets) and compared perceptually —
//!      test/support/percept.zig downscales both frames onto one small grid and
//!      thresholds the mean per-channel error, per model, against measured
//!      same-model/cross-model margins. Renderers never agree byte-for-byte;
//!      the grid forgives resolution and antialiasing while still failing on
//!      wrong colours, layout, or a missing feature.

const std = @import("std");
const modelcache = @import("testroot").assets.modelcache;
const png = @import("testroot").assets.png;
const vfs = @import("vfs");
const ifilesys = @import("ifilesys");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");
const spin = @import("spin");
const percept = @import("percept");

const ta = std.testing.allocator;

const W: u32 = 256;
const H: u32 = 256;
const GOLDEN_DIR = "test/ui/assets/fixtures/renders";
const OUT_DIR = "build/renders";

/// The model viewer's pose comes from its owner (spin.zig — the same facts
/// modelview.zig draws with); only the spin is frozen at a fixed angle here so
/// the frame is a function of the asset alone.
const SPIN_DEG: f32 = 30.0;

const MODELS = [_]struct { file: []const u8, bytes: []const u8 }{
    .{ .file = "Triangle.gltf", .bytes = @embedFile("oracle_triangle") },
    .{ .file = "BoxInterleaved.glb", .bytes = @embedFile("oracle_boxinterleaved") },
    .{ .file = "BoxTextured.glb", .bytes = @embedFile("oracle_boxtextured") },
    .{ .file = "Duck.glb", .bytes = @embedFile("oracle_duck") },
    .{ .file = "VertexColorTest.glb", .bytes = @embedFile("oracle_vertexcolortest") },
    .{ .file = "AlphaBlendModeTest.glb", .bytes = @embedFile("oracle_alphablendmodetest") },
    .{ .file = "TextureCoordinateTest.glb", .bytes = @embedFile("oracle_texturecoordinatetest") },
    .{ .file = "OrientationTest.glb", .bytes = @embedFile("oracle_orientationtest") },
    .{ .file = "NormalTangentTest.glb", .bytes = @embedFile("oracle_normaltangenttest") },
    .{ .file = "MetalRoughSpheres.glb", .bytes = @embedFile("oracle_metalroughspheres") },
};

// A fake /ramdisk mount serving every fixture by name.
const FakeFs = struct {
    fn read(_: *anyopaque, path: []const u8) ?[]const u8 {
        for (MODELS) |m| {
            if (std.mem.eql(u8, path, m.file)) return m.bytes;
        }
        return null;
    }
    fn list(_: *anyopaque, _: []const u8, _: ifilesys.ListFn, _: ?*anyopaque) ifilesys.Error!void {
        return ifilesys.Error.NotFound; // unused here
    }
    fn kind(c: *anyopaque, path: []const u8) ?ifilesys.Kind {
        if (path.len == 0) return .dir;
        return if (read(c, path) != null) .file else null;
    }
    // Read-only: the asset pipeline never writes through the VFS.
    const vtable = ifilesys.IFileSys.VTable{
        .read = read,
        .list = list,
        .kind = kind,
        .write = ifilesys.read_only.write,
        .remove = ifilesys.read_only.remove,
        .mkdir = ifilesys.read_only.mkdir,
        .rmdir = ifilesys.read_only.rmdir,
    };
    var ctx: u8 = 0;
    fn iface() ifilesys.IFileSys {
        return .{ .ctx = &ctx, .vtable = &vtable };
    }
};

/// Render one fixture at the fixed pose and return the frame's BGRA bytes
/// (borrowed from the context — copy before teardown).
fn renderModel(dev: *raster.Soft, g: *gles.Context, file: []const u8) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/ramdisk/{s}", .{file});
    const model = try modelcache.load(ta, g, path);
    defer model.deinit(g);
    _ = dev;

    gles.viewport(g, 0, 0, W, H);
    gles.clearColor(g, 0.10, 0.10, 0.12, 1);
    gles.clearDepthf(g, 1.0);
    gles.clear(g, gles.GL_COLOR_BUFFER_BIT | gles.GL_DEPTH_BUFFER_BIT);

    const near: f32 = 0.1;
    const top = near * @tan(std.math.pi / 6.0); // half of a 60-degree vertical FOV
    gles.matrixMode(g, gles.GL_PROJECTION);
    gles.loadIdentity(g);
    gles.frustumf(g, -top, top, -top, top, near, 100.0);
    gles.matrixMode(g, gles.GL_MODELVIEW);
    gles.loadIdentity(g);
    gles.translatef(g, 0, 0, -spin.CAM_DIST);
    gles.rotatef(g, spin.CAM_PITCH_DEG, 1, 0, 0);
    gles.rotatef(g, SPIN_DEG, 0, 1, 0);
    gles.rotatef(g, spin.MODEL_TILT_DEG, 1, 0, 0);

    gles.enable(g, gles.GL_DEPTH_TEST);
    gles.enable(g, gles.GL_CULL_FACE);
    applyViewerLighting(g);

    model.draw(g);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
}

/// The model viewer's lamp, from its owner (spin.zig): one directional light
/// plus a cool ambient. Shared by the regression pose and the lit conformance
/// renders so "lit" means the same thing everywhere in this suite.
fn applyViewerLighting(g: *gles.Context) void {
    gles.enable(g, gles.GL_LIGHTING);
    gles.enable(g, gles.GL_LIGHT0);
    gles.enable(g, gles.GL_NORMALIZE);
    gles.lightfv(g, gles.GL_LIGHT0, gles.GL_POSITION, &spin.LAMP_DIR);
    gles.lightfv(g, gles.GL_LIGHT0, gles.GL_DIFFUSE, &spin.LAMP_COLOR);
    gles.lightfv(g, gles.GL_LIGHT0, gles.GL_SPECULAR, &spin.LAMP_COLOR);
    gles.lightModelfv(g, gles.GL_LIGHT_MODEL_AMBIENT, &spin.LAMP_AMBIENT);
    gles.materialf(g, gles.GL_FRONT_AND_BACK, gles.GL_SHININESS, spin.LAMP_SHININESS);
}

/// P6 PPM from the soft context's BGRA framebuffer (desktop_shot's format, so
/// the same tooling views both).
fn writePpm(ctx: *raster.SoftCtx, path: []const u8, w_px: u32, h_px: u32) !void {
    const tio = std.testing.io;
    var f = try std.Io.Dir.cwd().createFile(tio, path, .{});
    defer f.close(tio);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(tio, &wbuf);
    const w = &fw.interface;
    try w.print("P6\n{} {}\n255\n", .{ w_px, h_px });
    var i: usize = 0;
    while (i < @as(usize, w_px) * h_px) : (i += 1) {
        const px = ctx.color[i * 4 ..][0..4];
        try w.writeAll(&[3]u8{ px[2], px[1], px[0] }); // BGRA → RGB
    }
    try w.flush();
}

test "every feature-tier fixture matches its committed regression golden (TEST-004)" {
    std.Io.Dir.cwd().createDirPath(std.testing.io, OUT_DIR) catch {};
    vfs.unmountAllForTest();
    vfs.mount("ramdisk", FakeFs.iface());
    defer vfs.unmountAllForTest();

    var failed: usize = 0;
    inline for (MODELS) |m| {
        var dev = raster.Soft{ .alloc = ta };
        idraw.device = dev.iface();
        var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = W, .off_x = 0, .off_y = 0 }) orelse return error.NoDevice;
        gles.beginFrame(&g, W, H);

        try renderModel(&dev, &g, m.file);

        const ctx: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
        const stem = comptime m.file[0..std.mem.lastIndexOfScalar(u8, m.file, '.').?];
        const out_path = OUT_DIR ++ "/" ++ stem ++ ".ppm";
        try writePpm(ctx, out_path, W, H);

        // Compare against the golden. A missing golden fails with the bless
        // instructions; a byte mismatch names the model and both files.
        const golden_path = GOLDEN_DIR ++ "/" ++ stem ++ ".ppm";
        if (std.Io.Dir.cwd().readFileAlloc(std.testing.io, golden_path, ta, .limited(8 * 1024 * 1024))) |golden| {
            defer ta.free(golden);
            const fresh = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out_path, ta, .limited(8 * 1024 * 1024));
            defer ta.free(fresh);
            if (!std.mem.eql(u8, golden, fresh)) {
                std.debug.print("render-oracle: {s} DIFFERS from its golden — inspect {s} vs {s}; bless via scripts/gl/bless_renders.sh if intended\n", .{ m.file, out_path, golden_path });
                failed += 1;
            }
        } else |_| {
            std.debug.print("render-oracle: {s} has NO golden — inspect {s}, then scripts/gl/bless_renders.sh\n", .{ m.file, out_path });
            failed += 1;
        }

        g.deinit();
        dev.deinit();
        idraw.device = null;
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

// ── TEST-006: conformance against the PUBLISHED Khronos reference renderings ──

/// Downscale lattice for the perceptual metric: coarse enough to forgive the
/// two renderers' resolution/antialiasing, fine enough that a wrong colour
/// region or layout still lands in the wrong cells.
const CONFORMANCE_GRID = 16;

/// Conformance viewport height; the width follows each reference screenshot's
/// aspect ratio so both frames compose the scene into the same shape.
const CONFORMANCE_H: u32 = 256;

/// One feature-validation model held to its published reference rendering.
/// yaw/pitch/dist restate the REFERENCE screenshot's framing (glb.normalize
/// centres every model into a height-2 box, so distance alone sets fill);
/// threshold is the stated maximum mean per-channel error (0..255 scale),
/// set from measured margins: comfortably above the same-model error,
/// comfortably below every cross-model error (a frame that would pass for a
/// DIFFERENT model's reference proves nothing). `gap` non-null names the
/// renderer feature the soft pipeline lacks: the frame is asserted to STILL
/// diverge (error > threshold), so the day the feature lands, this test
/// fails loudly and the model is promoted to the conforming set.
const Reference = struct {
    file: []const u8,
    ref_png: []const u8,
    yaw_deg: f32,
    pitch_deg: f32,
    dist: f32,
    threshold: f32,
    /// Light the render with the viewer's lamp. The published renderings are
    /// image-based-lit; for flat test charts that reads as full exposure
    /// (unlit shows their base/vertex colours truest), while for solid forms
    /// the shading itself is the content — those render lit.
    lit: bool = false,
    gap: ?[]const u8 = null,
};

const REFERENCES = [_]Reference{
    // Conforming set — measured same-model error, then every cross-model error
    // against the same reference (the discrimination margin), then the bar:
    //   AlphaBlendModeTest     24.3, cross >= 37.0 -> 30
    //   VertexColorTest        18.2, cross >= 49.1 -> 30
    //   OrientationTest        37.0, cross >= 53.2 -> 45
    //   TextureCoordinateTest  19.9 once baseColorFactor modulated the
    //                          base-colour texture; bar kept at its gap-era 40,
    //                          which the cross-model matrix already cleared
    // APP-010 is cited HERE, against the Khronos AlphaBlendModeTest reference,
    // because this is where alpha blending is actually judged. It used to be
    // cited only from a comment over an unrelated list of five opaque models in
    // a passthrough run, which bears on blending not at all.
    .{ .file = "AlphaBlendModeTest.glb", .ref_png = @embedFile("ref_alphablendmodetest"), .yaw_deg = 0, .pitch_deg = 0, .dist = 3.8, .threshold = 30 },
    .{ .file = "VertexColorTest.glb", .ref_png = @embedFile("ref_vertexcolortest"), .yaw_deg = 0, .pitch_deg = 0, .dist = 2.0, .threshold = 30 },
    .{ .file = "OrientationTest.glb", .ref_png = @embedFile("ref_orientationtest"), .yaw_deg = -45, .pitch_deg = 30, .dist = 4.2, .threshold = 45, .lit = true },
    .{ .file = "TextureCoordinateTest.glb", .ref_png = @embedFile("ref_texturecoordinatetest"), .yaw_deg = 0, .pitch_deg = 0, .dist = 2.0, .threshold = 40 },
    // Documented gaps (spec TEST-008) — each threshold is the bar a MEANINGFUL
    // pass would need (under every cross-model error); the render is asserted to
    // stay ABOVE it until the named feature exists.
    //
    // These two are deliberately NOT part of TEST-006's conformance set: that
    // requirement is scoped to "features it implements", and listing these by
    // name alongside the conforming four made it read as a claim to render all
    // six correctly while the suite asserted the opposite for two of them.
    .{ .file = "NormalTangentTest.glb", .ref_png = @embedFile("ref_normaltangenttest"), .yaw_deg = 0, .pitch_deg = 0, .dist = 2.0, .threshold = 30, .gap = "the sphere shapes are normal-map content on flat quads; the unlit chart never enters the PBR path, so its normal maps stay unread" },
    .{ .file = "MetalRoughSpheres.glb", .ref_png = @embedFile("ref_metalroughspheres"), .yaw_deg = 0, .pitch_deg = 0, .dist = 2.3, .threshold = 30, .lit = true, .gap = "the metal/roughness response matrix reads as sharp mirrored environment detail per sphere; the analytic environment has no such detail to reflect" },
};

/// Render one model at its reference framing (lit per its table row).
fn renderConformance(g: *gles.Context, r: Reference, w_px: u32, h_px: u32, clear_bgr: [3]u8) !void {
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/ramdisk/{s}", .{r.file});
    const model = try modelcache.load(ta, g, path);
    defer model.deinit(g);

    gles.viewport(g, 0, 0, @intCast(w_px), @intCast(h_px));
    gles.clearColor(
        g,
        @as(f32, @floatFromInt(clear_bgr[2])) / 255.0,
        @as(f32, @floatFromInt(clear_bgr[1])) / 255.0,
        @as(f32, @floatFromInt(clear_bgr[0])) / 255.0,
        1,
    );
    gles.clearDepthf(g, 1.0);
    gles.clear(g, gles.GL_COLOR_BUFFER_BIT | gles.GL_DEPTH_BUFFER_BIT);

    const near: f32 = 0.1;
    const top = near * @tan(std.math.pi / 6.0); // half of a 60-degree vertical FOV
    const aspect = @as(f32, @floatFromInt(w_px)) / @as(f32, @floatFromInt(h_px));
    gles.matrixMode(g, gles.GL_PROJECTION);
    gles.loadIdentity(g);
    gles.frustumf(g, -top * aspect, top * aspect, -top, top, near, 100.0);
    gles.matrixMode(g, gles.GL_MODELVIEW);
    gles.loadIdentity(g);
    gles.translatef(g, 0, 0, -r.dist);
    gles.rotatef(g, r.pitch_deg, 1, 0, 0);
    gles.rotatef(g, r.yaw_deg, 0, 1, 0);

    gles.enable(g, gles.GL_DEPTH_TEST);
    gles.enable(g, gles.GL_CULL_FACE);
    if (r.lit) applyViewerLighting(g);

    model.draw(g);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(g));
}

test "feature models are consistent with the published Khronos renderings (TEST-006)" {
    const tio = std.testing.io;
    std.Io.Dir.cwd().createDirPath(tio, OUT_DIR) catch {};
    vfs.unmountAllForTest();
    vfs.mount("ramdisk", FakeFs.iface());
    defer vfs.unmountAllForTest();

    // A green run writes NOTHING to stderr: the build runner reprints any step
    // stderr through its failure formatter ("failed command: ..."), so passing
    // margins narrated there read as a red suite. The full per-model margin
    // table lands here instead, next to the frames it describes.
    var report = try std.Io.Dir.cwd().createFile(tio, OUT_DIR ++ "/conformance.txt", .{});
    defer report.close(tio);
    var rep_buf: [4096]u8 = undefined;
    var rep_w = report.writer(tio, &rep_buf);
    const rep = &rep_w.interface;
    defer rep.flush() catch {};

    var failed: usize = 0;
    for (REFERENCES) |r| {
        const ref = try png.decode(ta, r.ref_png);
        defer ref.deinit(ta);
        const backdrop = percept.borderMeanBgr(ref.bgra, ref.w, ref.h);
        const conf_w: u32 = @max(CONFORMANCE_GRID, CONFORMANCE_H * ref.w / ref.h);

        var dev = raster.Soft{ .alloc = ta };
        idraw.device = dev.iface();
        var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = conf_w, .off_x = 0, .off_y = 0 }) orelse return error.NoDevice;
        gles.beginFrame(&g, conf_w, CONFORMANCE_H);

        try renderConformance(&g, r, conf_w, CONFORMANCE_H, backdrop);

        const ctx: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
        const frame = ctx.color[0 .. @as(usize, conf_w) * CONFORMANCE_H * percept.BYTES_PER_PIXEL];

        // Keep the frame inspectable next to the regression renders.
        var name_buf: [96]u8 = undefined;
        const stem = r.file[0..std.mem.lastIndexOfScalar(u8, r.file, '.').?];
        const out_path = try std.fmt.bufPrint(&name_buf, OUT_DIR ++ "/{s}.conformance.ppm", .{stem});
        try writePpm(ctx, out_path, conf_w, CONFORMANCE_H);

        const ours = percept.downscale(CONFORMANCE_GRID, frame, conf_w, CONFORMANCE_H);
        const theirs = percept.downscale(CONFORMANCE_GRID, ref.bgra, ref.w, ref.h);
        const err = percept.meanAbsError(&ours, &theirs);

        if (r.gap) |why| {
            if (err <= r.threshold) {
                std.debug.print(
                    "conformance: {s} err {d:.1} is INSIDE the threshold {d:.1} but is listed as a gap ({s}) — the gap closed: promote it to the conforming set\n",
                    .{ r.file, err, r.threshold, why },
                );
                failed += 1;
            } else {
                try rep.print("{s} err {d:.1} > {d:.1} diverges as documented: {s}\n", .{ r.file, err, r.threshold, why });
            }
        } else if (err > r.threshold) {
            std.debug.print(
                "conformance: {s} err {d:.1} EXCEEDS the threshold {d:.1} — inspect {s} against test/ui/assets/fixtures/reference/{s}.png\n",
                .{ r.file, err, r.threshold, out_path, stem },
            );
            failed += 1;
        } else {
            try rep.print("{s} err {d:.1} <= {d:.1}\n", .{ r.file, err, r.threshold });
        }

        g.deinit();
        dev.deinit();
        idraw.device = null;
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}
