//! Host tests for the rectangle algebra: splits tile their parent exactly, insets
//! never invert, and an out-of-range index yields nothing rather than geometry
//! outside the parent.

const std = @import("std");
const rects = @import("rects");

const R = rects.Rect;
const page: R = .{ .x = 0, .y = 0, .w = 1000, .h = 600 };

test "edges and emptiness" {
    try std.testing.expectEqual(@as(f32, 1000), page.right());
    try std.testing.expectEqual(@as(f32, 600), page.bottom());
    try std.testing.expect(!page.isEmpty());
    try std.testing.expect((R{ .x = 0, .y = 0, .w = 0, .h = 10 }).isEmpty());
}

test "columns tile the parent exactly, gaps included" {
    const gap: f32 = 10;
    const n = 4;
    var i: usize = 0;
    var covered: f32 = 0;
    var prev_right: f32 = page.x;
    while (i < n) : (i += 1) {
        const c = rects.column(page, n, i, gap);
        covered += c.w;
        if (i > 0) try std.testing.expectApproxEqAbs(prev_right + gap, c.x, 0.001);
        prev_right = c.right();
        try std.testing.expectEqual(page.h, c.h);
    }
    try std.testing.expectApproxEqAbs(page.w - gap * (n - 1), covered, 0.001);
    try std.testing.expectApproxEqAbs(page.right(), prev_right, 0.001);
}

test "rows tile the parent exactly, gaps included" {
    const gap: f32 = 8;
    const n = 3;
    var i: usize = 0;
    var prev_bottom: f32 = page.y;
    while (i < n) : (i += 1) {
        const r = rects.row(page, n, i, gap);
        if (i > 0) try std.testing.expectApproxEqAbs(prev_bottom + gap, r.y, 0.001);
        prev_bottom = r.bottom();
    }
    try std.testing.expectApproxEqAbs(page.bottom(), prev_bottom, 0.001);
}

test "an out-of-range split index is empty, not off the parent" {
    try std.testing.expect(rects.column(page, 3, 3, 4).isEmpty());
    try std.testing.expect(rects.row(page, 3, 9, 4).isEmpty());
    try std.testing.expect(rects.column(page, 0, 0, 4).isEmpty());
    // Gaps wider than the parent leave nothing to draw rather than negative width.
    try std.testing.expect(rects.column(page, 4, 0, 500).isEmpty());
}

test "a grid cell is the intersection of its column and row" {
    const c = rects.cell(page, 4, 3, 2, 1, 10);
    const col = rects.column(page, 4, 2, 10);
    const rw = rects.row(page, 3, 1, 10);
    try std.testing.expectApproxEqAbs(col.x, c.x, 0.001);
    try std.testing.expectApproxEqAbs(col.w, c.w, 0.001);
    try std.testing.expectApproxEqAbs(rw.y, c.y, 0.001);
    try std.testing.expectApproxEqAbs(rw.h, c.h, 0.001);
}

test "weighted columns divide in proportion and still tile" {
    const w = [_]f32{ 2, 3, 2 };
    const gap: f32 = 12;
    const a = rects.weighted(page, &w, 0, gap);
    const b = rects.weighted(page, &w, 1, gap);
    const c = rects.weighted(page, &w, 2, gap);
    try std.testing.expectApproxEqAbs(a.w * 1.5, b.w, 0.01);
    try std.testing.expectApproxEqAbs(a.w, c.w, 0.01);
    try std.testing.expectApproxEqAbs(a.right() + gap, b.x, 0.01);
    try std.testing.expectApproxEqAbs(b.right() + gap, c.x, 0.01);
    try std.testing.expectApproxEqAbs(page.right(), c.right(), 0.01);
}

test "weighted rows divide in proportion" {
    const w = [_]f32{ 1, 3 };
    const a = rects.weightedRow(page, &w, 0, 6);
    const b = rects.weightedRow(page, &w, 1, 6);
    try std.testing.expectApproxEqAbs(a.h * 3, b.h, 0.01);
    try std.testing.expectApproxEqAbs(page.bottom(), b.bottom(), 0.01);
}

test "inset shrinks from every side and collapses rather than inverting" {
    const in = page.inset(20);
    try std.testing.expectEqual(@as(f32, 20), in.x);
    try std.testing.expectEqual(@as(f32, 960), in.w);
    const tiny: R = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const collapsed = tiny.inset(50);
    try std.testing.expectEqual(@as(f32, 0), collapsed.w);
    try std.testing.expectEqual(@as(f32, 0), collapsed.h);
}

test "edge slices and their remainders partition the parent" {
    const head = page.top(80);
    const rest = page.belowTop(80);
    try std.testing.expectEqual(@as(f32, 80), head.h);
    try std.testing.expectEqual(page.h - 80, rest.h);
    try std.testing.expectEqual(head.bottom(), rest.y);

    const side = page.left(200);
    const after = page.afterLeft(200);
    try std.testing.expectEqual(@as(f32, 200), side.w);
    try std.testing.expectEqual(side.right(), after.x);
    // A slice larger than the parent takes all of it and leaves nothing.
    try std.testing.expectEqual(page.h, page.top(9999).h);
    try std.testing.expect(page.belowTop(9999).isEmpty());
}

test "contains is half-open, so adjacent rectangles never both claim a pixel" {
    const a = rects.column(page, 2, 0, 0);
    const b = rects.column(page, 2, 1, 0);
    try std.testing.expect(a.contains(0, 0));
    try std.testing.expect(!a.contains(a.right(), 0));
    try std.testing.expect(b.contains(b.x, 0));
}

test "baselines step by the line height and capacity counts whole lines" {
    const body: R = .{ .x = 0, .y = 100, .w = 200, .h = 65 };
    try std.testing.expectEqual(@as(f32, 115), rects.baseline(body, 15, 20, 0));
    try std.testing.expectEqual(@as(f32, 135), rects.baseline(body, 15, 20, 1));
    try std.testing.expectEqual(@as(usize, 3), rects.lineCapacity(body, 20));
    try std.testing.expectEqual(@as(usize, 0), rects.lineCapacity(body, 0));
}
