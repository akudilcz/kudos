//! The rectangle algebra every widget lays itself out with: split a rectangle into
//! rows, columns or a grid, inset it, take a slice off an edge. PURE (imports only
//! std) — no painter, no theme, no device — so a screen's whole layout can be
//! computed and asserted on the host before a single pixel is drawn.
//!
//! Pixels are floats because the painter's vertices are: rounding once, at the
//! draw call, keeps a column of panels from accumulating a half-pixel of drift
//! down the screen.

const std = @import("std");

/// A screen-space rectangle: x right, y down, matching the painter's projection.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }

    /// Shrink by `d` on every side. A rectangle smaller than the inset collapses
    /// to zero rather than inverting — a negative size would draw inside-out.
    pub fn inset(self: Rect, d: f32) Rect {
        return self.insetXY(d, d);
    }

    /// Shrink by `dx` left and right, `dy` top and bottom.
    pub fn insetXY(self: Rect, dx: f32, dy: f32) Rect {
        return .{
            .x = self.x + dx,
            .y = self.y + dy,
            .w = @max(0, self.w - 2 * dx),
            .h = @max(0, self.h - 2 * dy),
        };
    }

    /// The top `h` pixels.
    pub fn top(self: Rect, h: f32) Rect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = @min(h, self.h) };
    }

    /// Everything below the top `h` pixels.
    pub fn belowTop(self: Rect, h: f32) Rect {
        const cut = @min(h, self.h);
        return .{ .x = self.x, .y = self.y + cut, .w = self.w, .h = self.h - cut };
    }

    /// The left `w` pixels.
    pub fn left(self: Rect, w: f32) Rect {
        return .{ .x = self.x, .y = self.y, .w = @min(w, self.w), .h = self.h };
    }

    /// Everything right of the left `w` pixels.
    pub fn afterLeft(self: Rect, w: f32) Rect {
        const cut = @min(w, self.w);
        return .{ .x = self.x + cut, .y = self.y, .w = self.w - cut, .h = self.h };
    }

    /// Whether a point is inside — the hit test every clickable widget shares.
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

/// Split `r` into `n` equal columns separated by `gap`, and return column `i`.
/// An out-of-range index returns an empty rectangle rather than drawing off the
/// end of the parent.
pub fn column(r: Rect, n: usize, i: usize, gap: f32) Rect {
    if (n == 0 or i >= n) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    const fn_: f32 = @floatFromInt(n);
    const w = (r.w - gap * (fn_ - 1)) / fn_;
    if (w <= 0) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    return .{ .x = r.x + (w + gap) * @as(f32, @floatFromInt(i)), .y = r.y, .w = w, .h = r.h };
}

/// Split `r` into `n` equal rows separated by `gap`, and return row `i`.
pub fn row(r: Rect, n: usize, i: usize, gap: f32) Rect {
    if (n == 0 or i >= n) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    const fn_: f32 = @floatFromInt(n);
    const h = (r.h - gap * (fn_ - 1)) / fn_;
    if (h <= 0) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    return .{ .x = r.x, .y = r.y + (h + gap) * @as(f32, @floatFromInt(i)), .w = r.w, .h = h };
}

/// Cell (`col`, `row`) of a `cols × rows` grid over `r`, with `gap` between cells.
pub fn cell(r: Rect, cols: usize, rows: usize, col: usize, row_i: usize, gap: f32) Rect {
    return row(column(r, cols, col, gap), rows, row_i, gap);
}

/// Split `r` into columns whose widths are proportional to `weights`, and return
/// column `i`. The workhorse for a page whose columns are not equal — a 2:3:2
/// split states its intent where three magic numbers would not.
pub fn weighted(r: Rect, weights: []const f32, i: usize, gap: f32) Rect {
    if (i >= weights.len) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    var total: f32 = 0;
    for (weights) |w| total += w;
    if (total <= 0) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    const free = r.w - gap * @as(f32, @floatFromInt(weights.len - 1));
    var x = r.x;
    for (weights[0..i]) |w| x += free * (w / total) + gap;
    return .{ .x = x, .y = r.y, .w = @max(0, free * (weights[i] / total)), .h = r.h };
}

/// Split `r` into rows whose heights are proportional to `weights`, and return
/// row `i`.
pub fn weightedRow(r: Rect, weights: []const f32, i: usize, gap: f32) Rect {
    if (i >= weights.len) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    var total: f32 = 0;
    for (weights) |w| total += w;
    if (total <= 0) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    const free = r.h - gap * @as(f32, @floatFromInt(weights.len - 1));
    var y = r.y;
    for (weights[0..i]) |w| y += free * (w / total) + gap;
    return .{ .x = r.x, .y = y, .w = r.w, .h = @max(0, free * (weights[i] / total)) };
}

/// Successive baselines down a rectangle: the y of text line `i` when the first
/// line's baseline sits `ascent` below the top and lines are `line_h` apart.
pub fn baseline(r: Rect, ascent: f32, line_h: f32, i: usize) f32 {
    return r.y + ascent + line_h * @as(f32, @floatFromInt(i));
}

/// How many lines of `line_h` fit in `r` — what a panel asks before it starts
/// filling itself with rows it cannot show.
pub fn lineCapacity(r: Rect, line_h: f32) usize {
    if (line_h <= 0 or r.h <= 0) return 0;
    return @intFromFloat(@floor(r.h / line_h));
}
