//! GP100-format GMMU page tables for the host channel VA space (AD102).
//!
//! Grounded in nouveau vmmgp100.c/vmmtu102.c.
//! The CPU owns every level; tables live in VRAM and are written through the
//! PRAMIN window. GSP-RM only learns the PD chain via the vaspace
//! COPY_SERVER_RESERVED_PDES ctrl (fifo.zig issues it).
//!
//! MVP VA map: everything lives in the first 512 MiB of VA
//! (one L2 entry); the mandatory server split at 4 GiB shares root+L3 with it.
//! Bump-style: mappings are created once before the channel runs and never
//! unmapped; overlap is a loud error.

const log = @import("../rm/log.zig").gpu;
const vram = @import("vram.zig");
const mmio = @import("../rm/mmio.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");

pub const Error = error{ GmmuVaOutOfRange, GmmuAlreadyMapped, GmmuUnaligned, GmmuTlbFlushTimeout } || error{VramOutOfMemory};

/// Fixed MVP virtual addresses (all within the first 512 MiB → L2 entry 0..).
pub const VA_SEM: u64 = 0x0100_0000; // 1 page: CE semaphore/fence word
pub const VA_RING: u64 = 0x0180_0000; // 1 page: GPFIFO ring
pub const VA_PUSH: u64 = 0x01c0_0000; // 1 page: pushbuffer
pub const VA_SYSMEM: u64 = 0x0200_0000; // 96 MiB: sysmem staging window
pub const VA_VRAM: u64 = 0x0800_0000; // 288 MiB: VRAM scanout window — 9 slots
// of 32 MiB HEAD_STRIDE (present.zig): heads/ring/overlay up to slot 8 (the
// triple-buffer ring's third buffer at +0x1000_0000), so it ends 0x1A00_0000.
// This was long mis-documented as 256 MiB; VA_GL_MESH collided with slot 8.
// Window-mirror windows (GPU compositing). Each desktop window
// gets a VRAM pixel mirror mapped in VA_WMIRROR and its sysmem surface mapped in
// VA_WSYSMEM (the CE-upload source). Both sit clear of the scanout window and
// well below the 4 GiB MVP ceiling (L2 slots 0..7 = 8 × 512 MiB). 1 GiB each
// holds far more than the desktop's window count (a full-screen ultrawide window
// is ~20 MiB), and a bump allocator (present.zig) hands out slots within them.
pub const VA_WMIRROR: u64 = 0x2000_0000; // 1 GiB: VRAM window pixel mirrors
pub const VA_WSYSMEM: u64 = 0x6000_0000; // 1 GiB: window sysmem surfaces (upload src)
// GR (3D) channel fixed VAs.
// Ring/push/sem sit in the same low gap as the CE channel's; the GR context
// buffers get their own window above the window-mirror regions (ATTRIBUTE_CB's
// VA alignment is order_base_2(size) — up to 128 MiB — so the window is sized
// 512 MiB to absorb alignment holes; gl/engine/gr.zig bump-allocates within it).
pub const VA_GR_SEM: u64 = 0x0120_0000; // 1 page: GR fence word
pub const VA_GR_RING: u64 = 0x0128_0000; // 1 page: GR GPFIFO ring
pub const VA_GR_PUSH: u64 = 0x0130_0000; // 1 page: GR pushbuffer
pub const VA_GR_ZERO: u64 = 0x0138_0000; // 1 page, all-zero: vertex-stream substitute
pub const VA_GR_SHADERS: u64 = 0x0140_0000; // shader program images (SPH+code, 0x80-aligned)
// The GL context pool (GL windows, GPU-resident;
// src/drivers/gl/opengl.zig): context slot i owns the 32 MiB VA window
// VA_GL_CTX0 + i*VA_GL_CTX_STRIDE with the fixed offsets below. Each slot
// holds a PANEL-SIZED (3440x1440, iopengl.MAX_W/MAX_H) block-linear 1x color
// RT (~21 MiB; depth lives in the shared MSAA scratch), so a window's
// viewport always equals its content size. 8 slots span
// 0xC000_0000..0xD000_0000 (ends at the screenshot stage); the MSAA scratch
// pair sits above it at 0xD800_0000/0xE800_0000, under the 4 GiB client-VA
// ceiling (the GSP server split) and clear of WMIRROR/WSYSMEM
// (0x2000_0000/0x6000_0000, 1 GiB each) and VA_GRCTX (ends 0xC000_0000).
pub const VA_GL_CTX0: u64 = 0xc000_0000;
pub const VA_GL_CTX_STRIDE: u64 = 0x0200_0000; // 32 MiB per context slot
pub const GL_CTX_RT_OFF: u64 = 0x0000_0000; // block-linear 1x color RT (panel-sized)
pub const GL_CTX_CB_OFF: u64 = 0x0180_0000; // cb0 page (desc cbufs at +0x800/+0x900)
pub const GL_CTX_GRPUSH_OFF: u64 = 0x0184_0000; // private GR pushbuffer page (sysmem)
pub const GL_CTX_GRSEM_OFF: u64 = 0x0188_0000; // private GR fence word (sysmem)
pub const GL_CTX_CEPUSH_OFF: u64 = 0x018c_0000; // private CE pushbuffer page (sysmem)
pub const GL_CTX_CESEM_OFF: u64 = 0x018e_0000; // private CE fence word (sysmem)
// The SHARED 8x-MSAA scratch pair (8x MSAA, shared scratch):
// panel-sized at the 4x2 SAMPLE extent (13760x2880 samples, ~160 MiB each).
// Serial use only — the GR channel executes each frame's push atomically.
pub const VA_GL_MSAA_RT: u64 = 0xd800_0000; // 8x MSAA block-linear color
pub const VA_GL_MSAA_ZT: u64 = 0xe800_0000; // 8x MSAA block-linear Z32F
// Shared by every GL context. NOT below 0xD000_0000: the context slots
// span 0xC000_0000..0xD000_0000 (8 × 32 MiB) — the previous 0xCC00_0000
// placement sat inside slot 6/7's windows and collided once 7+ windows
// mapped. Now above the screenshot stage (0xD000_0000 + 2 panel planes
// ≈ 38 MiB) and below the MSAA scratch (0xD800_0000):
pub const VA_GL_TEX: u64 = 0xd400_0000; // built-in white default texture
pub const VA_GL_TICPOOL: u64 = 0xd440_0000; // TIC pool page (TSC at +0x400)
// Mesh VB/IB bump window: the 96 MiB hole between the scanout window's REAL
// end and the window mirrors (0x2000_0000). NOTE the scanout window is NOT the
// "256 MiB" its declaration long claimed: present.zig carves it in 32 MiB
// HEAD_STRIDE slots and the triple-buffer ring's third buffer sits at slot 8
// (VA_VRAM + 0x1000_0000 = 0x1800_0000), so the window truly extends to
// 0x1A00_0000 (9 slots) — placing the mesh window at 0x1800_0000 collided
// ("va already mapped", GL device dead for a whole boot). Sized for a full
// sweep batch resident at once (~61 MB; ABeautifulGame alone is ~20 MB — the
// previous 16 MiB window failed every heavy scene with OpenGlOutOfResources).
pub const VA_GL_MESH: u64 = 0x1a00_0000;
pub const VA_GL_MESH_SIZE: u64 = 0x0600_0000; // 96 MiB, ends at VA_WMIRROR
// Model textures (textureCreate): bump window ABOVE the MSAA scratch pair
// (which ends ≈0xF200_0000), under the 4 GiB client-VA ceiling.
pub const VA_GL_TEXWIN: u64 = 0xf400_0000; // texture bump window (128 MiB)
pub const VA_GL_TEXWIN_SIZE: u64 = 0x0800_0000;
pub const VA_GRCTX: u64 = 0xa000_0000; // 512 MiB: GR context buffers
pub const GRCTX_SIZE: u64 = 0x2000_0000;
pub const WREGION_SIZE: u64 = 0x4000_0000; // 1 GiB — size of each window VA region
// The two windows are adjacent (WMIRROR ends exactly at WSYSMEM); a bump
// allocator (present.zig) MUST stop at region_base+WREGION_SIZE or it walks into
// the neighbour and silently aliases (mapVram/mapSysmem still succeed below the
// 4 GiB MVP ceiling). present.findOrMapMirror enforces the ceiling.

