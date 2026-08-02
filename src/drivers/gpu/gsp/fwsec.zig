//! FWSEC-FRTS: run the VBIOS-resident FWSEC ucode with the FRTS command to set
//! up the FRTS region in WPR2 — a precondition for the GSP booter (nouveau
//! fwsec.c, gsp/tu102.c nvkm_gsp_fwsec_frts). FWSEC runs on the GSP falcon and
//! is signed against the VBIOS (not the firmware package).
//!
//! Flow (nvkm_gsp_fwsec_v3 + _patch + _boot):
//!   parse the v3 ucode desc in the VBIOS -> copy IMEM+DMEM image to a writable
//!   buffer -> patch the FRTS command into the DMEM interface (DMEMMAPPER app)
//!   -> patch the VBIOS production signature -> falcon load+boot on the GSP
//!   falcon -> verify (rd32(0x001400 + 0xe*4)>>16 == 0, wpr2_hi nonzero).
//!
//! All structures are byte-exact from nouveau fwsec.c (see resources).

const mmio = @import("../base/mmio.zig");
const log = @import("../base/log.zig").gpu;
const shim = @import("../base/shim.zig");
const falcon = @import("falcon.zig");
const vbios = @import("vbios.zig");

pub const Error = error{
    FwsecDescBad,
    FwsecNoDmemMapper,
    FwsecAlloc,
    FwsecBootTimeout,
    FwsecFrtsFailed,
    FwsecSigNoEngine, // signature-select: engine 0x400 bit absent
    FwsecSigVersionMismatch, // fuse version does not match any firmware signature
};

const CMD_FRTS: u32 = 0x15; // NVFW_FALCON_APPIF_DMEMMAPPER_CMD_FRTS
const CMD_SB: u32 = 0x19; // NVFW_FALCON_APPIF_DMEMMAPPER_CMD_SB (fwsec.c:61)
const APPIF_ID_DMEMMAPPER: u32 = 0x04;
const FRTS_REGION_TYPE_FB: u32 = 0x02;

/// FWSEC run mode: FRTS provisions the WPR2 FRTS region at boot; SB is the
/// "secure boot" sub-command nouveau runs at teardown (tu102_gsp_fini) between
/// the falcon reset and booter_unload. SB patches only read_vbios (no frts_region)
/// and verifies a different scratch reg.
pub const Mode = enum { frts, sb };

/// nvkm_falcon_ucode_desc_v3 (fwsec.c) — the FWSEC ucode descriptor in the VBIOS.
pub const UcodeDescV3 = extern struct {
    Hdr: u32,
    StoredSize: u32,
    PKCDataOffset: u32,
    InterfaceOffset: u32,
    IMEMPhysBase: u32,
    IMEMLoadSize: u32,
    IMEMVirtBase: u32,
    DMEMPhysBase: u32,
    DMEMLoadSize: u32,
    EngineIdMask: u16,
    UcodeId: u8,
    SignatureCount: u8,
    SignatureVersions: u16,
    Reserved: u16,
};

