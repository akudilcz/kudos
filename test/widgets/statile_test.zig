//! Host tests for the stat tile's layout: caption above, figure and unit sharing
//! one baseline, the unit clearing the figure at every size, and the whole tile
//! staying inside the rectangle it was given.

const std = @import("std");
const statile = @import("statile");
const rects = @import("rects");
const typeface = @import("typeface");

const tile: rects.Rect = .{ .x = 200, .y = 100, .w = 220, .h = 90 };

test "the caption sits at the top and the figure below it" {
    try typeface.init(std.heap.page_allocator);
    const cap = statile.captionBaseline(tile, .{});
    const val = statile.valueBaseline(tile, .{});
    try std.testing.expect(cap > tile.y);
    try std.testing.expect(val > cap);
}

test "a tile's ink stays inside the rectangle it was given" {
    try typeface.init(std.heap.page_allocator);
    for ([_]typeface.Role{ .value, .hero }) |role| {
        const base = statile.valueBaseline(tile, .{ .value = role });
        const m = typeface.metrics(role);
        try std.testing.expect(base - m.ascent >= tile.y);
        try std.testing.expect(base + m.descent <= tile.bottom());
    }
}

test "the unit clears the figure by the stated gap, at every size" {
    try typeface.init(std.heap.page_allocator);
    for ([_]typeface.Role{ .body, .value, .hero, .mega }) |role| {
        const value = "18.4";
        const x = statile.unitX(tile, .{ .value = role }, value);
        try std.testing.expectApproxEqAbs(
            tile.x + typeface.width(role, value) + statile.UNIT_GAP,
            x,
            0.001,
        );
        try std.testing.expect(x > tile.x + typeface.width(role, value));
    }
}

test "a longer figure pushes its unit further right" {
    try typeface.init(std.heap.page_allocator);
    const short = statile.unitX(tile, .{}, "9");
    const long = statile.unitX(tile, .{}, "1284913");
    try std.testing.expect(long > short);
}

test "a trend mark is drawn only when there is a trend" {
    try std.testing.expectEqual(@as(usize, 0), statile.Trend.none.mark().len);
    try std.testing.expect(statile.Trend.rising.mark().len > 0);
    try std.testing.expect(statile.Trend.falling.mark().len > 0);
    // The marks must be inside the baked ASCII range, or they would draw nothing.
    for ([_]statile.Trend{ .rising, .falling }) |t| {
        for (t.mark()) |ch| try std.testing.expect(ch >= 0x20 and ch < 0x7F);
    }
}
