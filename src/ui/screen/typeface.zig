//! The system typeface: the shipped outlines, baked once into ONE packed coverage
//! sheet at the handful of sizes the interface draws, and handed out as glyph
//! tables. This is the home of "which text sizes kudos has" — a surface asks for a
//! role, not a pixel count, so a size added here is available everywhere and a
//! size nobody names costs nothing.
//!
//! No device: baking is arithmetic over the font bytes, so this module stays at
//! the toolkit layer and is host-testable. Whoever owns the GL context uploads
//! `sheetBytes()` once (kgl.uploadAtlas) and passes the texture id back in with
//! every draw — the same split the fixed-cell atlas already uses.
//!
//! Baking happens once, at init, off any hot path: a frame only ever samples the
//! sheet (spec PERF-016).

const std = @import("std");
const truetype = @import("truetype");
const glyphcache = @import("glyphcache");
const gltext = @import("gltext");

/// The shipped face — the same file the fixed-cell atlas is baked from, so the
/// terminal grid and scalable text are one typeface.
const FONT_BYTES = @embedFile("font_ttf");

/// What a surface asks for. Sizes are a ratio ladder rather than arbitrary
/// numbers: each step is legible next to its neighbour, and a dense panel of
/// `.fine` reads as a different voice from a `.hero` figure, not as the same text
/// slightly smaller.
pub const Role = enum(u8) {
    /// Dense rows on a screen too small for `fine`.
    micro = 0,
    /// Counter walls and footnotes.
    fine = 1,
    /// Default interface text.
    body = 2,
    /// Panel headings and column labels.
    label = 3,
    /// A panel's headline figure.
    value = 4,
    /// The few numbers read from across a room.
    hero = 5,
    /// The wall clock.
    mega = 6,

    /// The next step DOWN the ladder, or the smallest role when there is none.
    /// A surface that must fit a small screen shifts the whole page by a step
    /// rather than picking new sizes: every voice on the page keeps its
    /// relationship to its neighbours, which is what the ratio ladder is for.
    pub fn smaller(self: Role) Role {
        const i = @intFromEnum(self);
        return if (i == 0) self else @enumFromInt(i - 1);
    }
};

/// Pixel em size per role, in `Role` order.
pub const SIZES = [_]f32{ 10, 12, 15, 20, 28, 44, 64 };

/// Sheet width. Wide enough that a 64 px shelf holds many glyphs, narrow enough
/// that the sheet stays a single modest allocation.
pub const SHEET_W: u32 = 1024;

var font: ?truetype.Font = null;
var sheet: []u8 = &.{};
var sheet_h: u32 = 0;
var sizes: [SIZES.len]glyphcache.Size = undefined;

pub const Error = error{ OutOfMemory, BadFont };

/// Parse the face and bake every role into the sheet. Call once, at start-up,
/// before anything draws. Idempotent: a second call keeps the first bake. The
/// bake lives until process exit — a host test passes a NON-TRACKING allocator
/// (page_allocator), because a process-lifetime singleton is not a leak.
pub fn init(a: std.mem.Allocator) Error!void {
    if (font != null) return;
    const f = truetype.Font.parse(FONT_BYTES) catch return Error.BadFont;
    const h = glyphcache.sheetHeight(f, &SIZES, SHEET_W);
    const bytes = try a.alloc(u8, SHEET_W * h);
    @memset(bytes, 0);
    _ = glyphcache.bake(f, &SIZES, bytes, SHEET_W, h, &sizes) catch {
        a.free(bytes);
        return Error.BadFont;
    };
    font = f;
    sheet = bytes;
    sheet_h = h;
}

/// Whether the typeface is baked and ready to draw.
pub fn ready() bool {
    return font != null;
}

/// The baked coverage sheet: `SHEET_W × sheetHeight()` bytes, one per texel.
pub fn sheetBytes() []const u8 {
    return sheet;
}

/// Rows in the baked sheet.
pub fn sheetHeight() u32 {
    return sheet_h;
}

/// The glyph table for a role — what `kgl.Painter.glyphText` draws from.
pub fn sheetFor(role: Role) gltext.Sheet {
    return sizes[@intFromEnum(role)].sheet();
}

/// The baked metrics for a role: advance, ascent, descent, line height.
pub fn metrics(role: Role) *const glyphcache.Size {
    return &sizes[@intFromEnum(role)];
}

/// Pen advance of one character at a role — the column width a monospaced layout
/// counts in.
pub fn advance(role: Role) f32 {
    return sizes[@intFromEnum(role)].advance;
}

/// Baseline-to-baseline distance at a role.
pub fn lineHeight(role: Role) f32 {
    return sizes[@intFromEnum(role)].line_height;
}

/// Pixel width `str` occupies at a role.
pub fn width(role: Role, str: []const u8) f32 {
    return sizes[@intFromEnum(role)].width(str);
}

/// How many characters of `role` fit in `px` pixels — what a surface asks before
/// it writes a label into a column it may be too narrow for.
pub fn fitChars(role: Role, px: f32) usize {
    const a = advance(role);
    if (a <= 0 or px <= 0) return 0;
    return @intFromFloat(@floor(px / a));
}

/// Whether every character of `str` is one the sheet was baked with. The baked
/// repertoire is printable ASCII (glyphcache.FIRST_CHAR, CHAR_COUNT) and text is
/// drawn byte by byte, so a typographic character would draw as NOTHING and still
/// take a pen width per byte — text that silently disappears. Callers keep their
/// labels drawable; this is the check that says whether they have.
pub fn drawable(str: []const u8) bool {
    for (str) |ch| {
        if (ch < glyphcache.FIRST_CHAR or ch >= glyphcache.FIRST_CHAR + glyphcache.CHAR_COUNT) return false;
    }
    return true;
}

/// Expand the coverage sheet into the luminance-alpha pairs the atlas texture
/// format wants, into a caller buffer of `sheetBytes().len * 2`. Coverage goes in
/// BOTH channels so tinted text takes its colour rather than sampling black
/// (see kgl.uploadAtlas). Called once, by whoever uploads the texture.
pub fn expandToLuminanceAlpha(dst: []u8) void {
    const src = sheet;
    var i: usize = 0;
    while (i < src.len and (i * 2 + 1) < dst.len) : (i += 1) {
        dst[i * 2] = src[i];
        dst[i * 2 + 1] = src[i];
    }
}
