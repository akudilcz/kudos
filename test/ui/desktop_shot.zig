//! A picture of the window manager, rendered on the host.
//!
//! This drives the REAL 2D library — `kgl`, holding one `Painter` — the way the window
//! manager does: `kgl.fillRoundedRect`, `disc`, `image`, `text`, batched and lowered
//! through gles into `Soft`, the software rasteriser that turns them into pixels. The
//! result is a PPM: a screenshot of the desktop that needs no GPU, no QEMU, no lemon, so a
//! change to the chrome or the dock can be SEEN on a laptop. Nothing here names gles for
//! drawing — only kgl — which is exactly the layering it exists to check.
//!
//! Run it with `zig build screenshot`, which writes build/desktop_shot.ppm.

//! RND-003: the 2D library (kgl) draws the shapes, images and text the desktop
//! is made of — this composes a whole desktop frame through kgl.Painter alone.
//! DSK-010: every window's chrome and content are composited into one frame.
const std = @import("std");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");

// The UI, through one module root (src/ui/) so its cross-folder relative imports resolve.
const ui = @import("ui");
const kgl = ui.kgl;
const glcomp = ui.glcomp;
const chrome = ui.chrome;
const dock = ui.dock;
const font = ui.font;
const dockicons = ui.dockicons;

/// The uploaded icon atlas's cell grid, as the text path reads it.
fn iconsAtlas() kgl.Atlas {
    return .{
        .cell_w = @floatFromInt(dockicons.CELL),
        .cell_h = @floatFromInt(dockicons.CELL),
        .first = 0,
        .count = @intCast(dockicons.COUNT),
    };
}

fn uploadIcons(g: *gles.Context) u32 {
    return kgl.uploadAtlas(g, @intCast(dockicons.ATLAS_W), @intCast(dockicons.ATLAS_H), &dockicons.ATLAS_LA);
}

/// Desktop size — a laptop-ish 16:10 so the whole thing fits a preview.
const DW: u32 = 1280;
const DH: u32 = 800;
const DWf: f32 = @floatFromInt(DW);
const DHf: f32 = @floatFromInt(DH);

/// The font atlas as a `kgl.Atlas` (a vertical strip of `count` monospace cells).
fn fontAtlas() kgl.Atlas {
    return .{
        .cell_w = @floatFromInt(font.WIDTH),
        .cell_h = @floatFromInt(font.HEIGHT),
        .first = font.FIRST_CHAR,
        .count = @intCast(font.GLYPH_COUNT),
    };
}

/// Stand-in "app content": a few monospace lines under the title bar. The painter's origin
/// is already at the window (glcomp.windowFrame left it there), so this draws in
/// window-local coordinates — exactly as a real app would, over the frosted body.
fn drawBody(p: *kgl.Painter, win: glcomp.Window, atlas_tex: u32, atlas: kgl.Atlas, body: []const []const u8) void {
    const color: u32 = if (win.focused) 0xFFB8C0CC else 0xFF6A7079;
    for (body, 0..) |line, i| {
        const ty = chrome.TITLE_H + 12 + @as(f32, @floatFromInt(i)) * (atlas.cell_h + 4);
        p.text(atlas_tex, atlas, line[0..@min(line.len, 64)], 16, ty, color);
    }
}

/// Compose the desktop through the glcomp primitives — the same ones the live desktop
/// drives: wallpaper, then each window's frame followed by its content, then the dock.
fn compose(p: *kgl.Painter, atlas_tex: u32, icons_tex: u32, icons: []const dock.Item) void {
    const atlas = fontAtlas();

    glcomp.wallpaper(p, DWf, DHf, 0xFF1E4E8C, 0xFF6B3F9E);

    // Three windows, back to front. The frontmost is focused (full-colour lights).
    const windows = [_]glcomp.Window{
        .{ .x = 96, .y = 84, .w = 520, .h = 340, .title = "Model Viewer", .focused = false },
        .{ .x = 300, .y = 150, .w = 560, .h = 380, .title = "System Monitor", .focused = false },
        .{ .x = 520, .y = 240, .w = 620, .h = 400, .title = "Terminal", .focused = true },
    };
    const bodies = [_][]const []const u8{
        &.{ "loading teapot.glb ...", "47112 indices, no texture" },
        &.{ "cpu0  12%   cpu1   8%", "mem   214M / 4096M", "net   eth0  up  1.0 Gb/s" },
        &.{ "kudos$ uname -a", "kudos 0.1 x86_64 GSP-RM", "kudos$ _" },
    };
    for (windows, bodies) |win, body| {
        glcomp.windowFrame(p, win, atlas_tex, atlas);
        drawBody(p, win, atlas_tex, atlas, body);
    }

    glcomp.dockBar(p, icons_tex, iconsAtlas(), DWf, DHf, icons);
}

