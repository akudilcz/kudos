//! The dock's icon set. Embeds a fixed-cell 8-bit ALPHA-COVERAGE atlas baked
//! from the committed Phosphor SVGs (assets/icons/, MIT — scripts/gen-icons.py)
//! and expands it to luminance-alpha at comptime, exactly as the font atlas
//! does (src/ui/screen/font.zig): the desktop uploads it once and every icon is
//! a tinted textured quad. Cells are baked at twice the drawn size so the dock
//! draws them scaled down, crisp under linear sampling.

const std = @import("std");

const atlas = @embedFile("dock_icons.atlas");

// Header: magic, version, width, height, first, count (6 x u32 little-endian).
const HEADER = 24;
const MAGIC: u32 = 0x4B49434E; // "KICN"

fn hdr(i: usize) u32 {
    return std.mem.readInt(u32, atlas[i * 4 ..][0..4], .little);
}

/// One baked cell's edge, in texels (square cells).
pub const CELL: usize = hdr(2);
pub const COUNT: usize = hdr(5);
const CELL_BYTES = CELL * CELL;

comptime {
    if (hdr(0) != MAGIC) @compileError("icon atlas: bad magic (regenerate with scripts/gen-icons.py)");
    if (hdr(1) != 1) @compileError("icon atlas: unsupported version");
    if (hdr(3) != CELL) @compileError("icon atlas: cells must be square");
    if (atlas.len != HEADER + COUNT * CELL_BYTES) @compileError("icon atlas: size mismatch vs header");
}

/// Texture size for the GL upload: one cell wide, every cell stacked vertically.
pub const ATLAS_W: usize = CELL;
pub const ATLAS_H: usize = CELL * COUNT;

/// The atlas as luminance-alpha (see font.zig for why not GL_ALPHA: MODULATE
/// against rgb = 0 draws every tint black; rgb = coverage premultiplies).
pub const ATLAS_LA: [(atlas.len - HEADER) * 2]u8 = blk: {
    @setEvalBranchQuota((atlas.len - HEADER) * 8 + 1000);
    var out: [(atlas.len - HEADER) * 2]u8 = undefined;
    for (atlas[HEADER..], 0..) |cov, i| {
        out[2 * i] = cov;
        out[2 * i + 1] = cov;
    }
    break :blk out;
};
