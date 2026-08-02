//! System monitor app: a live-rendered view of the machine —
//! CPU identity (CPUID), memory usage bar, ramdisk contents, uptime, framebuffer.

const std = @import("std");
const surface = @import("surface");
const Color = surface.Color;
const font = @import("../ui/screen/font.zig");
const Window = @import("../ui/wm/window.zig").Window;
const pmm = @import("../kernel/memory/pmm.zig");
const iramdisk = @import("iramdisk"); // the file store, whoever provides it
const timer = @import("../kernel/timer/timer.zig");
const framebuffer = @import("../ui/screen/framebuffer.zig");
const theme = @import("theme");
const cpu = @import("../kernel/cpu/cpu.zig");
const smp = @import("../kernel/smp/smp.zig");
const barfill = @import("barfill");
const kgl = @import("kgl"); // the 2D toolkit the unified GL desktop draws through

// Shared dashboard palette (single source of truth: src/ui/screen/theme.zig).
const BG = theme.GLASS_BG; // glass background
const HEADER = theme.HEADER;
const WHITE = theme.WHITE;
const ACCENT = theme.ACCENT;
const DIM = theme.DIM;
const BORDER = theme.BORDER;
const GREEN = theme.GREEN;
const YELLOW = theme.YELLOW;
const RED = theme.RED;

// Vertical gap between dashboard sections (px). Distinct from theme.HEADER_H even
// though they coincide today — they describe unrelated layout dimensions.
const SECTION_GAP: usize = 28;

// Horizontal layout of the dashboard body (px). LABEL_X is the left inset of a
// section heading; INDENT_X is where that section's rows are drawn (indented under
// the heading). HEADING_GAP is the vertical drop from a heading to its first row.
const LABEL_X: usize = 12;
const INDENT_X: usize = 24;
const HEADING_GAP: usize = 20;

const cpuid = cpu.cpuid;

/// Saturating subtraction: `a - b`, or 0 when `b > a`. Every content-relative
/// coordinate in `drawGl`/`barGl` (`cw - N`, `ch - N`, `w - 2`) uses this so a
/// window narrower/shorter than the assumed layout margins can never underflow-
/// wrap into a huge usize. Under ReleaseFast that wrap is silent UB (bogus
/// geometry / an overflow in the `* used` bar math) rather than a clean trap —
/// see the min-window-size clamp.
fn satSub(a: usize, b: usize) usize {
    return if (a > b) a - b else 0;
}

/// Write a CPUID register (4 bytes, little-endian) into `buf`, the byte order
/// CPUID uses to pack vendor/brand string characters.
fn putReg(buf: []u8, reg: u32) void {
    buf[0] = @truncate(reg);
    buf[1] = @truncate(reg >> 8);
    buf[2] = @truncate(reg >> 16);
    buf[3] = @truncate(reg >> 24);
}

// Live-figure refresh cadence: 50 ticks = 0.5 s at 100 Hz. The monitor samples
// its counters at draw time, and apps rasterize only on damage, so it must
// REPORT a content change on a cadence (via tick).
const REFRESH_TICKS: u64 = 50;