/// Read the sim's BGRA framebuffer back and write it as a binary PPM (P6, RGB).
fn writePpm(g: *gles.Context, path: []const u8) !void {
    const cs: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
    const bgra = cs.color;

    const tio = std.testing.io;
    var file = try std.Io.Dir.cwd().createFile(tio, path, .{});
    defer file.close(tio);
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(tio, &wbuf);
    const w = &fw.interface;
    try w.print("P6\n{d} {d}\n255\n", .{ DW, DH });
    var i: usize = 0;
    while (i < @as(usize, DW) * DH) : (i += 1) {
        try w.writeByte(bgra[i * 4 + 2]); // R
        try w.writeByte(bgra[i * 4 + 1]); // G
        try w.writeByte(bgra[i * 4 + 0]); // B
    }
    try w.flush();
}

test "render the desktop through kgl + Soft and write a screenshot" {
    const ta = std.testing.allocator;
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();

    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = DW, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();

    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);

    gles.beginFrame(&g, DW, DH);
    const atlas_tex = kgl.uploadAtlas(&g, @intCast(font.ATLAS_W), @intCast(font.ATLAS_H), &font.ATLAS_LA);
    const icons_tex = uploadIcons(&g);
    const icons = [_]dock.Item{
        .{ .accent = 0xFF0A84FF, .icon = .terminal, .running = true },
        .{ .accent = 0xFF30D158, .icon = .system, .running = true },
        .{ .accent = 0xFFFF9F0A, .icon = .calculator, .running = false },
        .{ .accent = 0xFFFF375F, .icon = .clock, .running = true },
        .{ .accent = 0xFFBF5AF2, .icon = .vm, .running = false },
    };

    p.begin(&g, DW, DH);
    compose(&p, atlas_tex, icons_tex, &icons);
    p.end();
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));

    try writePpm(&g, "build/desktop_shot.ppm");
}

/// Render one wallpaper + one centred window and read back a body-interior
/// pixel, well below the title bar. Everything else is held constant so two
/// calls differ only by the wallpaper underneath.
fn bodyCenterPixel(ta: std.mem.Allocator, wall_a: u32, wall_b: u32, with_window: bool) !u32 {
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = DW, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);
    gles.beginFrame(&g, DW, DH);
    const atlas_tex = kgl.uploadAtlas(&g, @intCast(font.ATLAS_W), @intCast(font.ATLAS_H), &font.ATLAS_LA);
    p.begin(&g, DW, DH);
    glcomp.wallpaper(&p, DWf, DHf, wall_a, wall_b);
    if (with_window) {
        glcomp.windowFrame(&p, .{ .x = 300, .y = 200, .w = 400, .h = 300, .title = "probe", .focused = true }, atlas_tex, fontAtlas());
        p.setOrigin(0, 0);
    }
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);
    const cs: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
    const px = (200 + 150) * @as(usize, DW) + (300 + 200); // body centre, well under the title bar
    const c = cs.color;
    return @as(u32, c[px * 4]) | @as(u32, c[px * 4 + 1]) << 8 | @as(u32, c[px * 4 + 2]) << 16;
}

/// Render just the dock over a flat field and hash the raster — the DSK-017
/// probe compares a running app's tile against a stopped one's.
fn dockHash(ta: std.mem.Allocator, running: bool) !u64 {
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = DW, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);
    gles.beginFrame(&g, DW, DH);
    const icons_tex = uploadIcons(&g);
    p.begin(&g, DW, DH);
    glcomp.wallpaper(&p, DWf, DHf, 0xFF1E4E8C, 0xFF6B3F9E);
    const icons = [_]dock.Item{.{ .accent = 0xFF0A84FF, .icon = .terminal, .running = running }};
    glcomp.dockBar(&p, icons_tex, iconsAtlas(), DWf, DHf, &icons);
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);
    const cs: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
    return std.hash.XxHash64.hash(0, cs.color[0 .. @as(usize, DW) * DH * 4]);
}

/// Render the whole screen as the decoded background image, a flat fill, or
/// nothing at all, and hash the raster. The `.none` arm is the control that
/// catches an image draw degrading to a no-op: painted-nothing must differ
/// from painted-image, not merely from a different fill.
const Backdrop = union(enum) { image: ui.png.Image, flat, none };

