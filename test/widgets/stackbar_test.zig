//! Host tests for the stacked bar's division: proportions hold, a sliver is never
//! rounded away to nothing, offsets follow the widths, and the segments never sum
//! past the bar they were given.

const std = @import("std");
const stackbar = @import("stackbar");

const Seg = stackbar.Segment;

const three = [_]Seg{
    .{ .label = "heap", .value = 500, .color = 0xFF3987E5 },
    .{ .label = "stacks", .value = 300, .color = 0xFFD55181 },
    .{ .label = "gpu", .value = 200, .color = 0xFF9085E9 },
};

test "the whole is the sum of the segments" {
    try std.testing.expectEqual(@as(u64, 1000), stackbar.total(&three));
    try std.testing.expectEqual(@as(u64, 0), stackbar.total(&.{}));
}

test "widths hold the segments' proportions once gaps are taken out" {
    const w: f32 = 302; // 300 of bar + two 1 px… no: two GAPs of 2 px minus one
    const usable = w - stackbar.GAP * 2;
    try std.testing.expectApproxEqAbs(usable * 0.5, stackbar.segmentWidth(&three, 0, w, 1000), 0.01);
    try std.testing.expectApproxEqAbs(usable * 0.3, stackbar.segmentWidth(&three, 1, w, 1000), 0.01);
    try std.testing.expectApproxEqAbs(usable * 0.2, stackbar.segmentWidth(&three, 2, w, 1000), 0.01);
}

test "segments never sum past the bar" {
    const w: f32 = 200;
    var sum: f32 = 0;
    for (0..three.len) |i| {
        sum += stackbar.segmentWidth(&three, i, w, 1000);
        if (i + 1 < three.len) sum += stackbar.GAP;
    }
    try std.testing.expect(sum <= w + 0.01);
}

test "a sliver keeps a pixel; nothing at all keeps none" {
    const segs = [_]Seg{
        .{ .label = "huge", .value = 1_000_000, .color = 0 },
        .{ .label = "sliver", .value = 1, .color = 0 },
        .{ .label = "absent", .value = 0, .color = 0 },
    };
    const w: f32 = 100;
    const whole = stackbar.total(&segs);
    try std.testing.expect(stackbar.segmentWidth(&segs, 1, w, whole) >= stackbar.MIN_SEGMENT);
    try std.testing.expectEqual(@as(f32, 0), stackbar.segmentWidth(&segs, 2, w, whole));
}

test "offsets accumulate the widths and their separators" {
    const w: f32 = 302;
    try std.testing.expectEqual(@as(f32, 0), stackbar.segmentOffset(&three, 0, w, 1000));
    const first = stackbar.segmentWidth(&three, 0, w, 1000);
    try std.testing.expectApproxEqAbs(first + stackbar.GAP, stackbar.segmentOffset(&three, 1, w, 1000), 0.01);
}

test "an absent segment leaves no gap behind it" {
    const segs = [_]Seg{
        .{ .label = "a", .value = 10, .color = 0 },
        .{ .label = "gone", .value = 0, .color = 0 },
        .{ .label = "b", .value = 10, .color = 0 },
    };
    const w: f32 = 100;
    const a_w = stackbar.segmentWidth(&segs, 0, w, 20);
    // 'gone' contributes neither width nor separator, so 'b' starts right after 'a'.
    try std.testing.expectApproxEqAbs(a_w + stackbar.GAP, stackbar.segmentOffset(&segs, 2, w, 20), 0.01);
}

test "a part-of-capacity bar leaves the remainder as bare track" {
    // 300 of a 1000 capacity: the segments occupy under a third of the width.
    const segs = [_]Seg{.{ .label = "used", .value = 300, .color = 0 }};
    const w: f32 = 100;
    try std.testing.expectApproxEqAbs(30, stackbar.segmentWidth(&segs, 0, w, 1000), 0.01);
}

test "degenerate inputs draw nothing rather than dividing by zero" {
    try std.testing.expectEqual(@as(f32, 0), stackbar.segmentWidth(&three, 0, 100, 0));
    try std.testing.expectEqual(@as(f32, 0), stackbar.segmentWidth(&three, 0, 0, 1000));
    try std.testing.expectEqual(@as(f32, 0), stackbar.segmentWidth(&three, 9, 100, 1000));
}

// ── the painted half ────────────────────────────────────────────────────────────

const kgl = @import("kgl");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");

test "the stack bar PAINTS: full-width segments and the part-of-capacity ribbon" {
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
    const segs = [_]stackbar.Segment{
        .{ .label = "a", .value = 30, .color = 0xFF0A84FF },
        .{ .label = "b", .value = 0, .color = 0xFF30D158 }, // absent: leaves no gap
        .{ .label = "c", .value = 20, .color = 0xFFFF9F0A },
    };
    stackbar.draw(&p, .{ .x = 4, .y = 4, .w = 100, .h = 10 }, &segs);
    stackbar.drawOfWhole(&p, .{ .x = 4, .y = 20, .w = 100, .h = 10 }, &segs, 200); // bare track shows
    stackbar.drawOfWhole(&p, .{ .x = 4, .y = 36, .w = 0, .h = 0 }, &segs, 200); // empty: no-op arm
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));
}
