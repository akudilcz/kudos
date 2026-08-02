//! Unit tests for the perceptual-comparison metric (test/support/percept.zig) — the
//! pure half of the TEST-006 Khronos reference conformance suite. The metric
//! gates real conformance verdicts, so its arithmetic is pinned here with
//! hand-computable cases: box-average coverage (uneven divisions included),
//! exact error values, and the border-ring backdrop mean.

const std = @import("std");
const percept = @import("percept.zig");

const BPP = percept.BYTES_PER_PIXEL;

/// A w*h BGRA buffer filled with one colour, alpha 0xFF.
fn solid(comptime w: usize, comptime h: usize, b: u8, g: u8, r: u8) [w * h * BPP]u8 {
    var out: [w * h * BPP]u8 = undefined;
    var i: usize = 0;
    while (i < w * h) : (i += 1) {
        out[i * BPP + 0] = b;
        out[i * BPP + 1] = g;
        out[i * BPP + 2] = r;
        out[i * BPP + 3] = 0xFF;
    }
    return out;
}

test "identical images have zero error" {
    const img = solid(8, 8, 10, 20, 30);
    const a = percept.downscale(4, &img, 8, 8);
    const b = percept.downscale(4, &img, 8, 8);
    try std.testing.expectEqual(@as(f32, 0), percept.meanAbsError(&a, &b));
}

test "a uniform +10 per-channel shift measures exactly 10" {
    const a_img = solid(8, 8, 100, 100, 100);
    const b_img = solid(8, 8, 110, 110, 110);
    const a = percept.downscale(4, &a_img, 8, 8);
    const b = percept.downscale(4, &b_img, 8, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 10), percept.meanAbsError(&a, &b), 1e-4);
}

test "downscale box-averages every pixel of a cell" {
    // 2x2 image onto a 1x1 grid: the one cell is the plain mean of all four
    // pixels, per channel. Pixels: B channel 0,10,20,30 -> mean 15.
    var img = solid(2, 2, 0, 0, 0);
    img[0 * BPP] = 0;
    img[1 * BPP] = 10;
    img[2 * BPP] = 20;
    img[3 * BPP] = 30;
    const cells = percept.downscale(1, &img, 2, 2);
    try std.testing.expectApproxEqAbs(@as(f32, 15), cells[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cells[1], 1e-4); // G untouched
}

test "uneven division drops no pixel: 3x3 onto 2x2 covers all nine" {
    // Cell boundaries at 3*1/2 = 1: cells cover 1x1, 2x1, 1x2 and 2x2 pixel
    // blocks. A lone bright pixel in the far corner must land (undiluted by
    // dropped neighbours) in the last cell's 2x2 block: mean = 200/4 = 50.
    var img = solid(3, 3, 0, 0, 0);
    img[(2 * 3 + 2) * BPP] = 200; // pixel (2,2), B channel
    const cells = percept.downscale(2, &img, 3, 3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cells[0 * 3], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 50), cells[3 * 3], 1e-4);
}

test "alpha never contributes to the error" {
    var a_img = solid(4, 4, 7, 7, 7);
    var b_img = solid(4, 4, 7, 7, 7);
    a_img[3] = 0x00; // divergent alpha, first pixel
    b_img[3] = 0xFF;
    const a = percept.downscale(2, &a_img, 4, 4);
    const b = percept.downscale(2, &b_img, 4, 4);
    try std.testing.expectEqual(@as(f32, 0), percept.meanAbsError(&a, &b));
}

test "borderMeanBgr reads the ring, never the interior" {
    // 4x4: border ring dark (10), interior 2x2 bright (250). The mean must be
    // exactly the ring's 10 — any interior contribution would pull it up.
    var img = solid(4, 4, 10, 10, 10);
    for ([_]usize{ 5, 6, 9, 10 }) |i| { // interior pixels of a 4x4
        img[i * BPP + 0] = 250;
        img[i * BPP + 1] = 250;
        img[i * BPP + 2] = 250;
    }
    try std.testing.expectEqual([3]u8{ 10, 10, 10 }, percept.borderMeanBgr(&img, 4, 4));
}