pub const System = struct {
    win: *Window,
    brand: [49]u8 = .{0} ** 49,
    brand_len: usize = 0,
    vendor: [13]u8 = .{0} ** 13,
    refresh_phase: u64 = 0,

    /// Allocate the monitor and cache the static CPU identity read once via CPUID
    /// (vendor + brand strings, logical-core count); the live figures are read
    /// fresh each `draw`.
    pub fn create(a: std.mem.Allocator, win: *Window) !*System {
        const self = try a.create(System);
        self.* = .{ .win = win };

        // Vendor string (leaf 0: EBX, EDX, ECX).
        const v = cpuid(0, 0);
        putReg(self.vendor[0..4], v.ebx);
        putReg(self.vendor[4..8], v.edx);
        putReg(self.vendor[8..12], v.ecx);

        // Brand string (leaves 0x80000002..4: EAX,EBX,ECX,EDX each).
        var i: usize = 0;
        for ([_]u32{ 0x80000002, 0x80000003, 0x80000004 }) |leaf| {
            const r = cpuid(leaf, 0);
            for ([_]u32{ r.eax, r.ebx, r.ecx, r.edx }) |reg| {
                putReg(self.brand[i .. i + 4], reg);
                i += 4;
            }
        }
        self.brand_len = std.mem.indexOfScalar(u8, &self.brand, 0) orelse 48;
        // trim leading spaces some firmwares pad with
        while (self.brand_len > 0 and self.brand[self.brand_len - 1] == ' ') self.brand_len -= 1;

        // NOTE: the core count is NOT cached here. It comes from the kernel's
        // authoritative online-core count (smp.coresOnline()) read live in draw(),
        // not from CPUID leaf 1 EBX[23:16] — that field is the max addressable
        // logical-processor ID per package, which firmware rounds up to a power of
        // two (a 32-core box reported 128), NOT the online/usable core count.
        return self;
    }

    /// Periodic content refresh: the live figures (uptime, CPU%, memory) are
    /// sampled at draw time, so report "content changed" every REFRESH_TICKS
    /// to get redrawn under the draw-on-damage model.
    pub fn tick(self: *System) bool {
        const phase = timer.now() / REFRESH_TICKS;
        if (phase == self.refresh_phase) return false;
        self.refresh_phase = phase;
        return true;
    }

    /// No key handling: the monitor is a passive, read-only view.
    pub fn onKey(self: *System, ascii: u8) void {
        _ = self;
        _ = ascii;
    }

    /// Resize needs no re-layout: `drawGl` derives every dimension from the
    /// content size the desktop passes each frame. Returns true so the desktop
    /// repaints the window at its new size on the next frame.
    pub fn onResize(self: *System) bool {
        _ = self;
        return true;
    }

    /// Draw a bordered usage bar filled to `used/total`, colored green/yellow/red
    /// by fill fraction (<70% / <90% / else). No-op fill when `total` is 0 or the
    /// bar is too narrow to hold an interior. The fill width comes from
    /// barfill.fillWidth (pure, host-tested) so a too-small window cannot
    /// underflow-wrap the geometry.
    fn barGl(p: *kgl.Painter, x: f32, y: f32, w: f32, h: f32, used: usize, total: usize) void {
        p.rect(x, y, w, h, BORDER);
        if (total == 0 or w < 2 or h < 2) return;
        const filled: f32 = @floatFromInt(barfill.fillWidth(@intFromFloat(w), used, total));
        const pct: usize = @intCast(@as(u64, used) * 100 / @as(u64, total));
        const col: Color = if (pct < 70) GREEN else if (pct < 90) YELLOW else RED;
        p.fillRect(x + 1, y + 1, filled, h - 2, col);
    }

    /// Render the dashboard into the whole-desktop GL frame, painted
    /// content-locally (the caller set the painter origin). The window's
    /// frosted body is the background, so nothing fills BG here.
    pub fn drawGl(self: *System, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, cw: usize, ch: usize, focused: bool, blink_on: bool) void {
        _ = focused;
        const cwf: f32 = @floatFromInt(cw);
        const lx: f32 = @floatFromInt(LABEL_X);
        const ix: f32 = @floatFromInt(INDENT_X);
        const hg: f32 = @floatFromInt(HEADING_GAP);
        const sg: f32 = @floatFromInt(SECTION_GAP);
        p.fillRect(0, 0, cwf, @floatFromInt(theme.HEADER_H), HEADER);
        p.text(atlas_tex, atlas, "KUDOS SYSTEM MONITOR", lx, 6, WHITE);
        if (blink_on) p.fillRect(@floatFromInt(satSub(cw, 20)), 10, 8, 8, GREEN);

        var buf: [96]u8 = undefined;
        var y: f32 = 42;

        p.text(atlas_tex, atlas, "CPU", lx, y, ACCENT);
        y += hg;
        p.text(atlas_tex, atlas, self.brand[0..self.brand_len], ix, y, WHITE);
        y += 18;
        const cores = smp.coresOnline();
        const cpus = std.fmt.bufPrint(&buf, "vendor {s}    cores online {d}", .{ self.vendor[0..12], cores }) catch "";
        p.text(atlas_tex, atlas, cpus, ix, y, DIM);
        y += 22;
        var k: u32 = 0;
        while (k < cores and k < 32) : (k += 1) {
            const kx = ix + @as(f32, @floatFromInt(k)) * 16;
            p.fillRect(kx, y, 12, 12, ACCENT);
            p.rect(kx, y, 12, 12, BORDER);
        }
        y += sg;

        p.text(atlas_tex, atlas, "MEMORY", lx, y, ACCENT);
        y += hg;
        barGl(p, ix, y, @floatFromInt(satSub(cw, 48)), 18, pmm.usedBytes(), pmm.totalBytes());
        y += 24;
        const mem = std.fmt.bufPrint(&buf, "{d} / {d} MiB used   ({d} MiB free)", .{ pmm.usedBytes() >> 20, pmm.totalBytes() >> 20, pmm.freeBytes() >> 20 }) catch "";
        p.text(atlas_tex, atlas, mem, ix, y, WHITE);
        y += sg;

        p.text(atlas_tex, atlas, "RAMDISK", lx, y, ACCENT);
        y += hg;
        if (iramdisk.instance) |rd| {
            var fi: usize = 0;
            while (fi < rd.count()) : (fi += 1) {
                const f = rd.at(fi);
                var nbuf: [96]u8 = undefined;
                const row = std.fmt.bufPrint(&nbuf, "{s}", .{f.name}) catch continue;
                p.text(atlas_tex, atlas, row, ix, y, WHITE);
                const sz = std.fmt.bufPrint(&nbuf, "{d} B", .{f.data.len}) catch continue;
                p.text(atlas_tex, atlas, sz, @floatFromInt(satSub(cw, 120)), y, DIM);
                y += 16;
            }
        }

        const up = timer.millis();
        const foot = std.fmt.bufPrint(&buf, "uptime {d}.{d}s    framebuffer {d}x{d}x{d}", .{ up / 1000, (up % 1000) / 100, framebuffer.width(), framebuffer.height(), framebuffer.bpp() }) catch "";
        p.text(atlas_tex, atlas, foot, lx, @floatFromInt(satSub(ch, 20)), DIM);
    }
};