/// Run the VBIOS-resident FWSEC ucode in `mode`. FRTS (boot) provisions the WPR2
/// FRTS region (`frts_addr`/`frts_size`); SB (teardown) ignores those. `regs` =
/// BAR0, `vb` = the read VBIOS, `desc_off` = the FWSEC desc offset (vbios.findFwsec).
pub fn run(mode: Mode, regs: mmio.Mapping, vb: vbios.Vbios, desc_off: u32, frts_addr: u64, frts_size: u64) Error!void {
    // The v3 desc is at desc_off (pointer-space); the ucode image (IMEM+DMEM)
    // follows it at desc_off + StoredSize-ish. nouveau: ucode = (u8*)desc + size,
    // where `size` is the desc size from the PMU entry header. The desc Hdr low
    // byte bit0 must be set; size = (Hdr>>16)&0xffff, vers = (Hdr>>8)&0xff.
    const hdr = vb.rd32(desc_off);
    if ((hdr & 0x1) == 0) return error.FwsecDescBad;
    const size = (hdr >> 16) & 0xffff;
    const vers = (hdr >> 8) & 0xff;
    if (vers != 3) {
        log("gpu.fwsec: desc version {} unsupported (need v3)\n", .{vers});
        return error.FwsecDescBad;
    }

    // Read the v3 desc fields (via translated VBIOS reads).
    const imem_phys = vb.rd32(desc_off + 16); // IMEMPhysBase
    const imem_size = vb.rd32(desc_off + 20); // IMEMLoadSize
    const dmem_phys = vb.rd32(desc_off + 28); // DMEMPhysBase
    const dmem_size = vb.rd32(desc_off + 32); // DMEMLoadSize
    const pkc_off = vb.rd32(desc_off + 8); // PKCDataOffset
    const if_off = vb.rd32(desc_off + 12); // InterfaceOffset
    // Allocate with 256-aligned segment sizes (DMA reads aligned-up lengths).
    const ucode_total = ((imem_size + 255) & ~@as(u32, 255)) + ((dmem_size + 255) & ~@as(u32, 255));
    log("gpu.fwsec: v3 desc size={} imem(phys=0x{x} sz={}) dmem(phys=0x{x} sz={}) pkc=0x{x} if=0x{x}\n", .{ size, imem_phys, imem_size, dmem_phys, dmem_size, pkc_off, if_off });

    // Copy the ucode image (at desc_off + size) to a writable, identity-mapped
    // buffer so we can patch the FRTS command + signature into its DMEM.
    const pages = (ucode_total + 0xfff) / 0x1000;
    const img_phys = shim.allocPagesPhys(pages) orelse return error.FwsecAlloc;
    // DMA'd into the GSP falcon below and dead thereafter — free on every exit so
    // repeated FWSEC runs (FRTS at boot, SB at teardown) don't leak the copy.
    defer shim.freePagesPhys(img_phys, pages);
    const img: [*]u8 = @ptrFromInt(img_phys);
    const ucode_start = desc_off + size;
    var i: u32 = 0;
    while (i < ucode_total) : (i += 1) img[i] = vb.rd8(ucode_start + i);

    // Patch the FRTS command into the DMEM interface (nvkm_gsp_fwsec_patch).
    // The DMEM image starts at offset imem_size within the copy (dmem follows
    // imem). The appif header is at dmem + if_off.
    const dmem = img + imem_size;
    try patchCmd(mode, dmem, if_off, frts_addr, frts_size);

    // Patch the VBIOS production signature into the image at pkc_off (within
    // DMEM). nvkm_gsp_fwsec_v3: sig_size = 96*4 = 384, sigs at the VBIOS base,
    // the signature array is at desc+0x2c (count = SignatureCount), selected by
    // fuse (ga102_gsp_fwsec_signature, engine 0x400 -> fuse 0x8241c0).
    // v3 desc: 9 u32 (0..35), then EngineIdMask u16@36, UcodeId u8@38,
    // SignatureCount u8@39, SignatureVersions u16@40.
    const engine_mask = vb.rd16(desc_off + 36);
    const ucode_id = vb.rd8(desc_off + 38);
    const sig_count = vb.rd8(desc_off + 39);
    const fuse_ver = vb.rd16(desc_off + 40);
    const sig_idx = try selectFwsecSig(regs, engine_mask, ucode_id, fuse_ver, sig_count);
    const sig_size: u32 = 96 * 4;
    const sig_arr = desc_off + 0x2c; // signature array (VBIOS pointer-space)
    const sig_src = sig_arr + sig_idx * sig_size;
    // Copy 384 bytes from the VBIOS signature into the DMEM image at pkc_off.
    var s: u32 = 0;
    while (s < sig_size) : (s += 1) dmem[pkc_off + s] = vb.rd8(sig_src + s);
    log("gpu.fwsec: sig idx={} (count={}) patched @dmem+0x{x}\n", .{ sig_idx, sig_count, pkc_off });

    // Range clflush, never wbinvd: a full cache writeback with the GPU BAR
    // mapped costs seconds and would stall GSP init.
    shim.flushRange(img_phys, ucode_total); // make the patched image visible to DMA

    // Load + boot FWSEC on the GSP falcon. IMEM <- [0,imem_size), DMEM <-
    // [imem_size, +dmem_size), both from img_phys. dmem_sign = pkc_off.
    const flcn = falcon.gsp(regs);
    falcon.enable(flcn) catch return error.FwsecBootTimeout;
    falcon.loadPreamble(flcn);
    // nouveau ga102_flcn_fw_load (falcon/ga102.c): IMEM transfer uses the RAW
    // imem_size (only DMEM is ALIGNed to 256), IMEM sec=true, **DMEM sec=false**.
    // Both details matter and neither is guessable: rounding IMEM up, or marking the
    // DMEM load secure, mis-provisions the firmware's reserved region. Nothing fails at
    // the time — the PMU faults later (Xid 62), far from the cause.
    const dmem_a = (dmem_size + 255) & ~@as(u32, 255);
    falcon.dmaWrite(flcn, img_phys, 0, imem_phys, imem_size, true, true) catch return error.FwsecBootTimeout;
    falcon.dmaWrite(flcn, img_phys, imem_size, dmem_phys, dmem_a, false, false) catch return error.FwsecBootTimeout;
    const fwsec_m0 = falcon.bootAndWait(flcn, pkc_off, engine_mask, ucode_id, 0, 0) catch |e| {
        log("gpu.fwsec: FWSEC boot did not halt: {}\n", .{e});
        return error.FwsecBootTimeout;
    };
    if (fwsec_m0 != 0) {
        log("gpu.fwsec: FWSEC returned error mbox0=0x{x}\n", .{fwsec_m0});
        return error.FwsecFrtsFailed;
    }

    switch (mode) {
        .frts => {
            // nvkm_gsp_fwsec_frts: scratch 0x001400 + 0xe*4, error in bits[31:16];
            // success leaves WPR2 hi (0x1fa828) nonzero.
            const err = regs.read32(0x001400 + 0xe * 4) >> 16;
            const wpr2_hi = regs.read32(0x1fa828);
            const wpr2_lo = regs.read32(0x1fa824);
            log("gpu.fwsec: FRTS done err=0x{x} wpr2=0x{x}..0x{x}\n", .{ err, wpr2_lo, wpr2_hi });
            if (err != 0 or wpr2_hi == 0) return error.FwsecFrtsFailed;
            log("gpu.fwsec: FRTS OK t={}ms\n", .{@import("../../../kernel/timer/timer.zig").millis()});
        },
        .sb => {
            // nvkm_gsp_fwsec_sb: scratch 0x001400 + 0x15*4, error in bits[15:0].
            const err = regs.read32(0x001400 + 0x15 * 4) & 0xffff;
            log("gpu.fwsec: SB done err=0x{x}\n", .{err});
            if (err != 0) return error.FwsecFrtsFailed;
        },
    }
}

