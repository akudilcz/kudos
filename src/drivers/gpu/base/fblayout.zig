//! GPU framebuffer (VRAM) layout for GSP boot — the kudos mirror of nouveau's
//! `tu102_gsp_oneinit` FB/WPR2 carve + `tu102_gsp_wpr_heap_size`
//! (gsp/tu102.c, rm/r570/rm.c). All offsets are VRAM-relative, carved top-down
//! from the GPU's framebuffer size.
//!
//! The signed Booter validates this layout, so the constants are byte-exact from
//! the pinned 570.144 nouveau sources named above (ga102 = libos3 wpr config).

const algn = @import("algn"); // alignment: ONE home
const mmio = @import("mmio.zig");
const gspfw = @import("gspfw.zig");
const calc = @import("calc.zig");
const log = @import("log.zig").gpu;
const alignUp = algn.up;
const alignDown = algn.down;

/// FB vidmem-size register (ga102_fb_vidmem_size: `rd32(0x1183a4) << 20`). BAR0
/// offset; value is in MiB.
const FB_VIDMEM_SIZE_REG: u64 = 0x1183a4;

/// WPR2 lo/hi registers (NV_PFB_PRI_MMU_WPR2_ADDR_LO/HI; tu102 reads them in
/// `nvkm_gsp_fwsec_frts`, fwsec.c:369-370). FRTS programs them: a nonzero hi means
/// a WPR2 is locked. The raw values are the WPR2 base/limit the hardware latched —
/// compared directly against our computed fblayout to validate the FRTS region.
pub const WPR2_LO_REG: u64 = 0x1fa824;
pub const WPR2_HI_REG: u64 = 0x1fa828;

// libos3 (ga102/570.144) WPR heap parameters — rm/r570/rm.c + r570/nvrm/gsp.h.
const OS_CARVEOUT_SIZE: u64 = 22 << 20; // OS_SIZE_LIBOS3_BAREMETAL
const BASE_RM_SIZE: u64 = 8 << 20; // BASE_RM_SIZE_TU10X (Turing..Ada)
const SIZE_PER_GB_FB: u64 = 96 << 10; // per-GB FB, all arches
const CLIENT_ALLOC_SIZE: u64 = (48 << 10) * 2048; // 2048 channels
// heap_size_min = 88 MiB. The r570 header writes MIN as (88 + 12 + 70), but the
// +12/+70 are BULLSEYE_ROOT_HEAP_ALLOC_* code-coverage-build deltas; a normal
// build uses 88. Confirmed against the instrumented nouveau reference: heap =
// max(formula=129, min) resolved to 129 MiB, which requires min<=129 (88, not
// 170). Using 170 oversized our heap and shifted the whole lower WPR2 carve.
const HEAP_SIZE_MIN: u64 = 88 << 20;
const FRTS_SIZE: u64 = 0x100000; // non-GA100 FRTS region

/// A VRAM sub-region (addr+size, both byte offsets into the framebuffer).
pub const Region = struct { addr: u64, size: u64 };

/// The computed FB layout. Mirrors nouveau `gsp->fb.*` fields the WPR meta reads.
pub const FbLayout = struct {
    fb_size: u64,
    bios: Region, // vga workspace at top of FB
    frts: Region,
    boot: Region, // bootloader image in WPR2
    elf: Region, // GSP-RM image in WPR2
    heap: Region, // GSP-RM heap in WPR2
    wpr2: Region, // the whole WPR2 (meta..frts end)
    nonwpr_heap: Region, // non-WPR heap just below WPR2
    /// VRAM below everything this layout reserves for the RM: `[0, nonwpr_heap.addr)`.
    /// The RM's heap lives inside WPR2 and its scratch is `nonwpr_heap`; everything
    /// below is the host's to carve (driver-owned scanout/instmem surfaces). kudos owns
    /// a single consumer, so a bump allocation from VRAM base 0 stays under that
    /// boundary — simpler here than parsing the RM's fbRegion[] heap map, and this
    /// field is the one place the boundary is defined.
    free: Region,
};

/// Read the GPU's VRAM size (bytes) from BAR0.
pub fn vidmemSize(regs: mmio.Mapping) u64 {
    return @as(u64, regs.read32(FB_VIDMEM_SIZE_REG)) << 20;
}

/// Heap size for the GSP-RM, per tu102_gsp_wpr_heap_size (libos3 params).
fn heapSize(fb_size: u64) u64 {
    const fb_gb = (fb_size + (1 << 30) - 1) >> 30;
    const hs = OS_CARVEOUT_SIZE + BASE_RM_SIZE +
        alignUp(SIZE_PER_GB_FB * fb_gb, 1 << 20) +
        alignUp(CLIENT_ALLOC_SIZE, 1 << 20);
    return @max(hs, HEAP_SIZE_MIN);
}

/// Compute the full FB/WPR2 layout (nouveau tu102_gsp_oneinit). `elf_size` is the
/// GSP-RM image size; `boot_size` the bootloader image size.
pub fn compute(regs: mmio.Mapping, elf_size: u64, boot_size: u64) FbLayout {
    const fb_size = vidmemSize(regs);

    // VGA/BIOS workspace: top 1 MiB of FB (simplified; nouveau also consults
    // 0x625f04 when a display engine is present — not on the M9 headless path).
    const vga_addr = fb_size - 0x100000;
    const bios = Region{ .addr = vga_addr, .size = fb_size - vga_addr };

    // Carve WPR2 downward from bios.addr.
    const frts_addr = alignDown(bios.addr, 0x20000) - FRTS_SIZE;
    const frts = Region{ .addr = frts_addr, .size = FRTS_SIZE };

    const boot_addr = alignDown(frts.addr - boot_size, 0x1000);
    const boot = Region{ .addr = boot_addr, .size = boot_size };

    const elf_addr = alignDown(boot.addr - elf_size, 0x10000);
    const elf = Region{ .addr = elf_addr, .size = elf_size };

    const heap_addr = alignDown(elf.addr - heapSize(fb_size), 0x100000);
    const heap_sz = alignDown(elf.addr - heap_addr, 0x100000);
    const heap = Region{ .addr = heap_addr, .size = heap_sz };

    const wpr2_addr = alignDown(heap.addr - @sizeOf(gspfw.GspFwWprMeta), 0x100000);
    const wpr2 = Region{ .addr = wpr2_addr, .size = frts.addr + frts.size - wpr2_addr };

    const nonwpr = Region{ .addr = wpr2_addr - 0x100000, .size = 0x100000 };

    // Free VRAM = everything below the non-WPR heap. (nonwpr.addr is the lowest
    // RM-reserved byte; [0, nonwpr.addr) is the host's.)
    const free = Region{ .addr = 0, .size = nonwpr.addr };

    log("gpu.fblayout: fb={} MiB wpr2@0x{x} heap={} MiB elf@0x{x} free={} MiB\n", .{ fb_size >> 20, wpr2.addr, heap.size >> 20, elf.addr, free.size >> 20 });
    return .{
        .fb_size = fb_size,
        .bios = bios,
        .frts = frts,
        .boot = boot,
        .elf = elf,
        .heap = heap,
        .wpr2 = wpr2,
        .nonwpr_heap = nonwpr,
        .free = free,
    };
}
