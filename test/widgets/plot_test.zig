//! Host tests of src/widgets/plot.zig — sampling, auto range, nice ticks.

const std = @import("std");
const plot = @import("plot");
const expect = std.testing.expect;

fn approx(a: f64, b: f64) bool {
    return @abs(a - b) < 1e-9;
}

fn line2x(_: *const anyopaque, x: f64) f64 {
    return 2 * x;
}

fn recip(_: *const anyopaque, x: f64) f64 {
    return 1 / x;
}

test "sample spans the range inclusively, one value per column" {
    var ys: [5]f64 = undefined;
    plot.sample(line2x, undefined, .{ .min = -2, .max = 2 }, &ys);
    try expect(approx(ys[0], -4));
    try expect(approx(ys[2], 0));
    try expect(approx(ys[4], 4));
}

test "autoY pads the finite extremes and skips non-finite samples" {
    var ys: [3]f64 = undefined;
    plot.sample(recip, undefined, .{ .min = -1, .max = 1 }, &ys); // middle column: 1/0 = inf
    try expect(!std.math.isFinite(ys[1]));
    const r = plot.autoY(&ys);
    // Finite extremes are -1 and 1; the padded range must strictly contain them.
    try expect(r.min < -1 and r.max > 1);
    try expect(r.max < 2); // padding, not the infinity
}

test "autoY of nothing finite or a flat line stays drawable" {
    const nans = [_]f64{ std.math.nan(f64), std.math.nan(f64) };
    const r0 = plot.autoY(&nans);
    try expect(r0.max > r0.min);

    const flat = [_]f64{ 3, 3, 3 };
    const r1 = plot.autoY(&flat);
    try expect(r1.min < 3 and r1.max > 3);
}

test "niceStep lands on 1/2/5 decades and firstTick aligns" {
    try expect(approx(plot.niceStep(10, 5), 2));
    try expect(approx(plot.niceStep(1, 5), 0.2));
    try expect(approx(plot.niceStep(100, 4), 20));
    try expect(approx(plot.firstTick(-7.3, 2), -6));
    try expect(approx(plot.firstTick(0.1, 0.5), 0.5));
}

test "zooming holds the window's centre and scales its span exactly (APP-018)" {
    const r = plot.Range{ .min = 2, .max = 10 }; // centre 6, half-span 4
    const out = r.zoomed(2);
    try std.testing.expectEqual(@as(f64, -2), out.min);
    try std.testing.expectEqual(@as(f64, 14), out.max);
    const back_in = out.zoomed(0.5);
    try std.testing.expectEqual(r.min, back_in.min);
    try std.testing.expectEqual(r.max, back_in.max);
}
