//! A picture of the VM console window, rendered on the host.
//!
//! The window's content is a pure function of the guest's serial stream: bytes in
//! (vmconsole.Console), a text grid out. This feeds it a REAL transcript — the
//! console of a Linux guest booted by kudos under QEMU, captured off the trace bus
//! — and draws the window through the same painter the desktop uses, lowered into
//! the software rasteriser. The result is a PPM of the window as kudos draws it,
//! obtainable on a machine with no GPU, which is the only kind this repository can
//! run a nested guest on.
//!
//! It is also the VM window's layout test: the assertions below fail if the
//! guest's output stops landing in the grid.
//!
//! Run it with `zig build vm-shot`, which writes build/vm_shot.ppm.

const std = @import("std");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");
const vmconsole = @import("vmconsole");

const ui = @import("ui");
const kgl = ui.kgl;
const glcomp = ui.glcomp;
const theme = ui.theme;
const font = ui.font;

/// The captured guest console: the boot of a Linux 6.6 guest inside kudos, from
/// the kernel's first line to the shell prompt.
const TRANSCRIPT = @embedFile("fixtures/guest-console.txt");

const SW: u32 = 1100;
const SH: u32 = 700;
/// The window, sized so the guest's 80×25 grid fits exactly.
const WIN_X: f32 = 40;
const WIN_Y: f32 = 40;
/// Height of the window's status strip, matching apps/vm.zig.
const STATUS_H: f32 = 20;

fn fontAtlas() kgl.Atlas {
    return .{
        .cell_w = @floatFromInt(font.WIDTH),
        .cell_h = @floatFromInt(font.HEIGHT),
        .first = font.FIRST_CHAR,
        .count = @intCast(font.GLYPH_COUNT),
    };
}

/// Replay the transcript into a console grid, exactly as the machine model feeds
/// it: one byte at a time, with the carriage returns a serial line carries.
fn replay() vmconsole.Console {
    var c = vmconsole.Console.init();
    for (TRANSCRIPT) |b| {
        if (b == '\n') c.feed('\r');
        c.feed(b);
    }
    return c;
}

fn writePpm(g: *gles.Context, path: []const u8) !void {
    const cs: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
    const bgra = cs.color;
    const tio = std.testing.io;
    var file = try std.Io.Dir.cwd().createFile(tio, path, .{});
    defer file.close(tio);
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(tio, &wbuf);
    const w = &fw.interface;
    try w.print("P6\n{d} {d}\n255\n", .{ SW, SH });
    var i: usize = 0;
    while (i < @as(usize, SW) * SH) : (i += 1) {
        try w.writeByte(bgra[i * 4 + 2]);
        try w.writeByte(bgra[i * 4 + 1]);
        try w.writeByte(bgra[i * 4 + 0]);
    }
    try w.flush();
}

// VIRT-010, not VIRT-016: this replays a SERIAL transcript into the text grid,
// so it is evidence for the console, not for the guest's virtio-gpu scanout —
// which is never involved here. The scanout's display rule is asserted by
// vmconsole's `showsScanout`.
test "the guest's boot lands in the console grid (VIRT-010)" {
    var c = replay();
    // The grid holds the last screenful, so the prompt is what survives — the
    // marker the initramfs prints scrolls off exactly as it would on a terminal.
    var seen_prompt = false;
    var r: usize = 0;
    while (r < vmconsole.ROWS) : (r += 1) {
        if (std.mem.indexOf(u8, c.row(r), "#") != null) seen_prompt = true;
    }
    try std.testing.expect(seen_prompt);
    try std.testing.expect(std.mem.indexOf(u8, TRANSCRIPT, "Linux version 6.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, TRANSCRIPT, "KUDOS-GUEST-UP") != null);
}

test "render the VM console window through kgl + Soft and write a screenshot" {
    const ta = std.testing.allocator;
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();

    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = SW, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);

    gles.beginFrame(&g, SW, SH);
    const atlas_tex = kgl.uploadAtlas(&g, @intCast(font.ATLAS_W), @intCast(font.ATLAS_H), &font.ATLAS_LA);

    const atlas = fontAtlas();
    const win_w: f32 = @as(f32, @floatFromInt(font.WIDTH)) * vmconsole.COLS + 12;
    const win_h: f32 = @as(f32, @floatFromInt(font.HEIGHT)) * vmconsole.ROWS + STATUS_H + 40;

    p.begin(&g, SW, SH);
    // The desktop underneath, so the window reads as a window.
    glcomp.wallpaper(&p, @floatFromInt(SW), @floatFromInt(SH), 0xFF1E4E8C, 0xFF6B3F9E);
    glcomp.windowFrame(&p, .{
        .x = WIN_X,
        .y = WIN_Y,
        .w = win_w,
        .h = win_h,
        .title = "vm 0",
        .focused = true,
    }, atlas_tex, atlas);

    // The content, drawn exactly as apps/vm.zig draws it: a status strip, then
    // the guest's grid.
    const cx = WIN_X + 1;
    const cy = WIN_Y + 28;
    p.setOrigin(cx, cy);
    const cw = win_w - 2;
    const ch = win_h - 29;
    p.fillRect(0, 0, cw, ch, theme.CONTENT_BG);
    p.rect(0, 0, cw, STATUS_H, theme.BORDER);
    p.text(atlas_tex, atlas, "VM 0: running", 6, 4, theme.ACCENT);

    var console = replay();
    var r: usize = 0;
    while (r < vmconsole.ROWS) : (r += 1) {
        const y = STATUS_H + @as(f32, @floatFromInt(r)) * atlas.cell_h;
        if (y >= ch) break;
        p.text(atlas_tex, atlas, console.row(r), 6, y + 2, theme.WHITE);
    }
    p.setOrigin(0, 0);
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);

    std.Io.Dir.cwd().createDirPath(std.testing.io, "build") catch {};
    try writePpm(&g, "build/vm_shot.ppm");
}
