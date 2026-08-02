//! Bakes a typeface into ONE packed coverage atlas at several pixel sizes, and
//! records where every glyph landed so text can be drawn from it in a single GPU
//! call. PURE (std + truetype + gltext): the caller owns the atlas bytes and the
//! glyph tables, this module only fills them.
//!
//! Why bake at all, when truetype.zig can rasterise on demand: a glyph outline
//! costs scanline work, and the renderer may not do that per frame. Baking happens
//! once at start-up (or when a new size is first asked for); every later frame is
//! textured quads out of the atlas, which is what the GPU is for.
//!
//! Layout is shelf packing: glyphs are placed left to right along a row whose
//! height is the tallest glyph placed on it, and a full row starts the next shelf
//! below. For a fixed-width face at a handful of sizes this wastes a few percent
//! of the sheet and needs no sorting, no allocation and no back-tracking.
//!
//! The atlas is 8-bit coverage — the same format the baked strip atlas uses,
//! so it uploads through the same path.

const std = @import("std");
const truetype = @import("truetype");
const gltext = @import("gltext");

pub const Error = error{
    /// The sheet has no room left for the glyphs still to place.
    AtlasFull,
    /// The caller's glyph table is smaller than the size list needs.
    TableTooSmall,
    /// The face could not be rasterised (see truetype.Error).
    BadGlyph,
};

/// Printable ASCII — the repertoire the system UI draws. Kept here as the one
/// home for "which characters are baked"; a caller asking for a different range
/// passes it to `bake`.
pub const FIRST_CHAR: u21 = 0x20;
pub const CHAR_COUNT: u16 = 95;

/// Transparent margin around each glyph inside the sheet, in pixels. Bilinear
/// sampling of a glyph's edge must never pick up its neighbour, and a rounded
/// pen position samples half a texel outside the box.
pub const PAD: u32 = 1;

/// One baked size of the face: the glyph table plus the vertical metrics text
/// layout needs at that size.
pub const Size = struct {
    /// Em size in pixels this was baked at.
    px: f32,
    /// Baseline to the highest ascender, pixels.
    ascent: f32,
    /// Baseline to the lowest descender, pixels.
    descent: f32,
    /// Baseline to baseline, pixels.
    line_height: f32,
    /// Pen advance of every glyph — the face is monospaced, so one figure serves
    /// the whole size and callers can lay out on a column grid.
    advance: f32,
    /// Where each character of the baked range sits in the sheet. Index `i` is
    /// character `FIRST_CHAR + i`.
    glyphs: [CHAR_COUNT]gltext.Glyph,

    /// This size's glyph table, in the form the text-geometry emitter takes.
    pub fn sheet(self: *const Size) gltext.Sheet {
        return .{ .first = @intCast(FIRST_CHAR), .glyphs = &self.glyphs };
    }

    /// The glyph record for a byte, or null when it is outside the baked range.
    pub fn glyph(self: *const Size, ch: u8) ?gltext.Glyph {
        return self.sheet().glyph(ch);
    }

    /// Pixel width of a string at this size.
    pub fn width(self: *const Size, str: []const u8) f32 {
        return self.advance * @as(f32, @floatFromInt(str.len));
    }
};

/// How much of the sheet a bake used — reported so a caller can size the sheet
/// from a real number instead of guessing, and so a test can assert the packer
/// does not silently sprawl.
pub const Usage = struct {
    /// Rows of the sheet actually touched.
    rows_used: u32,
    /// Glyph boxes placed.
    placed: u32,
};

/// Rasterise `sizes` of `font` into `sheet` (an `w × h` 8-bit coverage bitmap the
/// caller has cleared) and fill `out[i]` for each size. The sheet is written only
/// where glyphs land, so a caller may bake more sizes into the remaining room
/// later by passing the returned `rows_used` as the starting shelf.
pub fn bake(
    font: truetype.Font,
    sizes: []const f32,
    sheet: []u8,
    w: u32,
    h: u32,
    out: []Size,
) Error!Usage {
    if (out.len < sizes.len) return Error.TableTooSmall;
    var pen_x: u32 = PAD;
    var shelf_y: u32 = PAD;
    var shelf_h: u32 = 0;
    var placed: u32 = 0;

    for (sizes, 0..) |px, si| {
        const vm = font.lineMetrics(px);
        out[si] = .{
            .px = px,
            .ascent = vm.ascent,
            .descent = vm.descent,
            .line_height = vm.line_height,
            .advance = font.advancePx(font.glyphIndex('M'), px),
            .glyphs = undefined,
        };

        var i: u16 = 0;
        while (i < CHAR_COUNT) : (i += 1) {
            const cp: u21 = FIRST_CHAR + i;
            const gid = font.glyphIndex(cp);
            const m = font.measure(gid, px) catch return Error.BadGlyph;

            // A blank glyph (space) occupies no sheet room: it advances the pen
            // and samples nothing.
            if (m.width == 0 or m.height == 0) {
                out[si].glyphs[i] = .{
                    .u0 = 0,
                    .v0 = 0,
                    .u1 = 0,
                    .v1 = 0,
                    .w = 0,
                    .h = 0,
                    .left = 0,
                    .top = 0,
                    .advance = m.advance,
                };
                continue;
            }

            if (pen_x + m.width + PAD > w) { // shelf full: start the next one
                shelf_y += shelf_h + PAD;
                shelf_h = 0;
                pen_x = PAD;
            }
            if (shelf_y + m.height + PAD > h) return Error.AtlasFull;

            const dst_off = shelf_y * w + pen_x;
            _ = font.rasterize(gid, px, sheet[dst_off..], w) catch return Error.BadGlyph;

            const fw: f32 = @floatFromInt(w);
            const fh: f32 = @floatFromInt(h);
            out[si].glyphs[i] = .{
                .u0 = @as(f32, @floatFromInt(pen_x)) / fw,
                .v0 = @as(f32, @floatFromInt(shelf_y)) / fh,
                .u1 = @as(f32, @floatFromInt(pen_x + m.width)) / fw,
                .v1 = @as(f32, @floatFromInt(shelf_y + m.height)) / fh,
                .w = @floatFromInt(m.width),
                .h = @floatFromInt(m.height),
                .left = @floatFromInt(m.left),
                .top = @floatFromInt(m.top),
                .advance = m.advance,
            };
            pen_x += m.width + PAD;
            shelf_h = @max(shelf_h, m.height);
            placed += 1;
        }
    }
    return .{ .rows_used = shelf_y + shelf_h + PAD, .placed = placed };
}

/// Sheet area, in bytes, that baking `sizes` of `font` needs at width `w` — the
/// honest way to size the sheet before allocating it. Uses the same shelf rule as
/// `bake`, so a sheet of `w × sheetHeight(...)` never reports AtlasFull.
pub fn sheetHeight(font: truetype.Font, sizes: []const f32, w: u32) u32 {
    var pen_x: u32 = PAD;
    var shelf_y: u32 = PAD;
    var shelf_h: u32 = 0;
    for (sizes) |px| {
        var i: u16 = 0;
        while (i < CHAR_COUNT) : (i += 1) {
            const gid = font.glyphIndex(FIRST_CHAR + i);
            const m = font.measure(gid, px) catch continue;
            if (m.width == 0 or m.height == 0) continue;
            if (pen_x + m.width + PAD > w) {
                shelf_y += shelf_h + PAD;
                shelf_h = 0;
                pen_x = PAD;
            }
            pen_x += m.width + PAD;
            shelf_h = @max(shelf_h, m.height);
        }
    }
    return shelf_y + shelf_h + PAD;
}
