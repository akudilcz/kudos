//! GSP firmware boot + RPC handshake. After BARs are mapped, DMA is available,
//! and the MSI ISR is wired, this loads the signed GSP image into DMA memory,
//! releases the GSP RISC-V core from reset, and brings up the command/status RPC
//! ring shared with the GPU.
//!
//! Boot-sequence shape (nouveau drivers/gpu/drm/nouveau/nvkm/subdev/gsp/r535.c):
//!   1. place the GSP-RM image + radix3 page tables in WPR (write-protected region)
//!   2. fill GSP_FW_WPR_META (frts/boot addresses, sizes) for the booter
//!   3. run the signed "booter load" falcon ucode to bring up GSP-RM in WPR
//!   4. init the command/status message queues (rmargs points the GSP at them)
//!   5. complete the init RPC handshake
//!
//! The concrete register offsets and the byte-exact layouts of WPR_META /
//! message-queue headers / rmargs are **version-locked to the vendored
//! driver+firmware triple** and must be taken from the pinned
//! open-gpu-kernel-modules source, never from memory. The boot path fails loudly
//! when a blob is missing — never a silent fake-success.

const std = @import("std");
const log = @import("../base/log.zig").gpu;
const shim = @import("../base/shim.zig");
const mmio = @import("../base/mmio.zig");
const pci = @import("../../pci/pci.zig");
const falcon = @import("falcon.zig");
const gspfw = @import("../base/gspfw.zig");
const radix3 = @import("radix3.zig");
const fblayout = @import("../base/fblayout.zig");
const vbios = @import("vbios.zig");
const fwsec = @import("fwsec.zig");
const elf = @import("elf.zig");
const top = @import("top.zig");
const msgq = @import("msgq.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const wpr2dump = @import("wpr2dump.zig");

/// GSP-RM boot app version, parsed from the bootloader desc; written to GSP
/// falcon reg 0x080 at RISC-V boot (r535_gsp_init).
var boot_app_version: u32 = 0;

/// The signed GSP firmware image set, supplied out-of-band (no filesystem on
/// kudos). NVIDIA's blobs, version-locked to the pinned 570.144 release; hosted,
/// never modified. The set mirrors the nouveau ad102/570.144 firmware files;
/// `firmware.zig` builds this from the multiboot2 boot modules GRUB loaded.
pub const Firmware = struct {
    /// The GSP-RM image placed into WPR (the large ~63 MB signed image).
    gsp_rm: []const u8,
    /// Signed "booter load" SEC2 falcon ucode: authenticates + loads GSP-RM into WPR.
    booter_load: []const u8,
    /// Signed "booter unload" falcon ucode: tears down WPR on shutdown.
    booter_unload: []const u8,
    /// GSP RISC-V bootloader falcon image.
    bootloader: []const u8,
    /// Memory-scrubber falcon image the booter requires.
    scrubber: []const u8,

    /// True only when every image is present and non-empty — the precondition for
    /// attempting GSP boot. Missing any blob is a loud error, never a fake boot.
    pub fn complete(self: Firmware) bool {
        return self.gsp_rm.len != 0 and self.booter_load.len != 0 and
            self.booter_unload.len != 0 and self.bootloader.len != 0 and
            self.scrubber.len != 0;
    }
};

/// Live GSP state once booted: BAR0 falcon view + the shared queues + the radix3
/// table + the WPR meta page, kept for RPC and teardown.
pub const Gsp = struct {
    regs: mmio.Mapping,
    flcn: falcon.Falcon,
    sec2: falcon.Falcon,
    shared: msgq.Shared,
    rx3: radix3.Radix3,
    wpr_meta_phys: u64,
    libos_phys: u64,
    app_version: u32,
    running: bool,
    /// The VRAM/WPR2 carve `boot` computed — exposes `fb.free`, the VRAM region
    /// below the RM's reserved top that the display path bump-allocates from.
    fb: fblayout.FbLayout,
    /// Teardown inputs (shutdown): the read VBIOS + FWSEC desc offset (for FWSEC-SB)
    /// and the signed booter_unload ucode (clears WPR2). Kept from boot so
    /// `shutdown` can run tu102_gsp_fini without re-reading the VBIOS.
    vbios: vbios.Vbios,
    fwsec_desc_off: u32,
    booter_unload: []const u8,
    /// Every persistent device-visible DMA buffer this boot allocated. `shutdown`
    /// frees them all so a re-run doesn't leak PMM.
    dma: shim.DmaTracker,
};

pub const Error = error{
    GspFirmwareMissing,
    GspBootTimeout,
    GspRpcNotImplemented,
    GspNotImplemented,
    GspRiscvInactive,
} || falcon.Error || radix3.Error || msgq.Error;

/// Boot the GSP and complete the init RPC handshake. Returns the live Gsp on
/// success. Fails loudly: a missing blob, a booter fault, or a handshake timeout
/// is an error, never a degraded "no-GPU" continue (CLAUDE.md no-fallbacks).
///
/// Sequence (nouveau r535):
///   1. radix3-map the GSP image; allocate + fill GspFwWprMeta.
///   2. reset the GSP falcon; run booter_load (SEC2) to authenticate+load into WPR.
///   3. init the shared cmd/status message queues.
///   4. boot the GSP RISC-V core; poll for GSP_INIT_DONE.
pub fn boot(regs: mmio.Mapping, dev: pci.Device, fw: Firmware) Error!Gsp {
    if (!fw.complete()) {
        log("gpu.gsp: firmware not fully provisioned\n", .{});
        return error.GspFirmwareMissing;
    }
    const flcn = falcon.gsp(regs);
    log("gpu.gsp: boot START t={}ms\n", .{timer.millis()});

    // Track every PERSISTENT device-visible DMA buffer (image, sig, bootloader,
    // WPR meta, radix3, shared queues, logs, rmargs, libos) so `shutdown` frees
    // them all. Without this each bring-up (re-runnable)
    // leaks ~64 MB of PMM. Transient falcon/FWSEC copies free themselves locally.
    var dma: shim.DmaTracker = .{};
    // Free every tracked buffer on ANY error return from here on. A re-run
    // is re-runnable, so without this each failed boot (VBIOS/FWSEC/booter_load/
    // INIT_DONE) leaks ~64 MB of PMM until it is exhausted. On SUCCESS this does not
    // fire — `g` takes ownership of `dma` (by value; same frames) and `shutdown`
    // frees them later. The tracker is a plain value copied into `g`, so freeing via
    // this local on error frees the same frames with no second owner.
    errdefer dma.freeAll();

    // KTRACE off: register logging is enormous trace overhead and slows GSP-init
    // servicing — the GSP-RM init is timing-sensitive (too-slow host servicing ->
    // INIT_DONE NOT_READY). Leave the hook available but disabled.
    mmio.ktrace_on = false;

    // 1. The GSP-RM blob is an ELF: radix3-map only its `.fwimage` section, and
    //    take the booter signature from `.fwsignature_ad10x` (nouveau r535
    //    .fwimage/sig_section loads). Mapping the raw blob (what we did before)
    //    gives the booter the wrong image + a zero signature -> it won't verify.
    const fwimage = elf.section(fw.gsp_rm, ".fwimage") catch |e| {
        log("gpu.gsp: GSP-RM .fwimage not found: {}\n", .{e});
        return error.GspFirmwareMissing;
    };
    const fwsig = elf.section(fw.gsp_rm, ".fwsignature_ad10x") catch |e| {
        log("gpu.gsp: GSP-RM .fwsignature_ad10x not found: {}\n", .{e});
        return error.GspFirmwareMissing;
    };

    // Copy .fwimage into a fresh PAGE-ALIGNED buffer before radix3-mapping it.
    // radix3 maps page-by-page (image_phys + i*PAGE), so the image base must be
    // page aligned; a slice into the ELF blob at sh_offset is not guaranteed to
    // be. Nouveau loads .fwimage into a page-allocated gsp->fw.img for the same
    // reason. ~63 MB — fine on our 64 GiB heap.
    const img_pages: u32 = @intCast((fwimage.data.len + 0xfff) / 0x1000);
    const image_phys = dma.alloc(img_pages) orelse return error.GspBootTimeout;
    const image_buf: [*]u8 = @ptrFromInt(image_phys);
    std.mem.copyForwards(u8, image_buf[0..fwimage.data.len], fwimage.data);
    const rx3 = try radix3.build(&dma, image_phys, fwimage.data.len);

    // Copy the signature into a fresh page-aligned buffer of ALIGN(size,256)
    // (nouveau nvkm_gsp_mem_ctor(ALIGN(size,256), &gsp->sig) + memcpy). The booter
    // DMAs from sysmemAddrOfSignature, which must be 256-aligned (falcon DMA).
    const sig_alloc = (fwsig.data.len + 0xff) & ~@as(usize, 0xff);
    const sig_pages: u32 = @intCast((sig_alloc + 0xfff) / 0x1000);
    const sig_phys = dma.alloc(sig_pages) orelse return error.GspBootTimeout;
    const sig_buf: [*]u8 = @ptrFromInt(sig_phys);
    std.mem.copyForwards(u8, sig_buf[0..fwsig.data.len], fwsig.data);
    log("gpu.gsp: .fwimage {} bytes @0x{x}, .fwsignature {} bytes @0x{x}\n", .{ fwimage.data.len, image_phys, fwsig.data.len, sig_phys });
    // (firmware-buffer KSUMs removed — contents already confirmed byte-identical
    // to nouveau, and summing 63 MB in a Debug build added seconds of pre-boot
    // delay that hurt the timing-sensitive GSP init.)

    // 1a. The bootloader blob is an nvfw container (nvfw_bin_hdr): header_offset
    //     @+12 -> RM_RISCV_UCODE_DESC, data_offset @+16, data_size @+20. We mirror
    //     nouveau r535_gsp_rm_boot_ctor exactly: copy `data_size` bytes from
    //     `blob + data_offset` into a FRESH page-aligned DMA buffer, and hand the
    //     booter that buffer's base + size. Pointing into the raw multiboot module
    //     (what we did before) gives a non-256-aligned source the falcon DMA can't
    //     address, and the wrong size (bl.len-data_off includes the trailing desc).
    const rd = struct {
        /// Read a little-endian u32 from the bootloader blob at byte offset `o`.
        fn u(d: []const u8, o: usize) u32 {
            return @as(u32, d[o]) | (@as(u32, d[o + 1]) << 8) | (@as(u32, d[o + 2]) << 16) | (@as(u32, d[o + 3]) << 24);
        }
    }.u;
    const bl = fw.bootloader;
    const bl_hdr_off = rd(bl, 12); // nvfw_bin_hdr.header_offset
    const bl_data_off = rd(bl, 16); // .data_offset
    const bl_data_size = rd(bl, 20); // .data_size
    const desc = bl[bl_hdr_off..]; // RM_RISCV_UCODE_DESC
    const bl_app_version = rd(desc, 28);
    const bl_manifest_off = rd(desc, 32);
    const bl_monitor_data_off = rd(desc, 40);
    const bl_monitor_code_off = rd(desc, 48);
    boot_app_version = bl_app_version;

    // Copy the bootloader image into a fresh page-aligned DMA buffer (nouveau
    // nvkm_gsp_mem_ctor(hdr->data_size) + memcpy(blob + data_offset, data_size)).
    const bl_pages: u32 = @intCast((bl_data_size + 0xfff) / 0x1000);
    const boot_fw_phys = dma.alloc(bl_pages) orelse return error.GspBootTimeout;
    const boot_fw_buf: [*]u8 = @ptrFromInt(boot_fw_phys);
    @import("std").mem.copyForwards(u8, boot_fw_buf[0..bl_data_size], bl[bl_data_off .. bl_data_off + bl_data_size]);

    // 1b. Compute the GPU FB/WPR2 layout (reads VRAM size from BAR0) and fill the
    //     WPR meta exactly as nouveau tu102_gsp_wpr_meta_init does.
    // WPR2 boot region size is the bootloader *data_size* (nouveau
    // gsp->fb.wpr2.boot.size = gsp->boot.fw.size), not the whole blob length.
    const fbl = fblayout.compute(regs, fwimage.data.len, bl_data_size);
    const wpr_meta_phys = dma.alloc(1) orelse return error.GspBootTimeout;
    const meta: *volatile gspfw.GspFwWprMeta = @ptrFromInt(wpr_meta_phys);
    meta.* = @import("std").mem.zeroes(gspfw.GspFwWprMeta);
    meta.magic = gspfw.GSP_FW_WPR_META_MAGIC;
    meta.revision = gspfw.GSP_FW_WPR_META_REVISION;
    // SYSMEM addresses (host RAM, DMAed by the Booter).
    meta.sysmemAddrOfRadix3Elf = rx3.lvl0;
    meta.sizeOfRadix3Elf = fbl.elf.size;
    meta.sysmemAddrOfBootloader = boot_fw_phys;
    meta.sizeOfBootloader = bl_data_size;
    meta.bootloaderCodeOffset = bl_monitor_code_off;
    meta.bootloaderDataOffset = bl_monitor_data_off;
    meta.bootloaderManifestOffset = bl_manifest_off;
    meta.sysmemAddrOfSignature = sig_phys;
    meta.sizeOfSignature = sig_alloc; // ALIGN(orig_size, 256), as nouveau gsp->sig.size
    // FB layout (VRAM offsets).
    meta.gspFwRsvdStart = fbl.nonwpr_heap.addr;
    meta.nonWprHeapOffset = fbl.nonwpr_heap.addr;
    meta.nonWprHeapSize = fbl.nonwpr_heap.size;
    meta.gspFwWprStart = fbl.wpr2.addr;
    meta.gspFwHeapOffset = fbl.heap.addr;
    meta.gspFwHeapSize = fbl.heap.size;
    meta.gspFwOffset = fbl.elf.addr;
    meta.bootBinOffset = fbl.boot.addr;
    meta.frtsOffset = fbl.frts.addr;
    meta.frtsSize = fbl.frts.size;
    meta.gspFwWprEnd = (fbl.bios.addr) & ~@as(u64, 0x1ffff); // ALIGN_DOWN(bios.addr,0x20000)
    meta.fbSize = fbl.fb_size;
    meta.vgaWorkspaceOffset = fbl.bios.addr;
    meta.vgaWorkspaceSize = fbl.bios.size;
    meta.bootCount = 0;
    meta.verified = 0;
    log("gpu.gsp: WPR meta @0x{x} filled (fb={} MiB, wpr2@0x{x})\n", .{ wpr_meta_phys, fbl.fb_size >> 20, fbl.wpr2.addr });

    // 1c. Read + parse the VBIOS to locate FWSEC (the ucode that sets up the
    //     FRTS region in WPR2, which the booter requires). FWSEC lives in the
    //     VBIOS, not the firmware package (nouveau fwsec.c). Read a generous
    //     192 KiB window (ROM is ~128 KiB+).
    // FWSEC-FRTS is FATAL on failure (nouveau tu102_gsp_oneinit: WARN_ON(ret) ->
    // return). It provisions the FRTS region the PMU reads; booting without it
    // makes the PMU fault during RM init (Xid 62). Do not swallow the error.
    const vb = vbios.read(regs, dev, 1024 * 1024) catch |e| {
        log("gpu.gsp: VBIOS read failed: {}\n", .{e});
        return error.GspNotImplemented;
    };
    const fwsec_loc = vbios.findFwsec(vb) catch |e| {
        log("gpu.gsp: FWSEC not found in VBIOS: {}\n", .{e});
        return error.GspNotImplemented;
    };
    log("gpu.gsp: FWSEC @0x{x} t={}ms; running FWSEC-FRTS\n", .{ fwsec_loc.desc_offset, timer.millis() });
    fwsec.run(.frts, regs, vb, fwsec_loc.desc_offset, fbl.frts.addr, fbl.frts.size) catch |e| {
        log("gpu.gsp: FWSEC-FRTS FAILED (fatal): {}\n", .{e});
        return error.GspNotImplemented;
    };

    // Step-1 probe (Xid-62 gap closure): FRTS just programmed the WPR2 boundary
    // registers (NV_PFB_PRI_MMU_WPR2_ADDR_LO/HI). nv logs these raw in
    // nvkm_gsp_fwsec_frts (fwsec.c:371). Read them raw and print alongside our
    // computed fblayout so the two can be diffed directly against the nv trace.
    {
        const wpr2_lo_raw = regs.read32(fblayout.WPR2_LO_REG);
        const wpr2_hi_raw = regs.read32(fblayout.WPR2_HI_REG);
        log("gpu.gsp: WPR2 regs raw lo=0x{x} hi=0x{x} | computed wpr2.addr=0x{x} wpr2.end=0x{x} frts.addr=0x{x}\n", .{
            wpr2_lo_raw, wpr2_hi_raw, fbl.wpr2.addr, fbl.wpr2.addr + fbl.wpr2.size, fbl.frts.addr,
        });
    }

    // 1d. Build the shared cmd/status message queues + the libos arg buffer +
    //     rmargs (nouveau r535_gsp_shared_init / libos_init / set_rmargs). The
    //     GSP RISC-V core reads the libos arg buffer (which references rmargs ->
    //     the queues) from GSP falcon 0x040/0x044, set just below before the
    //     booter launches the core.
    log("gpu.gsp: pre-buildShared t={}ms\n", .{timer.millis()});
    const shared = try msgq.buildShared(&dma);
    const libos = try msgq.buildLibos(&dma, shared);
    log("gpu.gsp: post-buildLibos t={}ms\n", .{timer.millis()});

    // 1e. Queue GSP_SET_SYSTEM_INFO (fn 72) + SET_REGISTRY (fn 73) into the cmdq
    //     BEFORE the booter (nouveau r535_gsp_oneinit). The GSP RM consumes these
    //     as the first thing after it boots; without system info it faults during
    //     init (Xid 62). These are fire-and-forget (no reply waited).
    // fn=72 payload byte-verified vs nv (only BAR0/BDF differ, both env-legit) —
    // keep silent; trace I/O here is in the latency-sensitive init window.
    msgq.dump_payload = false;
    setSystemInfo(flcn, shared, dev) catch |e| {
        log("gpu.gsp: set_system_info send failed: {}\n", .{e});
        return error.GspNotImplemented;
    };
    setRegistry(flcn, shared) catch |e| {
        log("gpu.gsp: set_registry send failed: {}\n", .{e});
        return error.GspNotImplemented;
    };

    // 2. Reset the GSP falcon into RISC-V mode (nouveau gsp->func->reset =
    //    reset_eng), then point it at the libos args (0x040/0x044). Done BEFORE
    //    the booter, which launches the GSP RISC-V core.
    log("gpu.gsp: pre-reset(post set_sysinfo/registry) t={}ms\n", .{timer.millis()});
    try falcon.reset(flcn);
    // FIX B (uniform flush discipline): before latching the libos-args address into
    // falcon 0x040/0x044, push every GSP-read shared buffer to RAM — the whole
    // shared queue region, the libos region table, rmargs, and the three log pages.
    // The ring paths already clflush because this mapping is not reliably snooped
    // for the GSP's DMA; these sibling buffers (which the GSP reads at RISC-V boot,
    // right after the booter launches the core) were the coherency gap. msgq owns
    // the sizes; clflush per line, not wbinvd.
    msgq.flushForHandoff(shared, libos);
    flcn.wr(falcon.Reg.MAILBOX0, @truncate(libos.libos_phys));
    flcn.wr(falcon.Reg.MAILBOX1, @truncate(libos.libos_phys >> 32));

    // 2b. Run booter_load on the SEC2 falcon (base 0x840000) to authenticate +
    //     load GSP-RM into WPR and launch the GSP RISC-V core. The booter reads
    //     the WPR meta from the address we hand it via SEC2 mbox0/mbox1 (nouveau
    //     tu102_gsp_init/booter_load); mbox0==0 on return means success.
    // Flush the CPU-written DMA buffers the booter/GSP read. x86 PCIe DMA is
    // snooped (coherent), but clflush the small control structures to be safe —
    // NOT a full wbinvd (that costs ~seconds with the GPU BAR mapped and was a
    // major contributor to the GSP-init timeout). The large image/sig/bootloader
    // buffers were already range-flushed where copied; radix3 + WPR meta here.
    shim.flushRange(wpr_meta_phys, 0x1000); // WPR meta page
    shim.flushRange(rx3.lvl0, 0x1000); // radix3 level 0
    shim.flushRange(rx3.lvl1, 0x1000); // radix3 level 1
    shim.flushRange(rx3.lvl2, rx3.lvl2_pages * 0x1000); // radix3 level 2

    // Find SEC2's PMC reset bit from the TOP table so we can power it on.
    const sec2_info = top.find(regs, top.ENGINE_SEC2);
    const sec2_bit: u8 = if (sec2_info) |s| s.reset else 0xff;
    log("gpu.gsp: SEC2 pmc_reset_bit={}\n", .{sec2_bit});
    const sec2 = falcon.sec2(regs, sec2_bit);
    const mbox0: u32 = @truncate(wpr_meta_phys);
    const mbox1: u32 = @truncate(wpr_meta_phys >> 32);

    // The booter's success signal is mbox0==0 (nouveau gm200_flcn_fw_boot checks
    // mbox0 == mbox0_ok, with mbox0_ok=0 for booter_load). It does NOT write the
    // meta `verified` field — that's set later by GSP-RM. loadAndBoot already
    // returns an error iff mbox0!=0, so a clean return == booter success.
    falcon.loadAndBoot(sec2, regs, "booter_load", fw.booter_load, mbox0, mbox1) catch |e| {
        log("gpu.gsp: booter_load failed: {}\n", .{e});
        return error.GspNotImplemented;
    };
    const wpr2_hi = regs.read32(fblayout.WPR2_HI_REG);
    log("gpu.gsp: booter_load OK t={}ms wpr2_hi=0x{x}\n", .{ timer.millis(), wpr2_hi });

    // Step-3 result: a PRAMIN-window read of locked WPR2 returns bad0acNN poison
    // on BOTH kudos and nouveau (verified on HW) — WPR2 is access-protected after
    // the Booter locks it, so its content is not host-readable and cannot be diffed.
    // (wpr2dump.dump is kept available but not called; the Xid errString below is
    // the live diagnostic.)
    _ = &wpr2dump;

    // 3. RISC-V boot: write boot.app_version to GSP falcon 0x080 and confirm the
    //    RISC-V core is active (nouveau r535_gsp_init).
    flcn.wr(falcon.Reg.BOOT_APP_VERSION, boot_app_version);
    if (!flcn.riscvActive()) {
        log("gpu.gsp: GSP RISC-V core not active after booter (riscv_active=0)\n", .{});
        return error.GspRiscvInactive;
    }
    log("gpu.gsp: GSP RISC-V active (app_version=0x{x}) t={}ms; polling for GSP_INIT_DONE\n", .{ boot_app_version, timer.millis() });

    // 4. Drive the status queue until GSP_INIT_DONE (0x1001), servicing any
    //    GSP_RUN_CPU_SEQUENCER events the GSP issues mid-init.
    msgq.poll(flcn, sec2, regs, shared, libos.libos_phys, boot_app_version, @intFromEnum(gspfw.MsgEvent.gsp_init_done)) catch |e| {
        // On stall, dump the GSP's own log buffers — they hold its early-boot
        // log / exception dump, the decisive evidence for why it didn't proceed.
        msgq.dumpLogs(libos);
        log("gpu.gsp: GSP init poll failed: {} (gsp.mbox0=0x{x})\n", .{ e, flcn.rd(falcon.Reg.MAILBOX0) });
        return e;
    };
    log("gpu.gsp: GSP_INIT_DONE received — GSP-RM is up\n", .{});

    const g = Gsp{
        .regs = regs,
        .flcn = flcn,
        .sec2 = sec2,
        .shared = shared,
        .rx3 = rx3,
        .wpr_meta_phys = wpr_meta_phys,
        .libos_phys = libos.libos_phys,
        .app_version = boot_app_version,
        .running = true,
        .fb = fbl,
        .vbios = vb,
        .fwsec_desc_off = fwsec_loc.desc_offset,
        .booter_unload = fw.booter_unload,
        .dma = dma,
    };

    // Step 3: prove the RPC ring round-trips by sending GET_GSP_STATIC_INFO
    // (fn 65) and reading the GSP's reply. The reply carries the internal RM
    // client/device/subdevice handles we'll need for display allocation.
    staticInfo(g) catch |e| {
        log("gpu.gsp: GET_GSP_STATIC_INFO failed: {}\n", .{e});
        return e; // errdefer dma.freeAll() above releases the tracked buffers
    };

    return g;
}

/// Send GSP_SET_SYSTEM_INFO (fn 72): GPU BAR physical addresses, PCI BDF, config
/// mirror, chipset. The GSP RM needs these during init; absent, it faults (Xid
/// 62). Fire-and-forget (nouveau REPLY_NOSEQ — no reply waited). nouveau
/// r535_gsp_set_system_info.
fn setSystemInfo(flcn: falcon.Falcon, shared: msgq.Shared, dev: pci.Device) Error!void {
    var info = @import("std").mem.zeroes(gspfw.GspSystemInfo);
    info.gpuPhysAddr = pci.bar64(dev, 0); // BAR0 (registers)
    info.gpuPhysFbAddr = pci.bar64(dev, 1); // BAR1 (FB aperture)
    info.gpuPhysInstAddr = pci.bar64(dev, 3); // BAR3 (instance / "BAR2")
    info.nvDomainBusDeviceFunc = (@as(u64, dev.bus) << 8) | (@as(u64, dev.slot) << 3) | dev.func;
    info.maxUserVa = 0x00007ffffffff000; // TASK_SIZE (x86-64 user VA top)
    info.pciConfigMirrorBase = 0x88000; // NVIDIA PCI config mirror in BAR0
    info.pciConfigMirrorSize = 0x1000;
    // r570 fields: PCI IDs from config space, chipset, primary flag.
    const id = dev.read32(0x00); // vendor (low 16) | device (high 16)
    const sub = dev.read32(0x2c); // subsys vendor (low) | subsys device (high)
    const rev = dev.read32(0x08) & 0xff; // revision id (class reg low byte)
    info.PCIDeviceID = id; // (device<<16)|vendor — config 0x00 is already that order
    info.PCISubDeviceID = sub;
    info.PCIRevisionID = rev;
    info.bIsPrimary = 0; // headless passthrough — not the primary VGA
    // NB: nouveau leaves Chipset=0 and hostPageSize=0 in this RPC (verified by
    // byte-diff of its debug=trace fn:72 dump) — the GSP derives them. Do NOT set
    // them, or our payload diverges from the known-good bytes.
    // Match nouveau's ACPI block byte-for-byte: bValid=1 with each method's
    // status = 0xffff (NV_ERR — method not present). nouveau sets bValid whenever
    // it has an ACPI handle (the QEMU VM does); the probes then fail to 0xffff.
    info.acpiMethodData.bValid = 1;
    info.acpiMethodData.dod.status = 0xffff;
    info.acpiMethodData.jt.status = 0xffff;
    info.acpiMethodData.caps.status = 0xffff;
    const bytes: [*]const u8 = @ptrCast(&info);
    try msgq.cmdqSend(flcn, shared, gspfw.GSP_SET_SYSTEM_INFO, bytes[0..@sizeOf(gspfw.GspSystemInfo)]);
}

/// Send SET_REGISTRY (fn 73) with nouveau's three required DWORD entries. The
/// packed table is: header {size,numEntries}, then numEntries × 16-byte
/// PACKED_REGISTRY_ENTRY {nameOffset,type,data,length}, then the null-terminated
/// key strings appended (nameOffset points at each). nouveau r535_gsp_rpc_set_registry
/// + build_registry. DWORD entries: type=1, data=value, length=4.
fn setRegistry(flcn: falcon.Falcon, shared: msgq.Shared) Error!void {
    const keys = [_][]const u8{ "RMSecBusResetEnable", "RMForcePcieConfigSave", "RMDevidCheckIgnore" };
    const n = keys.len;
    var buf = [_]u8{0} ** 256;
    const hdr_size: usize = 8; // size + numEntries
    const ent_size: usize = 16; // PACKED_REGISTRY_ENTRY (natural alignment)
    var str_off: usize = hdr_size + n * ent_size;

    const wr32 = struct {
        /// Write a little-endian u32 `v` into the registry-table buffer `b` at `o`.
        fn f(b: []u8, o: usize, v: u32) void {
            b[o] = @truncate(v);
            b[o + 1] = @truncate(v >> 8);
            b[o + 2] = @truncate(v >> 16);
            b[o + 3] = @truncate(v >> 24);
        }
    }.f;

    wr32(&buf, 4, n); // numEntries
    for (keys, 0..) |key, i| {
        const eo = hdr_size + i * ent_size;
        wr32(&buf, eo + 0, @intCast(str_off)); // nameOffset
        buf[eo + 4] = 1; // type = DWORD
        wr32(&buf, eo + 8, 1); // data = 1
        wr32(&buf, eo + 12, 4); // length = sizeof(u32)
        @memcpy(buf[str_off .. str_off + key.len], key);
        buf[str_off + key.len] = 0; // null terminator
        str_off += key.len + 1;
    }
    wr32(&buf, 0, @intCast(str_off)); // total size

    try msgq.cmdqSend(flcn, shared, gspfw.SET_REGISTRY, buf[0..str_off]);
}

/// NV_VGPU_MSG_FUNCTION_GET_GSP_STATIC_INFO (rpcfn.h #65). Request payload is a
/// zeroed GspStaticConfigInfo the GSP fills and returns. nouveau trace shows
/// rpc fn:65 len:0x698 (payload 0x678) — fits one page. Send generously sized.
const GET_GSP_STATIC_INFO: u32 = 65;
// nouveau sends exactly 0x678 (1656) bytes for this RPC (trace: rpc fn:65
// len:0x698/0x678). With the 80-byte element+rpc headers that's one page, so
// match it — a single-page request avoids the multi-page send path for this probe.
const STATIC_INFO_SIZE: usize = 0x678;

/// Send GET_GSP_STATIC_INFO and wait for the reply; log proof-of-life fields.
fn staticInfo(g: Gsp) Error!void {
    var payload = [_]u8{0} ** STATIC_INFO_SIZE;
    try msgq.cmdqSend(g.flcn, g.shared, GET_GSP_STATIC_INFO, payload[0..]);
    // Wait for the fn=65 reply on the status queue; the reply is copied back into
    // the same ring slot, so poll surfaces it. Log the reply's RPC result.
    const reply = try msgq.recvReply(g.flcn, g.sec2, g.regs, g.shared, g.libos_phys, g.app_version, GET_GSP_STATIC_INFO);
    log("gpu.gsp: GET_GSP_STATIC_INFO reply: result=0x{x} len={} (GSP RPC round-trip OK)\n", .{ reply.result, reply.len });
    _ = std;
}

/// Submit one RPC on the command queue and wait for its reply on the status
/// queue. The send path lives in msgq.zig (cmdqSend + recvReply); this is the
/// public entry other gpu modules (display) use.
pub fn rpc(g: Gsp, function: u32, payload: []const u8) Error!msgq.Reply {
    try msgq.cmdqSend(g.flcn, g.shared, function, payload);
    return msgq.recvReply(g.flcn, g.sec2, g.regs, g.shared, g.libos_phys, g.app_version, function);
}

/// Like rpc, but the reply wait carries a wall-clock budget — for callers with
/// their own deadline (teardown), where a GSP diagnostic flood must not hold
/// the drain hostage (msgq.recvReplyBudget has the full story).
fn rpcBudget(g: Gsp, function: u32, payload: []const u8, budget_ms: u64) Error!msgq.Reply {
    try msgq.cmdqSend(g.flcn, g.shared, function, payload);
    return msgq.recvReplyBudget(g.flcn, g.sec2, g.regs, g.shared, g.libos_phys, g.app_version, function, budget_ms);
}

/// NV_VGPU_MSG_FUNCTION_UNLOADING_GUEST_DRIVER (rpcfn.h: RM fn 47).
const UNLOADING_GUEST_DRIVER: u32 = 47;

/// How long shutdown waits for the UNLOADING_GUEST_DRIVER reply before
/// proceeding to the falcon reset. The reply normally arrives in well under a
/// second; a GSP spewing queued Xid/NOCAT records can push it out — or never
/// send it — and the teardown's own callers (the test harness kills the
/// machine at 60 s) must see the storage flush regardless, so the wait is
/// bounded far inside that.
const UNLOAD_REPLY_BUDGET_MS: u64 = 10_000;
/// rpc_unloading_guest_driver_v1F_07 (r535 nvrm/gsp.h:220): bInPMTransition(u8),
/// bGc6Entering(u8), newLevel(u32). Non-suspend teardown = all zero (newLevel =
/// NV2080_CTRL_GPU_SET_POWER_STATE_GPU_LEVEL_0 = 0).
const UnloadingGuestDriverParams = extern struct {
    bInPMTransition: u8 = 0,
    bGc6Entering: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    newLevel: u32 = 0,
};

/// Tear the GSP down so the NEXT booter_load can re-establish WPR2 from a clean
/// state. Without this kudos leaves WPR2 locked + the GSP-RM running, and the next
/// boot faults with Xid 62 (only a host power-off otherwise clears it). Mirrors
/// nouveau tu102_gsp_fini → ad102 uses tu102_gsp_fini (gsp/tu102.c, rm/r535/gsp.c):
///   1. UNLOADING_GUEST_DRIVER RPC (graceful GSP-RM unload); wait GSP falcon
///      0x040 == 0x80000000.
///   2. reset the GSP falcon.
///   3. FWSEC-SB (re-secure the falcon for the unload booter).
///   4. booter_unload on SEC2 (mbox 0xff/0xff): tears down WPR2; verify 0x1fa828==0.
/// Steps 1-3 are best-effort + logged: a stuck GSP must not block the WPR2
/// teardown (step 4 is the load-bearing one). Step 4 IS surfaced: a failed
/// booter_unload leaves WPR2 locked and poisons the next boot (Xid 62), so the
/// return status reflects whether WPR2 ended up clear. Frees every tracked DMA
/// buffer on every exit path so a re-run doesn't leak PMM.
pub fn shutdown(g: Gsp) shim.Status {
    var gm = g;
    defer gm.dma.freeAll();
    log("gpu.gsp: shutdown START t={}ms\n", .{timer.millis()});

    // 1. Graceful GSP-RM unload (r535_gsp_fini, suspend=false), reply wait
    //    bounded: a diagnostic flood must not stall the teardown past the
    //    budgets of everything waiting on it.
    var up = UnloadingGuestDriverParams{};
    if (rpcBudget(g, UNLOADING_GUEST_DRIVER, std.mem.asBytes(&up), UNLOAD_REPLY_BUDGET_MS)) |_| {
        // Wait for the GSP falcon to quiesce (nvkm_msec 2000: reg 0x040 == 0x80000000).
        var spins: u32 = 0;
        while (spins < 2000) : (spins += 1) {
            if (g.flcn.rd(0x040) == 0x80000000) break;
            shim.delayUs(1000);
        }
        log("gpu.gsp: UNLOADING_GUEST_DRIVER ok, gsp[0x040]=0x{x} after {} spins\n", .{ g.flcn.rd(0x040), spins });
    } else |e| {
        log("gpu.gsp: UNLOADING_GUEST_DRIVER RPC failed: {} (continuing teardown)\n", .{e});
    }

    // 2. Reset the GSP falcon (nvkm_falcon_reset).
    falcon.reset(g.flcn) catch |e| log("gpu.gsp: GSP falcon reset failed: {} (continuing)\n", .{e});

    // 3. FWSEC-SB — re-run FWSEC in secure-boot mode so the unload booter can run.
    fwsec.run(.sb, g.regs, g.vbios, g.fwsec_desc_off, 0, 0) catch |e|
        log("gpu.gsp: FWSEC-SB failed: {} (continuing to booter_unload)\n", .{e});

    // 4. booter_unload on SEC2 (mbox0=mbox1=0xff) — tears down WPR2. Skip if WPR2
    //    is already clear (tu102_gsp_booter_unload: 0x1fa828==0 → nothing to do).
    const wpr2_hi_pre = g.regs.read32(fblayout.WPR2_HI_REG);
    if (wpr2_hi_pre == 0) {
        log("gpu.gsp: WPR2 already clear (0x1fa828=0) — skipping booter_unload\n", .{});
        return .ok;
    }
    falcon.loadAndBoot(g.sec2, g.regs, "booter_unload", g.booter_unload, 0xff, 0xff) catch |e| {
        log("gpu.gsp: booter_unload failed: {} — WPR2 still locked, next boot will Xid 62\n", .{e});
        return .err_invalid_state;
    };
    const wpr2_hi_post = g.regs.read32(fblayout.WPR2_HI_REG);
    log("gpu.gsp: booter_unload OK; WPR2-hi 0x{x} -> 0x{x} (0 = torn down) t={}ms\n", .{ wpr2_hi_pre, wpr2_hi_post, timer.millis() });
    // booter_unload can return success yet leave WPR2 standing — the only proof
    // the next boot won't Xid 62 is WPR2-hi reading 0.
    if (wpr2_hi_post != 0) {
        log("gpu.gsp: booter_unload ran but WPR2 still locked (0x{x}) — next boot will Xid 62\n", .{wpr2_hi_post});
        return .err_invalid_state;
    }
    return .ok;
}
