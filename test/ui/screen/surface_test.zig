//! Host tests of src/ui/screen/surface.zig.

const std = @import("std");
const surface = @import("surface");
const Surface = surface.Surface;
const blendConst = surface.blendConst;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const makeSurface = surface.makeSurface;
const refBlendChannel = surface.refBlendChannel;

test "blendConst is bit-exact to the rounded scalar reference (channel sweep)" {
    // Sweep every coverage, and a dense set of fg/bg channel values, checking each
    // channel independently (R, G, B share the same per-channel formula).
    var a: u32 = 0;
    while (a <= 255) : (a += 17) { // 0,17,...,255 — covers ends + interior
        const fa = a;
        const ia = 255 - a;
        var fc: u32 = 0;
        while (fc <= 255) : (fc += 1) {
            var bc: u32 = 0;
            while (bc <= 255) : (bc += 3) {
                // Put the same value in all three channels of fg and bg, so one
                // blendConst call exercises R, G, B at once.
                const fg = (fc << 16) | (fc << 8) | fc;
                const bg = (bc << 16) | (bc << 8) | bc;
                const out = blendConst(fg, bg, fa, ia);
                const want = refBlendChannel(fc, bc, fa, ia);
                try std.testing.expectEqual(want, (out >> 16) & 0xFF); // R
                try std.testing.expectEqual(want, (out >> 8) & 0xFF); // G
                try std.testing.expectEqual(want, out & 0xFF); // B
                try std.testing.expectEqual(@as(u32, 0), (out >> 24) & 0xFF); // top byte clear
            }
        }
    }
}

test "blendConst endpoints: a=255 copies fg, a=0 copies bg" {
    const fg: u32 = 0x00123456;
    const bg: u32 = 0x00ABCDEF;
    try std.testing.expectEqual(fg, blendConst(fg, bg, 255, 0));
    try std.testing.expectEqual(bg, blendConst(fg, bg, 0, 255));
}

test "fromSlice: stride equals width, no row padding" {
    var buf: [12]u32 = undefined;
    const s = makeSurface(&buf, 4, 3);
    try expectEqual(@as(usize, 4), s.w);
    try expectEqual(@as(usize, 3), s.h);
    try expectEqual(@as(usize, 4), s.stride);
    try expectEqual(@as([*]u32, buf[0..].ptr), s.px);
}

test "sub: offsets into the parent buffer and keeps the parent's stride" {
    var buf: [16]u32 = undefined; // 4x4
    const parent = makeSurface(&buf, 4, 4);
    const s = parent.sub(1, 1, 2, 2); // a 2x2 window starting at (1,1)
    try expectEqual(@as(usize, 2), s.w);
    try expectEqual(@as(usize, 2), s.h);
    try expectEqual(@as(usize, 4), s.stride); // parent's stride, not the sub-rect's width
    s.putPixel(0, 0, 0xAA); // writes at parent (1,1)
    try expectEqual(@as(u32, 0xAA), buf[1 * 4 + 1]);
}

test "putPixel: in-bounds write and out-of-bounds silent clip (x, y, and both)" {
    var buf: [9]u32 = undefined; // 3x3
    const s = makeSurface(&buf, 3, 3);
    s.putPixel(1, 1, 0x11);
    try expectEqual(@as(u32, 0x11), buf[1 * 3 + 1]);
    // Out of bounds on x, y, and both: must not write anywhere (no panic/wrap).
    s.putPixel(3, 0, 0x22);
    s.putPixel(0, 3, 0x33);
    s.putPixel(5, 5, 0x44);
    for (buf) |px| try expectEqual(@as(u32, if (px == 0x11) 0x11 else 0), px);
}

test "fill: sets every pixel in the surface" {
    var buf: [6]u32 = undefined; // 3x2
    const s = makeSurface(&buf, 3, 2);
    s.fill(0x42);
    for (buf) |px| try expectEqual(@as(u32, 0x42), px);
}

test "fillRect: clips to surface bounds when the rect overruns the edge" {
    var buf: [9]u32 = undefined; // 3x3, row-major
    const s = makeSurface(&buf, 3, 3);
    s.fillRect(2, 2, 5, 5, 0x7); // requested 5x5 at (2,2): only (2,2) is in-bounds
    try expectEqual(@as(u32, 0x7), buf[2 * 3 + 2]);
    var count: u32 = 0;
    for (buf) |px| {
        if (px == 0x7) count += 1;
    }
    try expectEqual(@as(u32, 1), count); // clipped to exactly one pixel, no overrun
}

test "blitPremult: srcA=0xFF is an opaque copy, srcA=0 (all-zero pixel) leaves dst" {
    var src_buf: [4]u32 = undefined; // 2x2, opaque red (premult: color == alpha-scaled)
    @memset(&src_buf, 0xFFFF0000);
    const src = Surface.fromSlice(&src_buf, 2, 2);
    var dst_buf: [4]u32 = undefined; // 2x2, all blue
    @memset(&dst_buf, 0x000000FF);
    const dst = Surface.fromSlice(&dst_buf, 2, 2);
    dst.blitPremult(src, 0, 0, 0, 0, 2, 2);
    for (dst_buf) |px| try expectEqual(@as(u32, 0x00FF0000), px); // fully replaced (out alpha 0)
    @memset(&src_buf, 0x00000000); // fully transparent premult pixel
    dst.blitPremult(src, 0, 0, 0, 0, 2, 2);
    for (dst_buf) |px| try expectEqual(@as(u32, 0x00FF0000), px); // unchanged
}