/// FWSEC signature selection (ga102_gsp_fwsec_signature). For engine 0x400 the fuse
/// version is BIT(fls(reg)) read from 0x8241c0 + (ucode_id-1)*4; the matching
/// signature index is the count of set sig-version bits below it. Fails loud (no
/// silent fallback to the last sig) when the engine bit is absent or the fuse
/// version does not match the firmware's — mirroring nouveau's -EINVAL, so a
/// version mismatch surfaces here instead of a later BROM/mbox0 error from a
/// wrongly-patched signature.
fn selectFwsecSig(regs: mmio.Mapping, engine_mask: u16, ucode_id: u8, fuse_ver: u16, sig_count: u8) Error!u32 {
    _ = sig_count;
    if (engine_mask & 0x400 == 0) return error.FwsecSigNoEngine;
    const reg = regs.read32(0x8241c0 + (@as(u64, ucode_id) - 1) * 4);
    // reg_fuse_version = BIT(fls(reg)); fls(0)=0 -> BIT(0)=1 (nouveau does not special
    // -case reg==0). A version the firmware does not carry is a hard mismatch.
    const rfv0: u32 = if (reg == 0) 1 else @as(u32, 1) << @intCast(32 - @clz(reg));
    if ((rfv0 & fuse_ver) == 0) return error.FwsecSigVersionMismatch;
    // idx = count of set sig-version bits below the matching bit.
    var rfv: u32 = rfv0;
    var sfv: u32 = fuse_ver;
    var idx: u32 = 0;
    while ((rfv & sfv & 1) == 0 and (rfv != 0)) {
        idx += (sfv & 1);
        rfv >>= 1;
        sfv >>= 1;
    }
    return idx;
}

