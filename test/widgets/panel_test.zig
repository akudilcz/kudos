//! Host tests for the panel frame's geometry: the body sits under the header and
//! inside the padding, the header's text is centred in its strip, a panel too
//! small for its own frame yields an empty body rather than a negative one, and
//! the body cursor keeps its content inside the body — refusing what will not fit
//! and counting it, which is what stops a panel drawing over the band below it.

const std = @import("std");
const panel = @import("panel");
const rects = @import("rects");
const typeface = @import("typeface");
const theme = @import("theme");

const frame: rects.Rect = .{ .x = 40, .y = 20, .w = 400, .h = 300 };
const chrome: panel.Chrome = .{};

test "the header strip is the theme's dashboard header height" {
    try std.testing.expectEqual(@as(f32, @floatFromInt(theme.HEADER_H)), panel.HEADER_H);
}

test "the body sits below the header and inside the padding" {
    const body = panel.bodyOf(frame, chrome);
    try std.testing.expectEqual(frame.x + chrome.pad, body.x);
    try std.testing.expectEqual(frame.y + chrome.header_h + chrome.pad * panel.PAD_Y, body.y);
    try std.testing.expectEqual(frame.w - 2 * chrome.pad, body.w);
    try std.testing.expect(body.bottom() <= frame.bottom());
}

test "the frame's overhead is exactly what the body loses to it" {
    const body = panel.bodyOf(frame, chrome);
    try std.testing.expectApproxEqAbs(frame.h - body.h, chrome.overhead(), 0.001);
}

test "a panel with no room left for a body reports an empty one" {
    const squashed: rects.Rect = .{ .x = 0, .y = 0, .w = 100, .h = chrome.header_h };
    try std.testing.expect(panel.bodyOf(squashed, chrome).isEmpty());
    const narrow: rects.Rect = .{ .x = 0, .y = 0, .w = 4, .h = 200 };
    try std.testing.expectEqual(@as(f32, 0), panel.bodyOf(narrow, chrome).w);
}

test "the title's baseline centres its text in the header strip" {
    try typeface.init(std.heap.page_allocator);
    const base = panel.titleBaseline(frame, chrome.title, chrome.header_h);
    const m = typeface.metrics(chrome.title);
    try std.testing.expect(base > frame.y);
    try std.testing.expect(base < frame.y + chrome.header_h);
    // Equal ink above the baseline and descender room below it.
    const above = base - frame.y;
    const below = frame.y + chrome.header_h - base;
    try std.testing.expectApproxEqAbs(above - m.ascent, below - m.descent, 0.01);
}

test "the accent tick is narrower than the padding, so it never touches the title" {
    try std.testing.expect(panel.TICK_W < panel.PAD);
}

test "a body cursor lays its rows down the body, each under the last" {
    try typeface.init(std.heap.page_allocator);
    const body: rects.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var rows = panel.Rows.probing(body, .body);
    const first = rows.take(30).?;
    const second = rows.take(30).?;
    try std.testing.expectEqual(body.y, first.y);
    try std.testing.expectEqual(first.bottom(), second.y);
    try std.testing.expectEqual(body.w, first.w);
    try std.testing.expectEqual(@as(f32, 60), rows.used);
    try std.testing.expectEqual(@as(f32, 40), rows.room());
}

test "a claim the body has no room for is refused and counted, not clipped" {
    try typeface.init(std.heap.page_allocator);
    const body: rects.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 50 };
    var rows = panel.Rows.probing(body, .body);
    try std.testing.expect(rows.take(40) != null);
    try std.testing.expect(rows.take(40) == null);
    try std.testing.expectEqual(@as(usize, 1), rows.dropped);
    // A refusal costs the body nothing: a later, smaller reading still fits.
    try std.testing.expect(rows.take(10) != null);
    try std.testing.expectEqual(@as(f32, 50), rows.used);
}

test "a claim is not refused over a fraction of a pixel" {
    // Body heights and content heights are both sums of float sizes. A reading
    // hidden because those sums disagreed in the third decimal would be a lie
    // about the machine told by a rounding error.
    try typeface.init(std.heap.page_allocator);
    const body: rects.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 99.9999 };
    var rows = panel.Rows.probing(body, .body);
    try std.testing.expect(rows.take(100) != null);
    try std.testing.expectEqual(@as(usize, 0), rows.dropped);
}

test "a measuring cursor refuses nothing and reports what the fill asked for" {
    try typeface.init(std.heap.page_allocator);
    var rows = panel.Rows.measuring(.body);
    try std.testing.expect(rows.unbounded);
    var i: usize = 0;
    while (i < 500) : (i += 1) _ = rows.take(40);
    try std.testing.expectEqual(@as(usize, 0), rows.dropped);
    try std.testing.expectEqual(@as(f32, 500 * 40), rows.used);
}

test "gaps carry the stretch, and count themselves so it can be divided" {
    try typeface.init(std.heap.page_allocator);
    const body: rects.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 300 };
    var rows = panel.Rows.probing(body, .body);
    rows.stretch = 10;
    rows.space(4);
    rows.space(4);
    try std.testing.expectEqual(@as(usize, 2), rows.gaps);
    try std.testing.expectEqual(@as(f32, 28), rows.used);
}

test "space never runs a body past its bottom" {
    try typeface.init(std.heap.page_allocator);
    const body: rects.Rect = .{ .x = 0, .y = 0, .w = 200, .h = 30 };
    var rows = panel.Rows.probing(body, .body);
    rows.space(500);
    try std.testing.expectEqual(@as(f32, 30), rows.used);
    try std.testing.expectEqual(@as(f32, 0), rows.room());
}
