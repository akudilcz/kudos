//! radix3: the GSP's three-level page table mapping the firmware image into the
//! GSP's address space (nouveau
//! `nvkm_gsp_radix3_sg`, gsp/rm/r535/gsp.c).
//!
//! Each level is 4 KiB pages of 64-bit entries:
//!   level 0 — one page, one entry → bus addr of the level-1 page
//!   level 1 — one page, ≤512 entries → bus addr of each level-2 page
//!   level 2 — ≤512 pages, each entry → bus addr of a firmware image page
//! Max image = 512×512×4 KiB = 1 GiB. kudos is identity-mapped, so a "bus
//! address" here is the physical frame address (no IOMMU translation in the
//! guest path; matches how mmio/pmm already treat addresses).
//!
//! Isolation invariant: builds tables from PMM frames via shim.allocPagesPhys
//! (the os_alloc_pages_node equivalent); adds nothing to other modules.

const shim = @import("../rm/shim.zig");
const gspfw = @import("../rm/gspfw.zig");
const log = @import("../rm/log.zig").gpu;

const PAGE = gspfw.GSP_PAGE_SIZE;
const PTES_PER_PAGE = PAGE / 8; // 512

pub const Error = error{ Radix3Alloc, Radix3ImageTooLarge };

/// The built table: physical address of the level-0 page (what goes into
/// GspFwWprMeta.sysmemAddrOfRadix3Elf) plus the level bases (for teardown later).
pub const Radix3 = struct {
    lvl0: u64,
    lvl1: u64,
    lvl2: u64,
    lvl2_pages: u64,
};

/// Pointer to the `index`-th 64-bit page-table entry in the 4 KiB page at `phys`.
fn pte(phys: u64, index: u64) *volatile u64 {
    const p: [*]volatile u64 = @ptrFromInt(phys);
    return &p[index];
}

/// Build a radix3 table mapping `[image_phys, image_phys+size)` (the firmware
/// image, which must be physically contiguous — kudos stages it as one boot
/// module, so it is). Returns the table to point WPR meta at.
pub fn build(dma: *shim.DmaTracker, image_phys: u64, size: u64) Error!Radix3 {
    const img_pages = (size + PAGE - 1) / PAGE;
    if (img_pages > PTES_PER_PAGE * PTES_PER_PAGE) return error.Radix3ImageTooLarge;

    // level 2 needs ceil(img_pages / 512) pages of PTEs.
    const lvl2_pages = (img_pages + PTES_PER_PAGE - 1) / PTES_PER_PAGE;

    // The radix3 tables are read by the booter for the GSP's entire runtime, so
    // they are persistent — track them for teardown via the shared DmaTracker.
    const lvl0 = dma.alloc(1) orelse return error.Radix3Alloc;
    const lvl1 = dma.alloc(1) orelse return error.Radix3Alloc;
    const lvl2 = dma.alloc(@intCast(lvl2_pages)) orelse return error.Radix3Alloc;

    // level 0 → level 1
    pte(lvl0, 0).* = lvl1;

    // level 1 → each level-2 page
    var i: u64 = 0;
    while (i < lvl2_pages) : (i += 1) pte(lvl1, i).* = lvl2 + i * PAGE;

    // level 2 → each firmware image page (contiguous)
    i = 0;
    while (i < img_pages) : (i += 1) pte(lvl2, i).* = image_phys + i * PAGE;

    log("gpu.radix3: img={} pages, lvl2={} pages, lvl0=0x{x}\n", .{ img_pages, lvl2_pages, lvl0 });
    return .{ .lvl0 = lvl0, .lvl1 = lvl1, .lvl2 = lvl2, .lvl2_pages = lvl2_pages };
}