fn backdropHash(ta: std.mem.Allocator, mode: Backdrop) !u64 {
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = DW, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);
    gles.beginFrame(&g, DW, DH);
    const tex: ?u32 = switch (mode) {
        .image => |im| kgl.uploadImage(&g, @intCast(im.w), @intCast(im.h), im.bgra),
        else => null,
    };
    p.begin(&g, DW, DH);
    switch (mode) {
        .image => p.image(tex.?, 0, 0, DWf, DHf, 0xFFFFFFFF),
        .flat => p.fillRect(0, 0, DWf, DHf, 0xFF1E4E8C),
        .none => {},
    }
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);
    const cs: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
    return std.hash.XxHash64.hash(0, cs.color[0 .. @as(usize, DW) * DH * 4]);
}

test "the shipped default background is a PNG that decodes and paints the backdrop (DSK-001, DSK-002)" {
    // assets/media/background.png IS the default: main.seedRamdisk stages it at
    // the path render.zig adopts as the boot wallpaper. Decoding it through the
    // REAL decoder proves the shipped asset, not a stand-in.
    const ta = std.testing.allocator;
    var img = try ui.png.decode(ta, @embedFile("background_png"));
    defer img.deinit(ta);
    try std.testing.expect(img.w > 0 and img.h > 0);
    // Painted as the backdrop it must show the image — different from a flat
    // field AND from an empty frame (a no-op draw is exactly an empty frame) —
    // and two runs of the same image must agree (deterministic paint).
    const painted = try backdropHash(ta, .{ .image = img });
    try std.testing.expect(painted != try backdropHash(ta, .flat));
    try std.testing.expect(painted != try backdropHash(ta, .none));
    try std.testing.expectEqual(painted, try backdropHash(ta, .{ .image = img }));
}

test "a running application's dock tile is marked (DSK-017)" {
    const ta = std.testing.allocator;
    try std.testing.expect(try dockHash(ta, true) != try dockHash(ta, false));
}

test "the window body is frosted: the wallpaper shows through it (DSK-008)" {
    const ta = std.testing.allocator;
    const reds = try bodyCenterPixel(ta, 0xFF8C1E1E, 0xFF9E3F3F, true);
    const blues = try bodyCenterPixel(ta, 0xFF1E4E8C, 0xFF6B3F9E, true);
    // Opaque body ⇒ identical pixels regardless of what lies beneath. Frosted
    // (translucent) ⇒ the wallpaper's colour participates in the body pixel.
    try std.testing.expect(reds != blues);
    // And the frost is a treatment, not a no-op: the body differs from the
    // bare wallpaper at the same point.
    const bare = try bodyCenterPixel(ta, 0xFF1E4E8C, 0xFF6B3F9E, false);
    try std.testing.expect(blues != bare);
}

test "BENCH soft frame cost at 1024x768" {
    const ta = std.testing.allocator;
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = 1024, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);
    gles.beginFrame(&g, 1024, 768);
    const atlas_tex = kgl.uploadAtlas(&g, @intCast(font.ATLAS_W), @intCast(font.ATLAS_H), &font.ATLAS_LA);
    gles.swapBuffers(&g);
    // Zig 0.16's monotonic clock: Timestamp deltas, not the removed std.time.Timer.
    const bench_io = std.testing.io;
    const t_start = std.Io.Timestamp.now(bench_io, .awake);
    const N = 20;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        gles.beginFrame(&g, 1024, 768);
        p.begin(&g, 1024, 768);
        glcomp.wallpaper(&p, 1024, 768, 0xFF1E4E8C, 0xFF6B3F9E);
        // two windows' frames + some text lines, roughly the boot scene
        glcomp.windowFrame(&p, .{ .x = 60, .y = 60, .w = 500, .h = 320, .title = "term #0", .focused = true }, atlas_tex, fontAtlas());
        var l: usize = 0;
        while (l < 8) : (l += 1) p.text(atlas_tex, fontAtlas(), "kudos terminal. type 'help'. 0123456789", 8, 34 + @as(f32, @floatFromInt(l)) * 16, 0xFFB8C0CC);
        glcomp.windowFrame(&p, .{ .x = 580, .y = 60, .w = 400, .h = 320, .title = "teapot.glb", .focused = false }, atlas_tex, fontAtlas());
        p.setOrigin(0, 0);
        p.end();
        gles.swapBuffers(&g);
    }
    const ns: u64 = @intCast(std.Io.Timestamp.durationTo(
        t_start,
        std.Io.Timestamp.now(bench_io, .awake),
    ).nanoseconds);
    const tio = bench_io;
    const f = try std.Io.Dir.createFileAbsolute(tio, "/tmp/soft_bench.txt", .{});
    defer f.close(tio);
    var pbuf: [128]u8 = undefined;
    var pw = f.writer(tio, &pbuf);
    try pw.interface.print("SOFT FRAME: {d} ns/frame ({d:.2} ms)\n", .{ ns / N, @as(f64, @floatFromInt(ns / N)) / 1e6 });
    try pw.interface.flush();
}