const PAGE: u64 = 0x1000;

// The GP100 PTE/PDE bit encoding + VA-index extraction live in the pure, host-
// tested gmmu_fmt (single source of truth).
const fmt = @import("../rm/gmmu_fmt.zig");
const PDE_APER_VRAM = fmt.PDE_APER_VRAM;
const PTE_VALID = fmt.PTE_VALID;
const PTE_APER_HOST = fmt.PTE_APER_HOST;
const PTE_VOL = fmt.PTE_VOL;

/// The page-table forest: root (2-bit), L3 (9-bit), L2 (9-bit) are allocated at
/// init and cover VA [0, 2^47). PD0 (8-bit, 16-byte entries) and SPT (9-bit)
/// instances are created on demand under L2 as mappings arrive.
pub const Gmmu = struct {
    regs: mmio.Mapping,
    valloc: *vram.Allocator,
    root: u64, // 4 KiB VRAM (4 × 8B entries used)
    l3: u64, // 4 KiB VRAM (512 × 8B)
    l2: u64, // 4 KiB VRAM (512 × 8B)
    pd0: [8]u64, // PD0 instance per L2 slot 0..7 (first 4 GiB is ample); 0 = none

    /// Allocate + zero the three upper levels and wire root[0]→L3, L3[0]→L2.
    pub fn init(regs: mmio.Mapping, valloc: *vram.Allocator) Error!Gmmu {
        const g = Gmmu{
            .regs = regs,
            .valloc = valloc,
            .root = try allocTable(regs, valloc),
            .l3 = try allocTable(regs, valloc),
            .l2 = try allocTable(regs, valloc),
            .pd0 = [_]u64{0} ** 8,
        };
        writePde8(regs, g.root, 0, g.l3);
        writePde8(regs, g.l3, 0, g.l2);
        log("gpu.gmmu: root@0x{x} l3@0x{x} l2@0x{x}\n", .{ g.root, g.l3, g.l2 });
        return g;
    }

    /// Map `len` bytes of coherent SYSMEM (contiguous physical) at `va`.
    pub fn mapSysmem(self: *Gmmu, va: u64, phys: u64, len: u64) Error!void {
        try self.map(va, phys, len, PTE_VALID | PTE_APER_HOST | PTE_VOL);
        try self.invalidateTlb();
    }

    /// Re-point `len` bytes of coherent SYSMEM at `va` to a NEW `phys`, OVERWRITING
    /// PTEs that are still valid from a prior mapping: when a mirror slot is
    /// reclaimed on window close, its sysmem VA is remapped to the next window's
    /// surface phys — the old PTE is still valid, so plain `map` would reject it
    /// with GmmuAlreadyMapped. Every page in the range MUST already be validly mapped
    /// (this is a REPLACE, not a fresh map) — an unmapped page is a caller bug (the
    /// slot accounting is wrong), so it fails loudly rather than falling back to a
    /// fresh map.
    pub fn remapSysmem(self: *Gmmu, va: u64, phys: u64, len: u64) Error!void {
        if ((va | phys | len) & (PAGE - 1) != 0) {
            log("gpu.gmmu: unaligned remap va=0x{x} phys=0x{x} len=0x{x}\n", .{ va, phys, len });
            return error.GmmuUnaligned;
        }
        var off: u64 = 0;
        while (off < len) : (off += PAGE) {
            try self.remapPage(va + off, phys + off, PTE_VALID | PTE_APER_HOST | PTE_VOL);
        }
        try self.invalidateTlb();
    }

    /// Map `len` bytes of VRAM (contiguous physical) at `va`.
    pub fn mapVram(self: *Gmmu, va: u64, phys: u64, len: u64) Error!void {
        try self.map(va, phys, len, PTE_VALID); // aperture VRAM = 0
        try self.invalidateTlb();
    }

    /// Map VRAM as BLOCK-LINEAR: PTE kind GENERIC_MEMORY (0x6) in bits 63:56,
    /// matching NVK's mapping of every tiled surface on Turing+
    /// (NIL image.rs:744-823 → vmmgp100.c:495).
    /// Used for depth buffers and sampled textures — never for pitch surfaces.
    pub fn mapVramBlockLinear(self: *Gmmu, va: u64, phys: u64, len: u64) Error!void {
        try self.map(va, phys, len, PTE_VALID | (0x6 << 56));
        try self.invalidateTlb();
    }

    /// GPU MMU TLB invalidate (gf100_vmm_invalidate + gp100_vmm_invalidate_pdb,
    /// vmmgf100.c:188-224): mappings created while the channel is live are not
    /// observed until the TLB drops its cached (negative) translations —
    /// without this the first CE copy from a freshly mapped region hangs.
    /// TSC-deadline bounded (100 ms — matches the
    /// project's poll-timeout convention; a fixed spin count is wall-clock-
    /// fragile) and LOUD on timeout: silently proceeding past a stuck flush
    /// leaves stale TLB entries live, which is exactly the CE-hang class the
    /// flush exists to prevent.
    fn invalidateTlb(self: *Gmmu) Error!void {
        const deadline = tsc.rdtsc() + tsc.msTicks(100);
        // Wait for a free flush slot (0x100c80 bits 23:16).
        while ((self.regs.read32(0x100c80) & 0x00ff0000) == 0) {
            if (tsc.rdtsc() >= deadline) {
                log("gpu.gmmu: TLB flush slot wait timed out (0x100c80=0x{x})\n", .{self.regs.read32(0x100c80)});
                return error.GmmuTlbFlushTimeout;
            }
            asm volatile ("pause");
        }
        // PDB address (VRAM aperture = 0) + trigger PAGE_ALL.
        const addr: u64 = (self.root >> 12) << 4;
        self.regs.write32(0x100cb8, @truncate(addr));
        self.regs.write32(0x100cec, @truncate(addr >> 32));
        self.regs.write32(0x100cbc, 0x80000000 | 0x00000001);
        // Wait for the flush to be queued (bit 15).
        const deadline2 = tsc.rdtsc() + tsc.msTicks(100);
        while ((self.regs.read32(0x100c80) & 0x00008000) == 0) {
            if (tsc.rdtsc() >= deadline2) {
                log("gpu.gmmu: TLB flush queue wait timed out (0x100c80=0x{x})\n", .{self.regs.read32(0x100c80)});
                return error.GmmuTlbFlushTimeout;
            }
            asm volatile ("pause");
        }
    }

    /// 4 KiB-page mapper. `type_bits` = PTE control bits (VALID/aperture/VOL).
    fn map(self: *Gmmu, va: u64, phys: u64, len: u64, type_bits: u64) Error!void {
        if ((va | phys | len) & (PAGE - 1) != 0) {
            log("gpu.gmmu: unaligned map va=0x{x} phys=0x{x} len=0x{x}\n", .{ va, phys, len });
            return error.GmmuUnaligned;
        }
        var off: u64 = 0;
        while (off < len) : (off += PAGE) {
            try self.mapPage(va + off, phys + off, type_bits);
        }
    }

    fn mapPage(self: *Gmmu, va: u64, phys: u64, type_bits: u64) Error!void {
        // MVP covers VA below 4 GiB (L3 entry 0, L2 entries 0..7 → 8 × 512 MiB).
        if (fmt.vaOutOfRange(va, self.pd0.len)) {
            log("gpu.gmmu: va 0x{x} outside the MVP window\n", .{va});
            return error.GmmuVaOutOfRange;
        }
        const idx = fmt.indices(va);
        // PD0 instance under L2[l2i].
        if (self.pd0[idx.l2] == 0) {
            self.pd0[idx.l2] = try allocTable(self.regs, self.valloc);
            writePde8(self.regs, self.l2, idx.l2, self.pd0[idx.l2]);
        }
        const pd0 = self.pd0[idx.l2];
        // SPT instance under PD0[pd0i]. PD0 entries are 16 bytes; the SMALL-page
        // (4 KiB) pointer is the second qword (+8). Rather than caching every SPT
        // (l2i*256+pd0i instances), read the PDE back from VRAM to find one.
        const pde_lo = vram.read32(self.regs, pd0 + idx.pd0 * 16 + 8);
        const pde_hi = vram.read32(self.regs, pd0 + idx.pd0 * 16 + 12);
        var spt_phys: u64 = fmt.decodePde(pde_lo, pde_hi);
        if (spt_phys == 0) {
            spt_phys = try allocTable(self.regs, self.valloc);
            const data = fmt.encodePde(spt_phys);
            vram.write32(self.regs, pd0 + idx.pd0 * 16 + 8, @truncate(data));
            vram.write32(self.regs, pd0 + idx.pd0 * 16 + 12, @truncate(data >> 32));
        }
        const old = vram.read32(self.regs, spt_phys + idx.spt * 8);
        if (fmt.pteValid(old)) {
            log("gpu.gmmu: va 0x{x} already mapped\n", .{va});
            return error.GmmuAlreadyMapped;
        }
        const pte = fmt.encodePte(phys, type_bits);
        vram.write32(self.regs, spt_phys + idx.spt * 8, @truncate(pte));
        vram.write32(self.regs, spt_phys + idx.spt * 8 + 4, @truncate(pte >> 32));
    }

    /// Overwrite an EXISTING valid PTE at `va` with a new `phys`/`type_bits` — the
    /// REPLACE half of remapSysmem. Requires the PD0/SPT chain and the PTE to
    /// already exist and be valid; anything else is a caller bug (fails loudly,
    /// does not silently fall back to a fresh map).
    fn remapPage(self: *Gmmu, va: u64, phys: u64, type_bits: u64) Error!void {
        if (fmt.vaOutOfRange(va, self.pd0.len)) {
            log("gpu.gmmu: remap va 0x{x} outside the MVP window\n", .{va});
            return error.GmmuVaOutOfRange;
        }
        const idx = fmt.indices(va);
        const pd0 = self.pd0[idx.l2];
        if (pd0 == 0) {
            log("gpu.gmmu: remap va 0x{x} has no PD0 — never mapped\n", .{va});
            return error.GmmuVaOutOfRange;
        }
        const pde_lo = vram.read32(self.regs, pd0 + idx.pd0 * 16 + 8);
        const pde_hi = vram.read32(self.regs, pd0 + idx.pd0 * 16 + 12);
        const spt_phys: u64 = fmt.decodePde(pde_lo, pde_hi);
        if (spt_phys == 0) {
            log("gpu.gmmu: remap va 0x{x} has no SPT — never mapped\n", .{va});
            return error.GmmuVaOutOfRange;
        }
        const old = vram.read32(self.regs, spt_phys + idx.spt * 8);
        if (!fmt.pteValid(old)) {
            log("gpu.gmmu: remap va 0x{x} PTE not valid — never mapped\n", .{va});
            return error.GmmuVaOutOfRange;
        }
        const pte = fmt.encodePte(phys, type_bits);
        vram.write32(self.regs, spt_phys + idx.spt * 8, @truncate(pte));
        vram.write32(self.regs, spt_phys + idx.spt * 8 + 4, @truncate(pte >> 32));
    }
};

/// Allocate one zeroed 4 KiB page-table page in VRAM.
fn allocTable(regs: mmio.Mapping, valloc: *vram.Allocator) Error!u64 {
    const t = try valloc.alloc(PAGE, PAGE);
    vram.fill(regs, t, PAGE, 0);
    return t;
}

/// Write an 8-byte PDE (root/L3/L2 levels): child table in VRAM.
fn writePde8(regs: mmio.Mapping, table: u64, index: u64, child_phys: u64) void {
    const data = fmt.encodePde(child_phys);
    vram.write32(regs, table + index * 8, @truncate(data));
    vram.write32(regs, table + index * 8 + 4, @truncate(data >> 32));
}
