//! A stat tile: a small caption, one large figure, its unit, and an optional
//! trend arrow. The unit of a vitals strip — the numbers meant to be read at a
//! glance from across the room, as against the dense rows inside a panel.
//!
//! The layout (`valueBaseline`, `unitX`, `height`) is pure and host-tested;
//! `draw` is the painter edge. The three sizes come from the caller as a `Type`,
//! so a page set a step down the ladder for a small screen carries its tiles with
//! it. The figure and its unit are set at different sizes and share a baseline,
//! which is the whole reason the HUD needed outlines rather than a fixed cell: a
//! 44 px figure beside a 15 px unit is one line of type, not two rows that happen
//! to be adjacent.

const std = @import("std");
const kgl = @import("kgl");
const rects = @import("rects");
const typeface = @import("typeface");
const theme = @import("theme");

/// Gap between the figure and its unit, in pixels.
pub const UNIT_GAP: f32 = 4;
/// Leading between the caption's baseline and the figure's, as a fraction of the
/// caption's line height.
pub const CAPTION_LEAD: f32 = 0.35;

/// The three voices of a tile.
pub const Type = struct {
    /// The caption over the figure.
    caption: typeface.Role = .fine,
    /// The figure itself.
    value: typeface.Role = .hero,
    /// The unit and the trend mark beside it.
    unit: typeface.Role = .body,
};

/// Which way a value is moving, and whether that is worth showing at all.
pub const Trend = enum {
    none,
    rising,
    falling,

    /// The glyph that states the trend. ASCII: the typeface is baked over
    /// printable ASCII, and a missing glyph would silently draw nothing.
    pub fn mark(self: Trend) []const u8 {
        return switch (self) {
            .none => "",
            .rising => "^",
            .falling => "v",
        };
    }
};

/// Baseline of the caption line.
pub fn captionBaseline(r: rects.Rect, t: Type) f32 {
    return r.y + typeface.metrics(t.caption).ascent;
}

/// Baseline shared by the figure and its unit.
pub fn valueBaseline(r: rects.Rect, t: Type) f32 {
    return captionBaseline(r, t) + typeface.lineHeight(t.caption) * CAPTION_LEAD + typeface.metrics(t.value).ascent;
}

/// Height a tile's ink occupies — what a strip of tiles asks the page for.
pub fn height(t: Type) f32 {
    const m = typeface.metrics(t.value);
    return typeface.metrics(t.caption).ascent + typeface.lineHeight(t.caption) * CAPTION_LEAD + m.ascent + m.descent;
}

/// X at which the unit is drawn, given the figure's width.
pub fn unitX(r: rects.Rect, t: Type, value: []const u8) f32 {
    return r.x + typeface.width(t.value, value) + UNIT_GAP;
}

/// Draw the tile. `color` applies to the figure only: the caption and unit stay in
/// the theme's recessive inks so a coloured figure means something.
pub fn draw(
    p: *kgl.Painter,
    sheet_tex: u32,
    r: rects.Rect,
    t: Type,
    caption: []const u8,
    value: []const u8,
    unit: []const u8,
    color: u32,
    trend: Trend,
) void {
    if (r.isEmpty()) return;
    p.glyphText(sheet_tex, typeface.sheetFor(t.caption), caption, r.x, captionBaseline(r, t), theme.DIM);

    const base = valueBaseline(r, t);
    p.glyphText(sheet_tex, typeface.sheetFor(t.value), value, r.x, base, color);

    var x = unitX(r, t, value);
    if (unit.len > 0) {
        p.glyphText(sheet_tex, typeface.sheetFor(t.unit), unit, x, base, theme.DIM);
        x += typeface.width(t.unit, unit) + UNIT_GAP;
    }
    const mark = trend.mark();
    if (mark.len > 0) {
        p.glyphText(sheet_tex, typeface.sheetFor(t.unit), mark, x, base, theme.DIM);
    }
}
