//! Falcon / RISC-V engine driver for the GSP (and SEC2 booter) — the kudos
//! mirror of nouveau's `nvkm/falcon/` + `subdev/gsp/ga102.c` falcon func for the
//! AD102/ga10x lineage.
//!
//! A "falcon" is NVIDIA's embedded microcontroller; the GSP one runs a RISC-V
//! core that executes GSP-RM. Bring-up touches its register block in BAR0:
//! reset → wait for memory scrub → load signed ucode → boot → poll RISC-V active.
//!
//! Register offsets are the Falcon block's own, cross-checked against nouveau
//! (ga102 falcon func):
//! base `0x110000` in BAR0; `addr2 = 0x1000` for the RISC-V register sub-block.
//! Isolation invariant: this is a self-contained mechanism under src/drivers/gpu/; it
//! reads the BAR0 mapping (mmio.Mapping) but adds nothing to other modules.

const mmio = @import("../rm/mmio.zig");
const log = @import("../rm/log.zig").gpu;
const shim = @import("../rm/shim.zig");
const falconfw = @import("falconfw.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const spinwait = @import("../../../kernel/debug/spinwait.zig");

/// Device-level fuse-version registers for the signature selector
/// (ga100_flcn_fw_signature), indexed by engine_id and ucode_id. BAR0 offsets.
const FUSE_VER_ENG1: u64 = 0x824140; // engine_id & 1
const FUSE_VER_ENG4: u64 = 0x824100; // engine_id & 4
const FUSE_VER_ENG400: u64 = 0x8241c0; // engine_id & 0x400

/// find-last-set: 1-based index of the highest set bit (0 if `v` is 0). Matches
/// the C `fls()` nouveau uses to derive the fuse signature version.
fn fls(v: u32) u32 {
    return if (v == 0) 0 else 32 - @clz(v); // find-last-set, 1-based
}

/// GSP falcon register base within BAR0 (nouveau: `nvkm_wr32(device, 0x110004,…)`
/// drives falcon reg 0x004 ⇒ base 0x110000).
pub const GSP_FALCON_BASE: u64 = 0x110000;

/// SEC2 falcon register base (nouveau sec2/tu102.c `addr = 0x840000`). The signed
/// "booter" ucode runs on SEC2, not the GSP falcon: it authenticates the GSP
/// image, sets up WPR, then releases the GSP RISC-V core. So the booter load
/// targets THIS base, while r535_gsp_init's RISC-V boot targets the GSP base.
pub const SEC2_FALCON_BASE: u64 = 0x840000;

/// Offset of the RISC-V register sub-block from the falcon base
/// (nouveau `ga102_gsp_flcn.addr2`).
pub const ADDR2: u64 = 0x1000;

/// Falcon registers used during bring-up (offsets from the falcon base).
/// Cross-checked against nouveau's ga102 falcon + gsp code; see resources.
pub const Reg = struct {
    pub const IRQSCLR: u64 = 0x004; // interrupt clear  (wr 0x40 to clear)
    pub const MAILBOX0: u64 = 0x040; // mbox0 — also "scrub done" sentinel (==0x80000000)
    pub const MAILBOX1: u64 = 0x044;
    pub const BOOT_APP_VERSION: u64 = 0x080; // write boot.app_version to start
    pub const HWCFG2: u64 = 0x0f4; // bit12 = mem-scrubbing busy; bit31 = halted (reset_prep)
    pub const CPUCTL: u64 = 0x100; // bit4 = halted, bit6 = alias_en
    pub const BOOTVEC: u64 = 0x104;
    pub const DMACTL: u64 = 0x10c;
    pub const ENGINE: u64 = 0x3c0; // engine reset/enable (gp102_flcn_reset_eng)
    // RISC-V sub-block (add ADDR2):
    pub const RISCV_CPUCTL_ACTIVE: u64 = 0x388; // (addr2+) bit7 = RISC-V active
    pub const RISCV_BCR_CTRL: u64 = 0x668; // (addr2+) core select (BR vs falcon)
};

/// PMC device enable register (ga100_mc_device_enable): mask in the engine's
/// reset bit to power it on.
const REG_PMC_DEVICE: u64 = 0x000600;

/// A falcon instance: a view onto its register block within the BAR0 mapping.
/// `addr2` is the RISC-V register sub-block offset (0x1000 for the GSP falcon,
/// 0 for SEC2 which has no RISC-V core). `is_riscv` selects RISC-V vs classic
/// falcon boot semantics.
pub const Falcon = struct {
    regs: mmio.Mapping,
    base: u64,
    addr2: u64 = ADDR2,
    is_riscv: bool = true,
    /// PMC reset bit (from the TOP table). 0xff = none/not needed.
    pmc_reset_bit: u8 = 0xff,

    /// Read a falcon register at `off` from the falcon base.
    pub fn rd(self: Falcon, off: u64) u32 {
        return self.regs.read32(self.base + off);
    }
    /// Write a falcon register at `off` from the falcon base.
    pub fn wr(self: Falcon, off: u64, val: u32) void {
        self.regs.write32(self.base + off, val);
    }
    /// Read-modify-write: clear the `clr` bits then set the `set` bits at `off`.
    pub fn mask(self: Falcon, off: u64, clr: u32, set: u32) void {
        const v = self.rd(off);
        self.wr(off, (v & ~clr) | set);
    }

    /// RISC-V core is out of reset and running (nouveau ga102_flcn_riscv_active:
    /// `rd32(addr2 + 0x388) & 0x80`). The key success signal for GSP boot.
    pub fn riscvActive(self: Falcon) bool {
        return (self.rd(self.addr2 + Reg.RISCV_CPUCTL_ACTIVE) & 0x00000080) != 0;
    }

    /// Wait until on-chip memory scrubbing completes (nouveau
    /// ga102_flcn_reset_wait_mem_scrubbing: poll `0x0f4 & 0x1000` clear). Returns
    /// false on timeout.
    pub fn waitMemScrubbing(self: Falcon, timeout_ms: u32) bool {
        // TSC-time-bounded poll on the scrub bit (like nv nvkm_msec). Returns the
        // INSTANT the bit clears — the scrub finishes in ~µs, so this is ~µs, not
        // the tens-of-ms a fixed MMIO-read iteration budget cost under vfio (each
        // trapped read is ~1µs, so an "N-iteration" loop ran N µs regardless).
        const deadline = tsc.rdtsc() + tsc.msTicks(timeout_ms);
        while (tsc.rdtsc() < deadline) {
            if ((self.rd(Reg.HWCFG2) & 0x00001000) == 0) return true;
        }
        return false;
    }
};

/// Construct the GSP falcon view over a mapped BAR0.
pub fn gsp(regs: mmio.Mapping) Falcon {
    return .{ .regs = regs, .base = GSP_FALCON_BASE };
}

/// Construct the SEC2 falcon view (where the signed booter runs).
pub fn sec2(regs: mmio.Mapping, pmc_reset_bit: u8) Falcon {
    // AD102's SEC2 (nouveau ga102_sec2_flcn) is configured like the GSP falcon:
    // addr2=0x1000 (it HAS a RISC-V sub-block), with ga102 reset_prep + riscv
    // select + the 0xf4 mem-scrub wait — PLUS reset_pmc (PMC power bit). Treating
    // it as a classic falcon (addr2=0, no select) leaves CPUCTL reading poison.
    return .{ .regs = regs, .base = SEC2_FALCON_BASE, .addr2 = ADDR2, .is_riscv = true, .pmc_reset_bit = pmc_reset_bit };
}

// --- Bring-up steps (scaffold; filled incrementally + hardware-tested) --------

pub const Error = error{
    FalconResetTimeout,
    FalconScrubTimeout,
    FalconSelectTimeout,
    FalconLoadNotImplemented,
    FalconCpuProtected,
    RiscvBootTimeout,
};

/// reset_prep (ga102_flcn_reset_prep): read 0x0f4, then poll bit31 set (≤150µs).
/// TSC-time-bounded poll (nv nvkm_usec): returns the instant the bit sets.
fn resetPrep(f: Falcon) void {
    _ = f.rd(Reg.HWCFG2);
    const deadline = tsc.rdtsc() + tsc.usTicks(150);
    while (tsc.rdtsc() < deadline) {
        if ((f.rd(Reg.HWCFG2) & 0x80000000) != 0) break;
    }
}

/// Wait for mem scrubbing the SEC2 way (gm200_flcn_reset_wait_mem_scrubbing):
/// poll DMACTL (0x10c) bits[2:1] clear. TSC-time-bounded (nv nvkm_msec).
fn waitMemScrubClassic(f: Falcon, timeout_ms: u32) bool {
    const deadline = tsc.rdtsc() + tsc.msTicks(timeout_ms);
    while (tsc.rdtsc() < deadline) {
        if ((f.rd(Reg.DMACTL) & 0x00000006) == 0) return true;
    }
    return false;
}

/// reset_eng (gp102_flcn_reset_eng): (RISC-V only: reset_prep) toggle engine
/// reset bit (0x3c0 bit0 set, 10µs, clear), then wait mem scrubbing. SEC2
/// (classic) has no reset_prep and polls 0x10c&0x6 for scrubbing; the GSP falcon
/// polls 0xf4&0x1000 (ga102_flcn_reset_prep + reset_wait_mem_scrubbing).
fn resetEng(f: Falcon) Error!void {
    if (f.is_riscv) resetPrep(f);
    f.mask(Reg.ENGINE, 0x00000001, 0x00000001);
    tsc.udelay(10); // nv udelay(10) — a TSC-exact 10µs, not a spin-count guess
    f.mask(Reg.ENGINE, 0x00000001, 0x00000000);
    const ok = if (f.is_riscv) f.waitMemScrubbing(100) else waitMemScrubClassic(f, 100);
    if (!ok) return error.FalconScrubTimeout;
}

/// select (ga102_flcn_select): if the RISC-V/falcon core-select bit indicates the
/// wrong core, switch to falcon mode and wait for it to take (≤10ms).
/// TSC-time-bounded poll (nv nvkm_msec): returns the instant select takes.
fn select(f: Falcon) Error!void {
    if ((f.rd(f.addr2 + Reg.RISCV_BCR_CTRL) & 0x00000010) != 0) {
        f.wr(f.addr2 + Reg.RISCV_BCR_CTRL, 0);
        const deadline = tsc.rdtsc() + tsc.msTicks(10);
        while (tsc.rdtsc() < deadline) {
            if ((f.rd(f.addr2 + Reg.RISCV_BCR_CTRL) & 0x00000001) != 0) return;
        }
        return error.FalconSelectTimeout;
    }
}

/// PMC device-enable bit set/clear (ga100_mc_device_enable/disable: mask the
/// engine bit in 0x000600, with posting reads).
fn pmcSet(f: Falcon, on: bool) void {
    if (f.pmc_reset_bit == 0xff) return;
    const bit = @as(u32, 1) << @intCast(f.pmc_reset_bit);
    const v = f.regs.read32(REG_PMC_DEVICE);
    f.regs.write32(REG_PMC_DEVICE, if (on) v | bit else v & ~bit);
    _ = f.regs.read32(REG_PMC_DEVICE);
    _ = f.regs.read32(REG_PMC_DEVICE);
}

/// disable() — gm200_flcn_disable: (riscv select) → mask(0x048,0x3,0) → clear
/// interrupts (wr 0x014=0xffffffff) → reset_prep + PMC power-OFF (reset_pmc) →
/// reset_eng. The PMC power-OFF is not optional: SEC2 must be powered down before it is
/// brought back up, or its CPU domain stays inaccessible and every later access reads
/// back as if the engine were absent.
fn disable(f: Falcon) Error!void {
    if (f.is_riscv) try select(f);
    f.mask(0x048, 0x00000003, 0x00000000);
    f.wr(0x014, 0xffffffff);
    if (f.pmc_reset_bit != 0xff) {
        if (f.is_riscv) resetPrep(f);
        pmcSet(f, false); // nvkm_mc_disable: power OFF
    }
    try resetEng(f);
}

/// enable() — gm200_flcn_enable: reset_eng → (riscv select) → PMC power-ON
/// (reset_pmc only) → reset_wait_mem_scrubbing → wr(0x084, rd32(0x0)).
/// NB: only the PMC power-ON is gated by reset_pmc; the scrub-wait and the
/// 0x084 = boot0/chipset write are UNCONDITIONAL in nouveau — they run even for
/// the GSP falcon (pmc_reset_bit==0xff). Skipping them would leave 0x110084
/// (the chipset id the GSP reads) unwritten.
fn enableOnly(f: Falcon) Error!void {
    try resetEng(f);
    if (f.is_riscv) try select(f);
    if (f.pmc_reset_bit != 0xff) pmcSet(f, true); // nvkm_mc_enable: power ON
    const ok = if (f.is_riscv) f.waitMemScrubbing(100) else waitMemScrubClassic(f, 100);
    if (!ok) return error.FalconScrubTimeout;
    f.wr(0x084, f.regs.read32(0x000000));
}

/// Full falcon reset for ucode load (nvkm_falcon_reset = disable then enable).
/// This OFF→ON power-cycle is what makes SEC2's CPU/DMA register block become
/// host-accessible (CPUCTL stops reading 0xbadf poison).
pub fn enable(f: Falcon) Error!void {
    try disable(f);
    try enableOnly(f);
    if (f.pmc_reset_bit != 0xff) {
        log("gpu.falcon: SEC2 post power-cycle cpuctl=0x{x} dmactl=0x{x} hwcfg2=0x{x}\n", .{ f.rd(Reg.CPUCTL), f.rd(Reg.DMACTL), f.rd(Reg.HWCFG2) });
    }
}

/// GSP-specific reset (ga102_gsp_reset): reset_eng then a device-level engine
/// unmask of 0x1668 bits 0x111 (relative to the falcon base on ga10x). Used for
/// the GSP falcon before its RISC-V boot.
pub fn reset(f: Falcon) Error!void {
    try resetEng(f);
    f.mask(0x1668, 0x00000111, 0x00000111);
}

// Falcon DMA-load register offsets (nouveau ga102_flcn_dma): the engine DMAs
// from a host physical address into the falcon's IMEM/DMEM in 256-byte blocks.
const DMA_TRANS: u64 = 0x110; // DMATRFBASE: dma_addr >> 8
const DMA_TRANS_HI: u64 = 0x128; // DMATRFBASE1 (high bits); 0 for <4GB-ish addrs
const DMA_MEM_OFF: u64 = 0x114; // DMATRFMOFFS: destination offset in IMEM/DMEM
const DMA_CMD: u64 = 0x118; // DMATRFCMD: command + done(bit1) status
const DMA_FB_OFF: u64 = 0x11c; // DMATRFFBOFFS: source offset within the image
const DMA_BLOCK: u32 = 256; // per-transfer block (nouveau dmalen)

/// Floor(log2(v)) for a power-of-two `v` — used to encode the DMA block size
/// into DMATRFCMD's size field (nouveau `ilog2(dmalen)`).
fn ilog2(v: u32) u5 {
    return @intCast(31 - @clz(v));
}

/// DMA `len` bytes (256-aligned) from the image at host physical `img_phys` into
/// the falcon's IMEM or DMEM. Faithfully mirrors nvkm_falcon_dma_wr + ga102 dma:
///   - `dma_base` = source byte offset within the image (DMATRFFBOFFS origin)
///   - `mem_base` = destination byte offset within IMEM/DMEM (DMATRFMOFFS)
/// For DMEM the reference folds dma_base into DMATRFBASE and zeroes the FB-offset
/// origin (`dma_start`); for IMEM it leaves the FB offset absolute. We reproduce
/// that exactly so the on-wire register values match the reference.
pub fn dmaWrite(f: Falcon, img_phys: u64, dma_base: u32, mem_base: u32, len: u32, is_imem: bool, sec: bool) Error!void {
    if (len == 0 or (len & (DMA_BLOCK - 1)) != 0) {
        log("gpu.falcon: dmaWrite len {} not 256-aligned\n", .{len});
        return error.FalconLoadNotImplemented;
    }

    // DMATRFBASE (0x110) holds a 256-byte-granular base (addr>>8); the per-block
    // DMATRFFBOFFS (0x11c) is the BYTE offset added to base<<8. The base MUST be
    // 256-aligned (folding an unaligned offset into it loses the low byte in >>8 —
    // THAT was the booter bug). `img_phys` here is required to be 256-aligned by
    // the caller (page-aligned ucode buffer, like nouveau's fw.phys); `dma_base`
    // is the byte offset within it and goes into the FB offset.
    if (img_phys & 0xff != 0) {
        log("gpu.falcon: dma img_phys 0x{x} not 256-aligned\n", .{img_phys});
        return error.FalconLoadNotImplemented;
    }
    var cmd: u32 = (@as(u32, ilog2(DMA_BLOCK)) - 2) << 8;
    if (is_imem) cmd |= 0x00000010;
    if (sec) cmd |= 0x00000004;
    f.wr(DMA_TRANS, @intCast(img_phys >> 8));
    f.wr(DMA_TRANS_HI, @intCast(img_phys >> 40));

    var dst = mem_base;
    var src = dma_base; // byte offset within the (aligned) buffer
    var remaining = len;
    var first = true;
    while (remaining >= DMA_BLOCK) {
        f.wr(DMA_MEM_OFF, dst);
        f.wr(DMA_FB_OFF, src);
        f.wr(DMA_CMD, cmd);
        // FIX C: TSC wall-clock deadline for the per-block DMA-done bit, not a fixed
        // iteration count (which is MMIO-speed-dependent — a budget tuned to vfio's
        // ~1µs/trapped read is off by orders of magnitude on a faster path). A block
        // DMA completes in ~µs; 1s is ample. Same policy as waitMemScrubbing.
        const dma_deadline = tsc.rdtsc() + tsc.msTicks(1000);
        var reads: u64 = 0;
        while ((f.rd(DMA_CMD) & 0x00000002) == 0) {
            reads += 1;
            if (tsc.rdtsc() >= dma_deadline) {
                log("gpu.falcon: DMA done-poll timeout (cmd=0x{x}, dst=0x{x}); SEC2 likely needs reset/select first\n", .{ f.rd(DMA_CMD), dst });
                return error.FalconLoadNotImplemented;
            }
        }
        if (first) {
            log("gpu.falcon: DMA first-block done in {} poll-reads\n", .{reads});
            first = false;
        }
        dst += DMA_BLOCK;
        src += DMA_BLOCK;
        remaining -= DMA_BLOCK;
    }
}

/// Load a signed falcon firmware image (booter/bootloader) into IMEM/DMEM and
/// boot it. Cross-checked against ga102_gsp_booter_ctor (parse) +
/// ga102_flcn_fw_load (DMA) + ga102_flcn_fw_boot (boot) + nvkm_falcon_dma_wr.
///
/// Pick the production-signature index for this falcon image by fuse version
/// (ga100_flcn_fw_signature). `f` must be a *device* register view (BAR0 base 0)
/// to read the fuse regs; we pass the regs mapping + read absolute offsets.
fn selectSignatureIdx(regs: mmio.Mapping, img: falconfw.FalconImage) Error!u32 {
    const fuse_reg: u64 = if (img.engine_id & 0x1 != 0)
        FUSE_VER_ENG1 + (@as(u64, img.ucode_id) - 1) * 4
    else if (img.engine_id & 0x4 != 0)
        FUSE_VER_ENG4 + (@as(u64, img.ucode_id) - 1) * 4
    else if (img.engine_id & 0x400 != 0)
        FUSE_VER_ENG400 + (@as(u64, img.ucode_id) - 1) * 4
    else
        return error.FalconLoadNotImplemented;

    const reg_fuse = regs.read32(fuse_reg);
    if (reg_fuse == 0) return img.num_sig - 1;
    const rfv = fls(reg_fuse);
    if (img.fuse_ver < rfv) return error.FalconLoadNotImplemented;
    return img.fuse_ver - rfv;
}

/// ga102_flcn_fw_load preamble (mask 0x624, clear 0x10c, set 0x600 to select the
/// sysmem DMA aperture). Call after enable(), before dmaWrite().
pub fn loadPreamble(f: Falcon) void {
    f.mask(0x624, 0x00000080, 0x00000080);
    f.wr(0x10c, 0x00000000);
    f.mask(0x600, 0x00010007, (0 << 16) | (1 << 2) | 1);
}

/// Program the BROM signature/engine/ucode regs (ga102_flcn_fw_boot prologue)
/// then start the core at `boot_addr` with mbox0 and poll halted (0x100 bit4).
/// Returns mbox0 after halt. Errors (RiscvBootTimeout) if the core never halts
/// within the spin budget — a timed-out boot must NOT be reported as a mbox0
/// value the caller would read as success. `dmem_sign` is patch_loc - dmem src.
pub fn bootAndWait(f: Falcon, dmem_sign: u32, engine_id: u32, ucode_id: u32, boot_addr: u32, mbox0: u32) Error!u32 {
    if (f.is_riscv) {
        f.wr(f.addr2 + 0x210, dmem_sign);
        f.wr(f.addr2 + 0x19c, engine_id);
        f.wr(f.addr2 + 0x198, ucode_id);
        f.wr(f.addr2 + 0x180, 0x00000001);
    }
    f.wr(Reg.MAILBOX0, mbox0);
    f.wr(Reg.BOOTVEC, boot_addr);
    f.wr(Reg.CPUCTL, 0x00000002);
    // FIX C: TSC wall-clock deadline for the halt bit (0x100 bit4), not a fixed
    // iteration count. nouveau gm200_flcn_fw_boot waits nvkm_msec(&device, 2000,...);
    // match that wall-clock budget so the poll is MMIO-speed-independent.
    const boot_deadline = tsc.rdtsc() + tsc.msTicks(2000);
    var boot_spins: u32 = 0;
    while (tsc.rdtsc() < boot_deadline) : (boot_spins +%= 1) {
        if ((f.rd(Reg.CPUCTL) & 0x00000010) != 0) break;
        // Up to 2 s inside the drain-pumping system task — keep the trace
        // flowing (same rationale as the fwBoot halt poll below).
        if (boot_spins % 1024 == 0) if (spinwait.pump) |pp| pp();
    }
    if ((f.rd(Reg.CPUCTL) & 0x00000010) == 0) {
        log("gpu.falcon: bootAndWait: core never halted (cpuctl=0x{x} mbox0=0x{x})\n", .{ f.rd(Reg.CPUCTL), f.rd(Reg.MAILBOX0) });
        return error.RiscvBootTimeout;
    }
    return f.rd(Reg.MAILBOX0);
}

/// Load a signed falcon firmware image into IMEM/DMEM and boot it. Cross-checked
/// against ga102_gsp_booter_ctor (parse) + nvkm_falcon_fw_patch (signature) +
/// ga102_flcn_fw_load (DMA) + ga102_flcn_fw_boot (boot).
///
/// `image` is the read-only firmware blob; `regs` is the BAR0 device mapping (for
/// the fuse-version registers). We copy the blob into a writable, identity-mapped
/// buffer, patch the fuse-selected signature into it (nvkm_falcon_fw_patch), then
/// DMA from that physical copy and boot.
pub fn loadAndBoot(f: Falcon, regs: mmio.Mapping, name: []const u8, image: []const u8, mbox0: u32, mbox1: u32) Error!void {
    const img = falconfw.parse(name, image) catch |e| {
        log("gpu.falcon: {s}: container parse failed: {}\n", .{ name, e });
        return error.FalconLoadNotImplemented;
    };

    // Copy the UCODE IMAGE (blob + bin.data_offset, length bin.data_size) into a
    // fresh PAGE-ALIGNED DMA buffer — exactly nouveau's nvkm_falcon_fw_ctor
    // (fw.img = a page-aligned copy of blob+data_offset). This is what makes the
    // DMATRFBASE aligned; the IMEM/DMEM offsets (app[0].offset, os_data_offset)
    // and patch_loc are all relative to this fw.img base.
    const ucode_len = img.bin.data_size;
    const pages = (ucode_len + 0xfff) / 0x1000;
    const ucode_phys = shim.allocPagesPhys(@intCast(pages)) orelse return error.FalconLoadNotImplemented;
    // The falcon DMAs this copy into its own IMEM/DMEM and boots from there; the
    // sysmem copy is dead once loaded. Free it on every exit so re-runs (each
    // booter_load / booter_unload / FWSEC boots via this path) don't leak it.
    defer shim.freePagesPhys(ucode_phys, @intCast(pages));
    const ucode: [*]u8 = @ptrFromInt(ucode_phys);
    @memcpy(ucode[0..ucode_len], image[img.bin.data_offset .. img.bin.data_offset + ucode_len]);

    // Signature patch (nvkm_falcon_fw_patch): dst = patch_loc (fw.img-relative);
    // source sigs are BLOB-relative (HS header area, before data_offset).
    const idx = try selectSignatureIdx(regs, img);
    const sig_size = img.hs.sig_prod_size / img.num_sig;
    const sigs_base = img.hs.sig_prod_offset + img.patch_sig;
    const src_off = sigs_base + idx * sig_size; // in `image` (blob)
    const dst_off = img.patch_loc; // in `ucode` (fw.img)
    if (@as(u64, src_off) + sig_size > image.len or @as(u64, dst_off) + sig_size > ucode_len)
        return error.FalconLoadNotImplemented;
    @memcpy(ucode[dst_off .. dst_off + sig_size], image[src_off .. src_off + sig_size]);
    const s0 = @as(u32, ucode[dst_off]) | (@as(u32, ucode[dst_off + 1]) << 8) | (@as(u32, ucode[dst_off + 2]) << 16) | (@as(u32, ucode[dst_off + 3]) << 24);
    log("gpu.falcon: {s}: sig idx={} size={} src=0x{x} -> ucode@0x{x} firstdword=0x{x:0>8} (nouveau:0x1ca0d30e)\n", .{ name, idx, sig_size, src_off, dst_off, s0 });

    // Flush just the ucode copy buffer (CPU-written) so the falcon DMA reads the
    // patched bytes. clflush the range, NOT a full wbinvd — wbinvd with the 24GB
    // GPU BAR mapped costs ~seconds and trips the timing-sensitive GSP-init.
    shim.flushRange(ucode_phys, ucode_len);

    // Bring the falcon up (reset_eng + select) before loading.
    log("gpu.falcon: {s}: pre-enable t={}ms\n", .{ name, @import("../../../kernel/timer/timer.zig").millis() });
    enable(f) catch |e| {
        log("gpu.falcon: {s}: enable failed: {}\n", .{ name, e });
        return error.FalconLoadNotImplemented;
    };
    log("gpu.falcon: {s}: post-enable t={}ms\n", .{ name, @import("../../../kernel/timer/timer.zig").millis() });

    // ga102_flcn_fw_load preamble.
    loadPreamble(f);

    // DMA from the page-aligned ucode buffer. Offsets are fw.img-relative:
    // IMEM <- app[0] (offset/size), DMEM <- os_data (offset/size). sec: IMEM yes,
    // DMEM no (ga102_flcn_fw_load). ucode_phys is 256-aligned so DMATRFBASE is
    // exact and the byte offsets go through DMATRFFBOFFS.
    try dmaWrite(f, ucode_phys, img.app0.offset, 0, img.app0.size, true, true);
    try dmaWrite(f, ucode_phys, img.load.os_data_offset, 0, img.load.os_data_size, false, false);
    log("gpu.falcon: {s}: DMA loaded imem {} B + dmem {} B t={}ms\n", .{ name, img.app0.size, img.load.os_data_size, @import("../../../kernel/timer/timer.zig").millis() });

    // (Removed the DMEM[sig]/IMEM[0] readback diagnostics: they wrote the falcon's
    // memory-port-select regs (0x1c0/0x180) on a falcon about to HS-secure-boot —
    // nouveau never touches these, and poking them can disturb the secure boot.)

    // ga102_flcn_fw_boot prologue (BROM regs) — only for RISC-V/BROM falcons.
    // SEC2 (classic falcon) skips these and just does the classic boot below.
    const dmem_sign = img.patch_loc - img.load.os_data_offset;
    if (f.is_riscv) {
        f.wr(f.addr2 + 0x210, dmem_sign);
        f.wr(f.addr2 + 0x19c, img.engine_id);
        f.wr(f.addr2 + 0x198, img.ucode_id);
        f.wr(f.addr2 + 0x180, 0x00000001);
    }

    // gm200_flcn_fw_boot: mbox0/1 (= WPR meta phys addr for the booter), boot
    // vector to 0x104, start core (0x100=2), poll halted (0x100 bit4).
    f.wr(Reg.MAILBOX0, mbox0);
    f.wr(Reg.MAILBOX1, mbox1);
    f.wr(Reg.BOOTVEC, img.app0.offset); // boot_addr = app[0].offset
    log("gpu.falcon: {s}: pre-start cpuctl=0x{x} brom-en check\n", .{ name, f.rd(Reg.CPUCTL) });
    f.wr(Reg.CPUCTL, 0x00000002);
    log("gpu.falcon: {s}: core started (boot_addr=0x{x}); polling halt\n", .{ name, img.app0.offset });

    // FIX C: TSC wall-clock deadline for the halt bit, not a fixed iteration count
    // (MMIO-speed-dependent). nouveau gm200_flcn_fw_boot waits nvkm_msec(2000,...);
    // `spins` stays a read-counter for the diagnostic log below.
    const halt_deadline = tsc.rdtsc() + tsc.msTicks(2000);
    var spins: u64 = 0;
    while (tsc.rdtsc() < halt_deadline) {
        spins += 1;
        if ((f.rd(Reg.CPUCTL) & 0x00000010) != 0) break; // halted
        // This poll runs up to 2 s inside the drain-pumping system task;
        // without this leg the trace goes quiet and the drain deadman
        // (correctly) reports the silence on a healthy boot.
        if (spins % 1024 == 0) if (spinwait.pump) |pp| pp();
    }
    const halted = (f.rd(Reg.CPUCTL) & 0x00000010) != 0;
    const m0 = f.rd(Reg.MAILBOX0);
    const m1 = f.rd(Reg.MAILBOX1);
    // BROM diagnostics: addr2+0x350 = BROM engine ctl/status, addr2+0x354 =
    // BROM error code (nonzero => signature/auth failure). intr 0x008.
    log("gpu.falcon: {s}: BROM ctl(0x{x})=0x{x} err(0x{x})=0x{x} intr(0x008)=0x{x} exci=0x{x}\n", .{ name, f.addr2 + 0x350, f.rd(f.addr2 + 0x350), f.addr2 + 0x354, f.rd(f.addr2 + 0x354), f.rd(0x008), f.rd(f.addr2 + 0x1c0) });
    // Diagnostics: cpuctl(0x100), halt state, BROM error/status (addr2+0x350 EXCI,
    // addr2+0x354), HWCFG2 halted bit, RISC-V active.
    log("gpu.falcon: {s}: spins={} halted={} cpuctl=0x{x} mbox0=0x{x} mbox1=0x{x}\n", .{ name, spins, (f.rd(Reg.CPUCTL) & 0x10) != 0, f.rd(Reg.CPUCTL), m0, m1 });
    log("gpu.falcon: {s}: hwcfg2(0xf4)=0x{x} irqstat(0x008)=0x{x} os(0x080)=0x{x}\n", .{ name, f.rd(Reg.HWCFG2), f.rd(0x008), f.rd(0x080) });
    if (!halted) {
        log("gpu.falcon: {s}: core never halted (spins exhausted) cpuctl=0x{x}\n", .{ name, f.rd(Reg.CPUCTL) });
        return error.RiscvBootTimeout;
    }
    if (m0 != 0) {
        log("gpu.falcon: {s}: booter returned error mbox0=0x{x}\n", .{ name, m0 });
        return error.FalconLoadNotImplemented;
    }
}
