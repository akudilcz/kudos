//! Function-plot maths — PURE (imports only std): per-column sampling of a
//! caller-supplied function, an auto y-range over the finite samples, and
//! "nice number" axis tick spacing. The calculator app maps the results to
//! pixels and draws with `Painter.line`; NaN/inf samples become gaps.

const std = @import("std");

pub const Range = struct {
    min: f64,
    max: f64,

    /// The same window scaled about its centre: factor > 1 zooms out (a wider
    /// span), factor < 1 zooms in. The centre never moves — zooming a plot
    /// keeps the reader's place.
    pub fn zoomed(self: Range, factor: f64) Range {
        const mid = (self.min + self.max) / 2;
        const half = (self.max - self.min) / 2 * factor;
        return .{ .min = mid - half, .max = mid + half };
    }
};

/// Fraction of the y-span added above and below the extremes so a curve never
/// kisses the viewport edge.
const AUTO_Y_PAD: f64 = 0.08;

/// The y-range when no sample is finite (or the function is constant): a unit
/// band around the value keeps the axes drawable instead of degenerate.
const FLAT_HALF_SPAN: f64 = 1.0;

/// Sample `f(ctx, x)` once per slot of `out`, x spanning `xr` inclusive.
pub fn sample(
    f: *const fn (ctx: *const anyopaque, x: f64) f64,
    ctx: *const anyopaque,
    xr: Range,
    out: []f64,
) void {
    if (out.len == 0) return;
    const n: f64 = @floatFromInt(out.len - 1);
    for (out, 0..) |*slot, i| {
        const t: f64 = if (out.len == 1) 0 else @as(f64, @floatFromInt(i)) / n;
        slot.* = f(ctx, xr.min + (xr.max - xr.min) * t);
    }
}

/// The y-range covering every FINITE sample, padded by AUTO_Y_PAD; a flat or
/// all-NaN sample set widens to a unit band so the viewport never collapses.
pub fn autoY(ys: []const f64) Range {
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (ys) |y| {
        if (!std.math.isFinite(y)) continue;
        lo = @min(lo, y);
        hi = @max(hi, y);
    }
    if (lo > hi) return .{ .min = -FLAT_HALF_SPAN, .max = FLAT_HALF_SPAN }; // nothing finite
    if (lo == hi) return .{ .min = lo - FLAT_HALF_SPAN, .max = hi + FLAT_HALF_SPAN };
    const pad = (hi - lo) * AUTO_Y_PAD;
    return .{ .min = lo - pad, .max = hi + pad };
}

/// A "nice" tick step (1, 2, or 5 × 10^k) giving roughly `target` ticks over
/// `span`. `span` must be positive and finite.
pub fn niceStep(span: f64, target: u32) f64 {
    const raw = span / @as(f64, @floatFromInt(@max(target, 1)));
    const mag = std.math.pow(f64, 10, @floor(std.math.log10(raw)));
    const norm = raw / mag; // 1..10
    const nice: f64 = if (norm <= 1.5) 1 else if (norm <= 3.5) 2 else if (norm <= 7.5) 5 else 10;
    return nice * mag;
}

/// The first tick at or above `min` for the given step.
pub fn firstTick(min: f64, step: f64) f64 {
    return @ceil(min / step) * step;
}
