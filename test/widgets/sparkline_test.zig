//! Host tests for the trace's sample-to-pixel mapping: time runs left to right,
//! value runs bottom to top, an excursion rides the edge instead of leaving the
//! panel, and an auto range never collapses onto a flat series.

const std = @import("std");
const sparkline = @import("sparkline");

const box: rects.Rect = .{ .x = 100, .y = 50, .w = 200, .h = 100 };
const unit: sparkline.Range = .{ .min = 0, .max = 1 };

test "time runs left to right, oldest at the left edge" {
    try std.testing.expectEqual(box.x, sparkline.plotX(box, 5, 0));
    try std.testing.expectEqual(box.right(), sparkline.plotX(box, 5, 4));
    try std.testing.expectApproxEqAbs(box.x + box.w / 2, sparkline.plotX(box, 5, 2), 0.001);
}

test "a single sample plots at the newest edge" {
    try std.testing.expectEqual(box.right(), sparkline.plotX(box, 1, 0));
}

test "value runs bottom to top" {
    try std.testing.expectEqual(box.bottom(), sparkline.plotY(box, unit, 0));
    try std.testing.expectEqual(box.y, sparkline.plotY(box, unit, 1));
    try std.testing.expectApproxEqAbs(box.y + box.h / 2, sparkline.plotY(box, unit, 0.5), 0.001);
}

test "an excursion rides the edge rather than drawing outside the panel" {
    try std.testing.expectEqual(box.y, sparkline.plotY(box, unit, 99));
    try std.testing.expectEqual(box.bottom(), sparkline.plotY(box, unit, -99));
}

test "a zero-height band still divides, rather than dividing by zero" {
    const flat: sparkline.Range = .{ .min = 5, .max = 5 };
    try std.testing.expectEqual(@as(f64, 1), flat.span());
    const y = sparkline.plotY(box, flat, 5);
    try std.testing.expect(y >= box.y and y <= box.bottom());
}

test "auto range pads the top and can be pinned to zero" {
    const zero_based = sparkline.autoRange(20, 100, true);
    try std.testing.expectEqual(@as(f64, 0), zero_based.min);
    try std.testing.expect(zero_based.max > 100);

    const floating = sparkline.autoRange(20, 100, false);
    try std.testing.expect(floating.min < 20);
    try std.testing.expect(floating.max > 100);
}

test "auto range never collapses on a flat series" {
    const r = sparkline.autoRange(42, 42, false);
    try std.testing.expect(r.max > r.min);
    try std.testing.expect(r.span() > 0);
}

test "a budget sits where its value maps, so a breach reads as one" {
    const range: sparkline.Range = .{ .min = 0, .max = 33.4 };
    const budget = 16.7;
    const y = sparkline.plotY(box, range, budget);
    // Half the band: the budget line lands mid-panel and a frame above it is
    // visibly above it.
    try std.testing.expectApproxEqAbs(box.y + box.h / 2, y, 0.5);
    try std.testing.expect(sparkline.plotY(box, range, 20.0) < y);
}

// ── the painted half ────────────────────────────────────────────────────────────

const kgl = @import("kgl");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");
const rects = @import("rects");

fn sampleAt(ctx: *const anyopaque, i: usize) f64 {
    _ = ctx;
    return @sin(@as(f64, @floatFromInt(i)) * 0.4) * 10 + 20;
}

test "the trace PAINTS: polyline, dashed budget line, and the panel floor" {
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
    const r = rects.Rect{ .x = 4, .y = 4, .w = 120, .h = 40 };
    const range = sparkline.autoRange(8, 32, false);
    var dummy: u8 = 0;
    sparkline.draw(&p, r, 60, &dummy, sampleAt, range, 0xFF0A84FF);
    sparkline.budgetLine(&p, r, range, 25, 0xFFFF9F0A);
    sparkline.floor(&p, r);
    sparkline.draw(&p, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, 60, &dummy, sampleAt, range, 0); // no-op arm
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));
}
