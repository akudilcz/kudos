//! A stacked bar: one rectangle divided into segments in proportion to a set of
//! values, each segment its own colour. This is how kudos shows where a resource
//! WENT rather than merely how much is gone — physical memory by the purpose each
//! region is held for, the graphics carve by region, an application's footprint by
//! the pool it came from.
//!
//! The division (`segments`) is a pure function of the values and the bar width
//! and is host-tested; `draw` is the painter edge. Two rules the pure part
//! enforces, because a stacked bar that breaks them misinforms:
//!
//!   - A segment with a non-zero value is never rounded away to nothing. It gets
//!     at least one pixel, so "a sliver" and "none at all" never look the same.
//!   - Segments are separated by a hairline of the surface colour, so adjacent
//!     colours cannot be misread as one region.

const std = @import("std");
const kgl = @import("kgl");
const rects = @import("rects");
const theme = @import("theme");

/// Gap between segments, in pixels — a separator, not a margin.
pub const GAP: f32 = 2;
/// Narrowest a non-zero segment may be drawn.
pub const MIN_SEGMENT: f32 = 1;

/// One part of the whole: what it is, how much of it there is, and the colour
/// that identifies it. `label` travels with the segment so the legend and the bar
/// cannot drift apart.
pub const Segment = struct {
    label: []const u8,
    value: u64,
    color: u32,
};

/// Total of every segment's value — the denominator the division uses when the
/// caller does not supply a capacity of its own.
pub fn total(segs: []const Segment) u64 {
    var sum: u64 = 0;
    for (segs) |s| sum +|= s.value;
    return sum;
}

/// Width in pixels of segment `i` when `segs` are laid across `width` pixels of
/// a bar whose whole is `whole`. A non-zero value never yields zero width, and
/// the widths never sum past the bar: the last drawn segment absorbs rounding.
pub fn segmentWidth(segs: []const Segment, i: usize, width: f32, whole: u64) f32 {
    if (i >= segs.len or whole == 0 or width <= 0) return 0;
    const gaps = GAP * @as(f32, @floatFromInt(segs.len - 1));
    const usable = @max(0, width - gaps);
    const frac = @as(f32, @floatFromInt(segs[i].value)) / @as(f32, @floatFromInt(whole));
    const raw = usable * frac;
    if (segs[i].value == 0) return 0;
    return @max(MIN_SEGMENT, raw);
}

/// Left edge of segment `i`, relative to the bar's left edge.
pub fn segmentOffset(segs: []const Segment, i: usize, width: f32, whole: u64) f32 {
    var x: f32 = 0;
    var k: usize = 0;
    while (k < i and k < segs.len) : (k += 1) {
        const w = segmentWidth(segs, k, width, whole);
        x += w;
        if (w > 0) x += GAP;
    }
    return x;
}

/// Draw the stacked bar in `r`, dividing by the segments' own total.
pub fn draw(p: *kgl.Painter, r: rects.Rect, segs: []const Segment) void {
    drawOfWhole(p, r, segs, total(segs));
}

/// Draw the stacked bar in `r` against an explicit whole — the form to use when
/// the segments are a PART of a capacity (a 64 GiB span of which 18 GiB is spoken
/// for), so the unaccounted remainder stays visible as bare track.
pub fn drawOfWhole(p: *kgl.Painter, r: rects.Rect, segs: []const Segment, whole: u64) void {
    if (r.isEmpty()) return;
    // The track is the unallocated remainder: drawn first, left showing.
    p.fillRect(r.x, r.y, r.w, r.h, theme.CONTENT_BG);
    var x = r.x;
    for (segs, 0..) |s, i| {
        const w = segmentWidth(segs, i, r.w, whole);
        if (w <= 0) continue;
        const clipped = @min(w, @max(0, r.right() - x));
        if (clipped <= 0) break;
        p.fillRect(x, r.y, clipped, r.h, s.color);
        x += clipped + GAP;
    }
    p.rect(r.x, r.y, r.w, r.h, theme.BORDER);
}
