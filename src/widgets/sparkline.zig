//! A trace: a series of samples drawn as a polyline across a rectangle, with an
//! optional budget line. The shape of a metric over time is what turns a number
//! into a diagnosis — 60 Hz with one spike is a different machine from 60 Hz that
//! has been sagging for a minute, and both read "60" as a scalar.
//!
//! The mapping from sample to pixel (`plotX`, `plotY`, `rangeOf`) is pure and
//! host-tested; `draw` is the painter edge. Drawn with line segments only: the
//! painter has no polyline primitive and a HUD must not invent one.
//!
//! Ranging rules, because an auto-scaled axis can flatter or panic:
//!   - A caller-supplied range is honoured exactly. A trace with a budget (frame
//!     time against 16.7 ms) must not rescale under the budget line, or a
//!     breach stops looking like one.
//!   - An auto range never collapses: a flat series still gets a band, so noise
//!     in the last digit is not magnified into a mountain range.

const std = @import("std");
const kgl = @import("kgl");
const rects = @import("rects");
const theme = @import("theme");

/// Value band a trace is drawn against.
pub const Range = struct {
    min: f64,
    max: f64,

    /// Height of the band, never zero (see the ranging rules above).
    pub fn span(self: Range) f64 {
        const d = self.max - self.min;
        return if (d > 0) d else 1;
    }
};

/// A band that holds `min`..`max` with a tenth of headroom, floored at zero for
/// series that cannot go negative, and never collapsed. Used when the caller has
/// no natural scale of its own.
pub fn autoRange(min: f64, max: f64, zero_based: bool) Range {
    var lo: f64 = if (zero_based) 0 else min;
    var hi = max;
    if (hi <= lo) hi = lo + 1;
    const pad = (hi - lo) * 0.1;
    hi += pad;
    if (!zero_based) lo -= pad;
    return .{ .min = lo, .max = hi };
}

/// X of sample `i` of `n` across `r` — oldest at the left edge, newest at the
/// right, so a trace always reads left-to-right in time.
pub fn plotX(r: rects.Rect, n: usize, i: usize) f32 {
    if (n <= 1) return r.right();
    const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
    return r.x + r.w * t;
}

/// Y of `value` in `r` under `range` — clamped to the rectangle, so an excursion
/// beyond the band rides the edge instead of drawing outside the panel.
pub fn plotY(r: rects.Rect, range: Range, value: f64) f32 {
    const t = (value - range.min) / range.span();
    const clamped = @max(0.0, @min(1.0, t));
    return r.bottom() - r.h * @as(f32, @floatCast(clamped));
}

/// Draw a trace of `n` samples read through `sample`, in `color`.
///
/// `sample` is a function rather than a slice because the samples live in a ring:
/// handing over a slice would mean copying the ring straight, per series, per
/// frame — an allocation and a memcpy on the draw path to save an indirect call.
pub fn draw(
    p: *kgl.Painter,
    r: rects.Rect,
    n: usize,
    ctx: *const anyopaque,
    sample: *const fn (ctx: *const anyopaque, i: usize) f64,
    range: Range,
    color: u32,
) void {
    if (r.isEmpty() or n < 2) return;
    var prev_x = plotX(r, n, 0);
    var prev_y = plotY(r, range, sample(ctx, 0));
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const x = plotX(r, n, i);
        const y = plotY(r, range, sample(ctx, i));
        p.line(prev_x, prev_y, x, y, 1.5, color);
        prev_x = x;
        prev_y = y;
    }
}

/// Draw a horizontal reference line across `r` at `value` — a budget, a target, a
/// limit. Dashed, in the caller's colour, so it reads as an annotation and never
/// as another series.
pub fn budgetLine(p: *kgl.Painter, r: rects.Rect, range: Range, value: f64, color: u32) void {
    if (r.isEmpty()) return;
    const y = plotY(r, range, value);
    const dash: f32 = 6;
    const gap: f32 = 5;
    var x = r.x;
    while (x < r.right()) : (x += dash + gap) {
        const end = @min(x + dash, r.right());
        p.line(x, y, end, y, 1, color);
    }
}

/// Draw the baseline a trace sits on — the panel's floor, in the theme's border
/// colour. Separate from `draw` so a panel with several traces draws one floor.
pub fn floor(p: *kgl.Painter, r: rects.Rect) void {
    if (r.isEmpty()) return;
    p.line(r.x, r.bottom(), r.right(), r.bottom(), 1, theme.BORDER);
}
