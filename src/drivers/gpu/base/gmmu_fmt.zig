//! GP100-format GMMU page-table bit encoding — the pure VA→index extraction +
//! PTE/PDE encode/decode.
//! Kept free of the mmio writes in gmmu.zig so this bit-twiddling — the exact
//! place a shift error silently corrupts every mapping — is host-testable.
//! Single source of truth: gmmu.zig imports these. No hardware import.

/// PDE aperture encoding (gp100_vmm_pde): VRAM=1 at bit1. NO valid bit.
pub const PDE_APER_VRAM: u64 = 1 << 1;
/// PTE bits (gp100_vmm_pgt_pte/valid): VALID bit0; aperture at bits 2:1
/// (VRAM=0, HOST=2); VOL bit3 for coherent sysmem.
pub const PTE_VALID: u64 = 1 << 0;
pub const PTE_APER_HOST: u64 = 2 << 1;
pub const PTE_VOL: u64 = 1 << 3;

/// Sysmem (coherent host) PTE control bits.
pub const PTE_SYSMEM: u64 = PTE_VALID | PTE_APER_HOST | PTE_VOL;
/// VRAM PTE control bits (aperture VRAM = 0).
pub const PTE_VRAM: u64 = PTE_VALID;

/// The three page-table indices for `va` in the MVP window (L3 entry 0):
///  L2 index  = va[37:29] (512 MiB granularity, 0..7 in-window),
///  PD0 index = va[28:21] (2 MiB, 8-bit, 16-byte entries),
///  SPT index = va[20:12] (4 KiB, 9-bit).
pub const Index = struct { l2: u64, pd0: u64, spt: u64 };
pub fn indices(va: u64) Index {
    return .{
        .l2 = (va >> 29) & 0x1ff,
        .pd0 = (va >> 21) & 0xff,
        .spt = (va >> 12) & 0x1ff,
    };
}

/// True if `va` is outside the MVP window (above 4 GiB, i.e. any bit ≥ 38, or an
/// L2 index past the `pd0_len` PD0 slots the MVP allocates).
pub fn vaOutOfRange(va: u64, pd0_len: u64) bool {
    return (va >> 38) != 0 or ((va >> 29) & 0x1ff) >= pd0_len;
}

/// Encode a leaf PTE: physical page `phys` + control `type_bits`. The address is
/// stored as `phys >> 4` (16-byte granularity) in the high bits.
pub fn encodePte(phys: u64, type_bits: u64) u64 {
    return (phys >> 4) | type_bits;
}

/// Encode a PDE pointing at a VRAM child table at `child_phys`.
pub fn encodePde(child_phys: u64) u64 {
    return (child_phys >> 4) | PDE_APER_VRAM;
}

/// Decode a PDE's child-table phys from its two 32-bit halves. Masks the low 4
/// control bits, then shifts the 16-byte-granular address back up.
pub fn decodePde(lo: u32, hi: u32) u64 {
    return ((@as(u64, hi) << 32 | lo) & ~@as(u64, 0xf)) << 4;
}

/// True if a leaf PTE (its low 32 bits) is already valid (bit 0 set).
pub fn pteValid(lo: u32) bool {
    return (lo & 1) != 0;
}

// ── tests (host: `zig build test`) ───────────────────────────────────────────
const std = @import("std");