test "blitPremult: mid alpha blends per pixel against the scalar reference" {
    // srcA=0x80 red, premultiplied: r = round(255*0x80/255) = 0x80.
    var src_buf: [1]u32 = .{0x80800000};
    const src = Surface.fromSlice(&src_buf, 1, 1);
    var dst_buf: [1]u32 = .{0x000000FF}; // blue dst
    const dst = Surface.fromSlice(&dst_buf, 1, 1);
    dst.blitPremult(src, 0, 0, 0, 0, 1, 1);
    // out = src + round(dst*(255-0x80)/255): r = 0x80, b = round(255*127/255) = 127.
    try expectEqual(@as(u32, (0x80 << 16) | 127), dst_buf[0]);
}

test "blitPremult: per-PIXEL alpha — an opaque and a transparent pixel in one blit" {
    var src_buf: [2]u32 = .{ 0xFF00FF00, 0x00000000 }; // opaque green, transparent
    const src = Surface.fromSlice(&src_buf, 2, 1);
    var dst_buf: [2]u32 = .{ 0x000000FF, 0x000000FF };
    const dst = Surface.fromSlice(&dst_buf, 2, 1);
    dst.blitPremult(src, 0, 0, 0, 0, 2, 1);
    try expectEqual(@as(u32, 0x0000FF00), dst_buf[0]); // replaced
    try expectEqual(@as(u32, 0x000000FF), dst_buf[1]); // untouched
}

test "blitPremult: clips to the destination's remaining space when dx/dy + w/h overruns dst" {
    var src_buf: [4]u32 = undefined; // 2x2 opaque red
    @memset(&src_buf, 0xFFFF0000);
    const src = Surface.fromSlice(&src_buf, 2, 2);
    var dst_buf: [9]u32 = undefined; // 3x3, all blue
    @memset(&dst_buf, 0x000000FF);
    const dst = Surface.fromSlice(&dst_buf, 3, 3);
    // dst offset (2,2) with a 2x2 src: only dst's single (2,2) pixel is in range.
    dst.blitPremult(src, 0, 0, 2, 2, 2, 2);
    try expectEqual(@as(u32, 0x00FF0000), dst_buf[2 * 3 + 2]);
    var untouched: u32 = 0;
    for (dst_buf) |px| {
        if (px == 0x000000FF) untouched += 1;
    }
    try expectEqual(@as(u32, 8), untouched); // exactly 8 of 9 pixels untouched
}

test "blitPremult: clips to the SOURCE's remaining space when sx/sy leaves less than w/h available" {
    var src_buf: [9]u32 = undefined; // 3x3 opaque red
    @memset(&src_buf, 0xFFFF0000);
    const src = Surface.fromSlice(&src_buf, 3, 3);
    var dst_buf: [16]u32 = undefined; // 4x4, all blue
    @memset(&dst_buf, 0x000000FF);
    const dst = Surface.fromSlice(&dst_buf, 4, 4);
    // Source sub-origin (2,2) in a 3x3 src leaves only a 1x1 region available,
    // even though w/h request 3x3 and the dst has plenty of room.
    dst.blitPremult(src, 2, 2, 0, 0, 3, 3);
    try expectEqual(@as(u32, 0x00FF0000), dst_buf[0]); // the one pixel that WAS copied
    var untouched: u32 = 0;
    for (dst_buf) |px| {
        if (px == 0x000000FF) untouched += 1;
    }
    try expectEqual(@as(u32, 15), untouched); // exactly 15 of 16 pixels untouched
}

test "blitPremult: a shifted sub-surface (Surface.sub) composites at the correct offset" {
    // Mirrors how window content areas are drawn: a sub-region of a larger
    // destination receives a blit whose clip math must account for the parent's
    // stride, not the sub-rect's own width (this is the arithmetic the audit
    // flagged as untested: dx + (src.w - min(sx, src.w))).
    var parent_buf: [16]u32 = undefined; // 4x4 dst
    @memset(&parent_buf, 0x000000FF);
    const parent = Surface.fromSlice(&parent_buf, 4, 4);
    const region = parent.sub(1, 1, 2, 2); // 2x2 window content area at (1,1)

    var src_buf: [4]u32 = undefined; // 2x2, opaque premultiplied
    @memset(&src_buf, 0xFFFF0000);
    const src = Surface.fromSlice(&src_buf, 2, 2);

    region.blitPremult(src, 0, 0, 0, 0, 2, 2);
    // The write must land inside the sub-region's parent-relative footprint
    // (rows 1-2, cols 1-2), not at the parent's (0,0).
    try expectEqual(@as(u32, 0x00FF0000), parent_buf[1 * 4 + 1]);
    try expectEqual(@as(u32, 0x00FF0000), parent_buf[1 * 4 + 2]);
    try expectEqual(@as(u32, 0x00FF0000), parent_buf[2 * 4 + 1]);
    try expectEqual(@as(u32, 0x00FF0000), parent_buf[2 * 4 + 2]);
    // Everything outside the sub-region is untouched.
    try expectEqual(@as(u32, 0x000000FF), parent_buf[0]);
    try expectEqual(@as(u32, 0x000000FF), parent_buf[3 * 4 + 3]);
}
