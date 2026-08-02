//! Block-linear surface sizing — PURE module, host-tested. Derived from
//! Mesa NIL: GOB = 64 B × 8 rows on Ada; a block is 1 GOB wide × 2^bh_log2 GOBs
//! tall. Only the SIZING math lives here — the
//! intra-GOB swizzle is never computed on the CPU (texture upload goes
//! through the CE's pitch→blocklinear path, depth never leaves the GPU).

const std = @import("std");

pub const GOB_W: u32 = 64; // bytes
pub const GOB_H: u32 = 8; // rows

/// NIL's block-height pick: start at 2^5 GOBs and halve while a
/// full block would be ≥ 2× the surface height. Returns log2(GOBs per block).
pub fn blockHeightLog2(h_px: u32) u5 {
    var bh: u5 = 5;
    while (bh > 0 and (GOB_H << (bh - 1)) >= h_px) bh -= 1;
    return bh;
}

pub const Layout = struct {
    bh_log2: u5,
    row_stride_bytes: u32, // one row of blocks
    size_bytes: u64,
    align_bytes: u64, // base alignment = one block, min 4 KiB
};

/// Layout for a 2D block-linear surface of `w_px`×`h_px` at `bpp` bytes/px.
pub fn layout2d(w_px: u32, h_px: u32, bpp: u32) Layout {
    const bh = blockHeightLog2(h_px);
    const block_h_px: u32 = GOB_H << bh;
    const w_bytes = w_px * bpp;
    const blocks_per_row = std.math.divCeil(u32, w_bytes, GOB_W) catch unreachable;
    const block_rows = std.math.divCeil(u32, h_px, block_h_px) catch unreachable;
    const block_bytes: u64 = @as(u64, GOB_W) * GOB_H << bh;
    const alignment = @max(block_bytes, 0x1000);
    return .{
        .bh_log2 = bh,
        .row_stride_bytes = blocks_per_row * GOB_W,
        .size_bytes = std.mem.alignForward(u64, @as(u64, blocks_per_row) * block_rows * block_bytes, alignment),
        .align_bytes = alignment,
    };
}
