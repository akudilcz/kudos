//! GPU text geometry — the "no CPU font blit" primitive. PURE (imports only std):
//! given a monospace glyph atlas and a string, it produces the vertex POSITIONS
//! and texture COORDINATES for one `glDrawArrays(GL_TRIANGLES)`, written into
//! caller buffers (no allocation). The painter binds these as client vertex +
//! texcoord arrays, binds the atlas texture, and issues a single draw — the whole
//! string in one GPU call, sampled and blended by the hardware.
//!
//! The atlas is a vertical strip: a `cell_w × (cell_h × count)` texture whose glyph
//! `i` (character `first + i`) occupies rows `[i·cell_h, (i+1)·cell_h)`. That is the
//! byte order the existing coverage atlas already has, so it uploads with no CPU
//! repack — glyph `i`'s vertical texcoord span is simply `[i/count, (i+1)/count]`.
//!
//! Screen space, y DOWN, matching the painter's `orthof(0, w, h, 0)`.

const std = @import("std");

/// A glyph atlas laid out as a vertical strip of `count` cells.
///
/// Monospace by default: `advances == null` and every glyph occupies one full
/// `cell_w`. When `advances` is set (a per-glyph pen width in px from `first`,
/// e.g. font_prop.ADVANCES), text is PROPORTIONAL — the pen moves by each
/// glyph's advance and the quad samples only the `advance/cell_w` left slice of
/// its cell (the glyph is left-aligned there). `cell_w` is then the widest
/// glyph's box, not the advance.
pub const Atlas = struct {
    cell_w: f32,
    cell_h: f32,
    /// First character the atlas holds (e.g. 0x20, space).
    first: u8,
    /// Number of glyph cells stacked in the strip.
    count: u32,
    /// Per-glyph advance (px, from `first`); null = monospace (`cell_w` each).
    advances: ?[]const u8 = null,

    /// Pen advance (px) for `ch` at scale 1 — the glyph's own width when
    /// proportional, else the fixed cell.
    pub fn advance(self: Atlas, ch: u8) f32 {
        if (self.advances) |a| {
            if (ch >= self.first and ch < self.first + self.count) return @floatFromInt(a[ch - self.first]);
            return self.cell_w; // out-of-range byte takes a cell's room
        }
        return self.cell_w;
    }
};

/// Floats one glyph writes to EACH of the position and texcoord buffers: two
/// triangles = 6 vertices × 2 components. Callers size both buffers with this.
pub fn glyphFloats(glyphs: usize) usize {
    return glyphs * 6 * 2;
}

/// One glyph's box inside a PACKED sheet (baked by glyphcache.zig): where its ink
/// lives in the texture, how big that ink is in pixels, and where it sits relative
/// to the pen. The strip `Atlas` above holds one fixed cell per character at one
/// size; a packed sheet holds glyphs of many sizes, each its own ink box, which is
/// what lets text be drawn at any size from one texture.
pub const Glyph = struct {
    /// Texture coordinates of the ink box, 0..1.
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    /// Ink box size in pixels.
    w: f32,
    h: f32,
    /// Pen to the box's left edge, pixels (may be negative).
    left: f32,
    /// BASELINE to the box's top edge, pixels, negative upwards — so the box's
    /// top row is `baseline + top`.
    top: f32,
    /// Pen advance for this glyph, pixels.
    advance: f32,
};

/// A packed sheet's glyph table: character `first + i` is `glyphs[i]`.
pub const Sheet = struct {
    first: u8,
    glyphs: []const Glyph,

    /// The record for a byte, or null when it is outside the baked range.
    pub fn glyph(self: Sheet, ch: u8) ?Glyph {
        if (ch < self.first or ch - self.first >= self.glyphs.len) return null;
        return self.glyphs[ch - self.first];
    }
};

