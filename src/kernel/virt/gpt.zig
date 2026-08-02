//! Guest boot page tables and GDT, written into low guest RAM before entry. Pure:
//! it fills a slice that aliases guest-physical memory (base = GPA 0) with the
//! identity map the guest kernel runs on until it builds its own, plus a flat
//! 64-bit GDT. Host-tested (test/kernel/virt/gpt_test.zig) by walking the built tables.
//!
//! These are the GUEST's own x86-64 paging structures (what guest CR3 points at) —
//! distinct from EPT (virt/ept.zig), which is the second-level guest-phys →
//! host-phys map. The 64-bit boot protocol requires the guest to enter already in
//! long mode with paging on, so the loader must hand it a valid identity map.

const std = @import("std");
pub const layout = @import("layout.zig");

const PAGE_SIZE = layout.PAGE_SIZE; // one page-table page
pub const PAGE_2M = layout.PAGE_2M; // the huge-page a PDE maps
const GIB = layout.GIB; // one page directory covers a GiB
const ENTRIES: usize = 512;
const ENTRY_BYTES: usize = 8;

// x86-64 paging-entry bits (Intel SDM Vol 3A §4.5).
const PTE_PRESENT: u64 = 1 << 0;
const PTE_WRITABLE: u64 = 1 << 1;
const PTE_HUGE: u64 = 1 << 7; // PDE: maps a 2 MiB page

// Flat long-mode GDT descriptors (Intel SDM Vol 3A §3.4.5). A 64-bit code segment
// sets L; data is a standard writable segment. Bases 0, limits ignored in 64-bit.
const GDT_NULL: u64 = 0;
const GDT_CODE64: u64 = 0x00AF_9A00_0000_FFFF;
const GDT_DATA: u64 = 0x00CF_9200_0000_FFFF;

/// Selectors into the built GDT.
pub const SEL_CODE: u16 = 0x08;
pub const SEL_DATA: u16 = 0x10;
/// GDTR limit for the three-descriptor table (3 × 8 − 1).
pub const GDT_LIMIT: u32 = 3 * 8 - 1;

/// Write the flat GDT at layout.GDT_GPA into `ram` (indexed by GPA).
pub fn buildGdt(ram: []u8) void {
    wr64(ram, layout.GDT_GPA + 0, GDT_NULL);
    wr64(ram, layout.GDT_GPA + 8, GDT_CODE64);
    wr64(ram, layout.GDT_GPA + 16, GDT_DATA);
}

/// Build an identity map covering [0, map_bytes) with 2 MiB pages: PML4 at
/// PT_PML4_GPA, PDPT at PT_PDPT_GPA, and one page directory per GiB starting at
/// PT_PD_BASE_GPA. `ram` is indexed by guest-physical address.
pub fn buildIdentity(ram: []u8, map_bytes: u64) void {
    // Zero the three-plus table pages we touch (PML4, PDPT, PDs).
    const num_pd: usize = @intCast((map_bytes + GIB - 1) / GIB);
    zero(ram, layout.PT_PML4_GPA, ENTRIES * ENTRY_BYTES);
    zero(ram, layout.PT_PDPT_GPA, ENTRIES * ENTRY_BYTES);
    var i: usize = 0;
    while (i < num_pd) : (i += 1) zero(ram, layout.PT_PD_BASE_GPA + @as(u64, i) * PAGE_SIZE, ENTRIES * ENTRY_BYTES);

    // PML4[0] → PDPT.
    wr64(ram, layout.PT_PML4_GPA, layout.PT_PDPT_GPA | PTE_PRESENT | PTE_WRITABLE);

    // PDPT[i] → PD[i], for each GiB covered.
    i = 0;
    while (i < num_pd) : (i += 1) {
        const pd_gpa = layout.PT_PD_BASE_GPA + @as(u64, i) * PAGE_SIZE;
        wr64(ram, layout.PT_PDPT_GPA + @as(u64, i) * ENTRY_BYTES, pd_gpa | PTE_PRESENT | PTE_WRITABLE);
    }

    // PD entries: one 2 MiB huge page per slot, identity-mapped, up to map_bytes.
    var gpa: u64 = 0;
    while (gpa < map_bytes) : (gpa += PAGE_2M) {
        const pd_index: usize = @intCast(gpa >> 30);
        const slot: usize = @intCast((gpa >> 21) & 0x1FF);
        const pd_gpa = layout.PT_PD_BASE_GPA + @as(u64, pd_index) * 4096;
        wr64(ram, pd_gpa + @as(u64, slot) * ENTRY_BYTES, gpa | PTE_PRESENT | PTE_WRITABLE | PTE_HUGE);
    }
}

fn zero(ram: []u8, gpa: u64, len: usize) void {
    @memset(ram[@intCast(gpa)..][0..len], 0);
}
fn wr64(ram: []u8, gpa: u64, v: u64) void {
    std.mem.writeInt(u64, ram[@intCast(gpa)..][0..8], v, .little);
}
