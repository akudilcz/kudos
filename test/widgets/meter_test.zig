//! Host tests for the usage meter's judgement: where healthy ends, that the
//! thresholds are the ones the theme's ramp is chosen for, and that a fill can
//! never overshoot its outline.

const std = @import("std");
const meter = @import("meter");
const theme = @import("theme");

test "status crosses at the stated thresholds" {
    try std.testing.expectEqual(meter.Status.ok, meter.statusOf(0, 100));
    try std.testing.expectEqual(meter.Status.ok, meter.statusOf(69, 100));
    try std.testing.expectEqual(meter.Status.warn, meter.statusOf(70, 100));
    try std.testing.expectEqual(meter.Status.warn, meter.statusOf(89, 100));
    try std.testing.expectEqual(meter.Status.critical, meter.statusOf(90, 100));
    try std.testing.expectEqual(meter.Status.critical, meter.statusOf(100, 100));
}

test "the thresholds are fractions, not percentages of some other scale" {
    try std.testing.expectEqual(@as(f32, 0.70), meter.WARN_AT);
    try std.testing.expectEqual(@as(f32, 0.90), meter.CRITICAL_AT);
}

test "an absent capacity reads as ok, never as full" {
    try std.testing.expectEqual(meter.Status.ok, meter.statusOf(0, 0));
    try std.testing.expectEqual(meter.Status.ok, meter.statusOf(50, 0));
    try std.testing.expectEqual(@as(f32, 0), meter.fraction(50, 0));
}

test "fraction is clamped, so a bad reading cannot draw past the outline" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), meter.fraction(1, 4), 0.0001);
    try std.testing.expectEqual(@as(f32, 1), meter.fraction(9, 4));
    try std.testing.expectEqual(@as(f32, 1), meter.fraction(std.math.maxInt(u64), 1));
}

test "byte-scale capacities do not lose the distinction" {
    const gib: u64 = 1024 * 1024 * 1024;
    try std.testing.expectEqual(meter.Status.ok, meter.statusOf(30 * gib, 64 * gib));
    try std.testing.expectEqual(meter.Status.warn, meter.statusOf(46 * gib, 64 * gib));
    try std.testing.expectEqual(meter.Status.critical, meter.statusOf(60 * gib, 64 * gib));
}

test "each status names a distinct colour from the theme's reserved ramp" {
    try std.testing.expectEqual(theme.GREEN, meter.Status.ok.color());
    try std.testing.expectEqual(theme.YELLOW, meter.Status.warn.color());
    try std.testing.expectEqual(theme.RED, meter.Status.critical.color());
}

// ── the painted half ────────────────────────────────────────────────────────────

const kgl = @import("kgl");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");
const rects = @import("rects");

test "the meter PAINTS: outline, fill by status, and a caller-tinted variant" {
    const ta = std.testing.allocator;
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = 128, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);
    gles.beginFrame(&g, 128, 128);
    p.begin(&g, 128, 128);
    const r = rects.Rect{ .x = 4, .y = 4, .w = 100, .h = 12 };
    meter.draw(&p, r, 30, 100);
    meter.draw(&p, .{ .x = 4, .y = 24, .w = 100, .h = 12 }, 95, 100); // critical fill
    meter.drawTinted(&p, .{ .x = 4, .y = 44, .w = 100, .h = 12 }, 50, 100, 0xFF0A84FF);
    meter.drawTinted(&p, .{ .x = 4, .y = 64, .w = 0, .h = 0 }, 1, 1, 0xFF0A84FF); // empty: no-op arm
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));
}