/// Patch the FWSEC command into the DMEM interface (nvkm_gsp_fwsec_patch). Both
/// modes set init_cmd + read_vbios; only FRTS also writes the frts_region block.
/// `dmem` points at the start of the DMEM image; `if_off` is InterfaceOffset.
fn patchCmd(mode: Mode, dmem: [*]u8, if_off: u32, frts_addr: u64, frts_size: u64) Error!void {
    // Little-endian dword accessors into the writable DMEM image copy.
    const rd32 = struct {
        /// Read a little-endian u32 from DMEM buffer `p` at offset `o`.
        fn f(p: [*]u8, o: u32) u32 {
            return @as(u32, p[o]) | (@as(u32, p[o + 1]) << 8) | (@as(u32, p[o + 2]) << 16) | (@as(u32, p[o + 3]) << 24);
        }
    }.f;
    const wr32 = struct {
        /// Write a little-endian u32 `v` into DMEM buffer `p` at offset `o`.
        fn f(p: [*]u8, o: u32, v: u32) void {
            p[o] = @truncate(v);
            p[o + 1] = @truncate(v >> 8);
            p[o + 2] = @truncate(v >> 16);
            p[o + 3] = @truncate(v >> 24);
        }
    }.f;

    // appif header (union nvfw_falcon_appif_hdr v1): ver(u8) at +0 must be 1;
    // hdr(u8)@+1, len(u8)@+2, cnt(u8)@+3. Located at dmem + if_off.
    if (dmem[if_off] != 1) return error.FwsecDescBad;
    const ah_hdr = dmem[if_off + 1];
    const ah_len = dmem[if_off + 2];
    const ah_cnt = dmem[if_off + 3];

    var i: u32 = 0;
    while (i < ah_cnt) : (i += 1) {
        const app = if_off + ah_hdr + i * ah_len;
        // appif v1: id(u32)@+0, dmem_base(u32)@+4.
        const id = rd32(dmem, app);
        if (id != APPIF_ID_DMEMMAPPER) continue;
        const dmem_base = rd32(dmem, app + 4);

        // dmemmapper v3: init_cmd@+0x2c, cmd_in_buffer_offset@+0x08.
        wr32(dmem, dmem_base + 0x2c, if (mode == .frts) CMD_FRTS else CMD_SB); // init_cmd
        const cmd_in = rd32(dmem, dmem_base + 0x08); // cmd_in_buffer_offset

        // read_vbios{ver,hdr,addr(u64),size,flags} (both modes).
        wr32(dmem, cmd_in + 0x00, 1); // read_vbios.ver
        wr32(dmem, cmd_in + 0x04, 24); // read_vbios.hdr = sizeof(read_vbios)
        wr32(dmem, cmd_in + 0x08, 0); // read_vbios.addr lo
        wr32(dmem, cmd_in + 0x0c, 0); // read_vbios.addr hi
        wr32(dmem, cmd_in + 0x10, 0); // read_vbios.size
        wr32(dmem, cmd_in + 0x14, 2); // read_vbios.flags
        // frts_region at cmd_in + 24 — FRTS only (nvkm_gsp_fwsec_patch skips it for SB).
        if (mode == .frts) {
            const fr = cmd_in + 24;
            wr32(dmem, fr + 0x00, 1); // ver
            wr32(dmem, fr + 0x04, 20); // hdr = sizeof(frts_region)
            wr32(dmem, fr + 0x08, @intCast(frts_addr >> 12)); // addr (4KB units)
            wr32(dmem, fr + 0x0c, @intCast(frts_size >> 12)); // size (4KB units)
            wr32(dmem, fr + 0x10, FRTS_REGION_TYPE_FB); // type
        }
        log("gpu.fwsec: patched {s} into dmemmapper @0x{x}\n", .{ @tagName(mode), dmem_base });
        return;
    }
    return error.FwsecNoDmemMapper;
}