/// Emit the geometry for `str` drawn from a packed sheet. Unlike `string`, the pen
/// (`x`, `baseline`) is ON THE BASELINE — glyphs of different sizes only line up
/// if they share a baseline, and the ink box's height is not the line's height.
/// Characters outside the sheet advance by the sheet's own advance and emit
/// nothing. Returns the glyphs emitted; both buffers need `glyphFloats(str.len)`.
pub fn glyphString(pos_out: []f32, uv_out: []f32, sheet: Sheet, str: []const u8, x: f32, baseline: f32) u32 {
    var pen_x = x;
    var emitted: u32 = 0;
    var p: usize = 0;
    for (str) |ch| {
        const g = sheet.glyph(ch) orelse continue;
        defer pen_x += g.advance;
        if (g.w == 0 or g.h == 0) continue; // blank (space): advance only
        const x0 = pen_x + g.left;
        const y0 = baseline + g.top;
        const x1 = x0 + g.w;
        const y1 = y0 + g.h;
        // Two triangles, TL-TR-BL then BL-TR-BR — the winding the painter draws.
        const px = [6][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x0, y1 }, .{ x1, y0 }, .{ x1, y1 } };
        const uv = [6][2]f32{ .{ g.u0, g.v0 }, .{ g.u1, g.v0 }, .{ g.u0, g.v1 }, .{ g.u0, g.v1 }, .{ g.u1, g.v0 }, .{ g.u1, g.v1 } };
        for (px, uv) |vp, vt| {
            pos_out[p] = vp[0];
            pos_out[p + 1] = vp[1];
            uv_out[p] = vt[0];
            uv_out[p + 1] = vt[1];
            p += 2;
        }
        emitted += 1;
    }
    return emitted;
}

/// Pixel width a string occupies when drawn from a packed sheet.
pub fn glyphWidth(sheet: Sheet, str: []const u8) f32 {
    var w: f32 = 0;
    for (str) |ch| {
        if (sheet.glyph(ch)) |g| w += g.advance;
    }
    return w;
}

/// Emit the geometry for `str` starting at pen (`x`, `y`) — the top-left of the
/// first cell. Non-printable characters (outside the atlas range) advance the pen
/// but emit nothing, so a stray byte leaves a blank, never garbage. Returns the
/// number of glyphs actually emitted (≤ `str.len`); `pos_out` and `uv_out` must
/// each hold `glyphFloats(str.len)` floats.
pub fn string(pos_out: []f32, uv_out: []f32, atlas: Atlas, str: []const u8, x: f32, y: f32) u32 {
    var pen_x = x;
    var emitted: u32 = 0;
    var p: usize = 0; // write cursor into both buffers (they advance in lockstep)
    for (str) |ch| {
        const adv = atlas.advance(ch);
        const ch_h = atlas.cell_h;
        defer pen_x += adv;
        if (ch < atlas.first or ch >= atlas.first + atlas.count) continue;
        const i: f32 = @floatFromInt(ch - atlas.first);
        const n: f32 = @floatFromInt(atlas.count);
        const v0 = i / n;
        const v1 = (i + 1) / n;
        // Proportional: the glyph fills the `adv/cell_w` left slice of its cell.
        const ur: f32 = if (atlas.advances != null) adv / atlas.cell_w else 1;
        const x0 = pen_x;
        const x1 = pen_x + adv;
        const y0 = y;
        const y1 = y + ch_h;
        // Two triangles, TL-TR-BL then BL-TR-BR — the winding the painter draws.
        const px = [6][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x0, y1 }, .{ x1, y0 }, .{ x1, y1 } };
        const uv = [6][2]f32{ .{ 0, v0 }, .{ ur, v0 }, .{ 0, v1 }, .{ 0, v1 }, .{ ur, v0 }, .{ ur, v1 } };
        for (px, uv) |vp, vt| {
            pos_out[p] = vp[0];
            pos_out[p + 1] = vp[1];
            uv_out[p] = vt[0];
            uv_out[p + 1] = vt[1];
            p += 2;
        }
        emitted += 1;
    }
    return emitted;
}

/// Pixel width a string will occupy — the sum of per-glyph advances (monospace:
/// one cell each; proportional: each glyph's own advance). The WM uses it to
/// centre titles.
pub fn width(atlas: Atlas, str: []const u8) f32 {
    var w: f32 = 0;
    for (str) |ch| w += atlas.advance(ch);
    return w;
}
