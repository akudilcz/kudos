//! Perceptual image comparison — the pure half of the Khronos reference
//! conformance suite (spec TEST-006, test/ui/assets/render_oracle_test.zig).
//!
//! Two renderers never agree byte-for-byte, so "consistent with the published
//! reference rendering" is judged coarsely: downscale both images onto one
//! small grid (box average — every source pixel contributes to exactly one
//! cell) and take the mean per-channel absolute error across the grid. The
//! downscale keeps composition and colour while forgiving resolution,
//! antialiasing and small pose differences; the mean error is then thresholded
//! by the caller, per model, against measured same-model/cross-model margins.
//!
//! All functions are pure over BGRA8 pixel buffers (the layout both the soft
//! rasteriser's framebuffer and png.decode produce); alpha is ignored — the
//! references are opaque renderings. Unit-tested in test/support/percept_test.zig.

const std = @import("std");

pub const BYTES_PER_PIXEL: usize = 4; // BGRA8

/// Box-average `bgra` (w*h*4 bytes, rows top-down) onto a grid*grid cell
/// lattice, returning grid*grid*3 channel means in B,G,R cell order. Cell
/// (cx,cy) averages the pixel block x in [w*cx/grid, w*(cx+1)/grid) (and
/// likewise for y), so uneven divisions spread the remainder across cells and
/// no pixel is dropped or double-counted. Requires w >= grid and h >= grid
/// (every cell non-empty).
pub fn downscale(comptime grid: usize, bgra: []const u8, w: usize, h: usize) [grid * grid * 3]f32 {
    std.debug.assert(w >= grid and h >= grid);
    std.debug.assert(bgra.len == w * h * BYTES_PER_PIXEL);
    var out: [grid * grid * 3]f32 = undefined;
    for (0..grid) |cy| {
        const y0 = h * cy / grid;
        const y1 = h * (cy + 1) / grid;
        for (0..grid) |cx| {
            const x0 = w * cx / grid;
            const x1 = w * (cx + 1) / grid;
            var sum = [3]f64{ 0, 0, 0 };
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    const px = bgra[(y * w + x) * BYTES_PER_PIXEL ..][0..BYTES_PER_PIXEL];
                    for (0..3) |c| sum[c] += @floatFromInt(px[c]);
                }
            }
            const n: f64 = @floatFromInt((y1 - y0) * (x1 - x0));
            const cell = (cy * grid + cx) * 3;
            for (0..3) |c| out[cell + c] = @floatCast(sum[c] / n);
        }
    }
    return out;
}

/// Mean absolute per-channel error between two equal-length channel grids
/// (downscale outputs), on the 0..255 scale of the source pixels.
pub fn meanAbsError(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len and a.len > 0);
    var sum: f64 = 0;
    for (a, b) |x, y| sum += @abs(x - y);
    return @floatCast(sum / @as(f64, @floatFromInt(a.len)));
}

/// Mean colour of the one-pixel border ring — the reference rendering's
/// backdrop. The backdrop is scene dressing, not model content, so the
/// conformance render adopts it as its clear colour and the error metric
/// measures the model, not the two renderers' taste in wallpaper.
pub fn borderMeanBgr(bgra: []const u8, w: usize, h: usize) [3]u8 {
    std.debug.assert(w >= 2 and h >= 2);
    std.debug.assert(bgra.len == w * h * BYTES_PER_PIXEL);
    var sum = [3]u64{ 0, 0, 0 };
    var n: u64 = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            if (y != 0 and y != h - 1 and x != 0 and x != w - 1) continue;
            const px = bgra[(y * w + x) * BYTES_PER_PIXEL ..][0..BYTES_PER_PIXEL];
            for (0..3) |c| sum[c] += px[c];
            n += 1;
        }
    }
    var out: [3]u8 = undefined;
    for (0..3) |c| out[c] = @intCast((sum[c] + n / 2) / n);
    return out;
}
