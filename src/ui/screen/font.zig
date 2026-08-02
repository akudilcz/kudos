//! Anti-aliased monospace font. Embeds a fixed-cell 8-bit
//! ALPHA-COVERAGE atlas pre-rendered from Roboto Mono (scripts/gen-font.py);
//! the GL desktop uploads it once as a luminance-alpha texture (`ATLAS_LA`) and
//! every glyph is a textured quad, so text is smooth rather than 1-bpp. The cell
//! size is read from the atlas header at comptime — this module is the single
//! source other code reads `WIDTH`/`HEIGHT` from.

const std = @import("std");

const atlas = @embedFile("../assets/font_roboto.atlas");

// Header: magic, version, width, height, first, count (6 x u32 little-endian).
const HEADER = 24;
const MAGIC: u32 = 0x4B464E54; // "KFNT"

/// Read header word `i` (0-based, little-endian u32) from the atlas: the six
/// fields are magic, version, width, height, first-char, count — see the module
/// header.
fn hdr(i: usize) u32 {
    return std.mem.readInt(u32, atlas[i * 4 ..][0..4], .little);
}

pub const WIDTH: usize = hdr(2);
pub const HEIGHT: usize = hdr(3);
const FIRST: u8 = @intCast(hdr(4));
const COUNT: usize = hdr(5);
const CELL_BYTES = WIDTH * HEIGHT;

comptime {
    if (hdr(0) != MAGIC) @compileError("font atlas: bad magic (regenerate with scripts/gen-font.py)");
    if (hdr(1) != 1) @compileError("font atlas: unsupported version");
    if (atlas.len != HEADER + COUNT * CELL_BYTES) @compileError("font atlas: size mismatch vs header");
}

// ── the atlas as a GL texture ──────────────────────────────────────────────
// The body is COUNT glyphs of WIDTH×HEIGHT alpha, each row-major and contiguous,
// so it is already a WIDTH × (HEIGHT·COUNT) single-channel image: glyph `i` at
// rows [i·HEIGHT, (i+1)·HEIGHT). The GL text path uploads it verbatim (no CPU
// repack) and samples glyph i's vertical span [i/COUNT, (i+1)/COUNT] — see
// ui/screen/gltext.zig. First char and count feed the same `gltext.Atlas`.

/// Texture width for the GL atlas upload (one glyph cell wide).
pub const ATLAS_W: usize = WIDTH;
/// Texture height: every glyph cell stacked into one vertical strip.
pub const ATLAS_H: usize = HEIGHT * COUNT;
/// First character in the atlas, and how many it holds — the `gltext.Atlas` range.
pub const FIRST_CHAR: u8 = FIRST;
pub const GLYPH_COUNT: usize = COUNT;

/// The atlas as a luminance-alpha image (header stripped): the same `ATLAS_W × ATLAS_H`
/// vertical strip, but 2 bytes per texel with BOTH channels set to the glyph coverage.
///
/// The GL text path uploads THIS, not a GL_ALPHA image, for a subtle but decisive reason.
/// Sampling a GL_ALPHA texture yields rgb = 0, so a glyph tinted by glColor under the
/// default MODULATE texture environment comes out BLACK (colour · 0), whatever colour was
/// asked for. Luminance-alpha yields rgb = coverage, so colour · coverage is the glyph in
/// its colour, premultiplied — exactly what the premultiplied-over blend wants. Expanded
/// from the coverage at comptime, so the text path never allocates for it.
pub const ATLAS_LA: [(atlas.len - HEADER) * 2]u8 = blk: {
    @setEvalBranchQuota((atlas.len - HEADER) * 8 + 1000);
    var out: [(atlas.len - HEADER) * 2]u8 = undefined;
    for (atlas[HEADER..], 0..) |cov, i| {
        out[2 * i] = cov; // luminance = coverage
        out[2 * i + 1] = cov; // alpha    = coverage
    }
    break :blk out;
};
