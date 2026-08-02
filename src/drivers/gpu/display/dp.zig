//! DisplayPort SST link-up over the booted GSP-RM (AD102, r570 firmware).
//!
//! Ports the minimal mode-set preamble from nouveau:
//! the GSP-RM auto-trains the link inside DP_CTRL, so kudos only (a) reads which
//! SOR drives the display, (b) reads GPU link caps, (c) issues DP_CTRL to pick
//! lane-count/bandwidth and trigger CR+EQ training, then (d) programs the stream
//! watermark via DP_CONFIG_STREAM. No manual TPS pattern toggling.
//!
//! All ctrls run on the NV04_DISPLAY_COMMON objcom (handle nvrm.RM_DISP =
//! 0x00730000) via rm.control, which copies the GSP's reply params back in place.
//!
//! The param structs below are byte-exact `extern struct` mirrors of NVIDIA's
//! r570 nvrm headers (NvBool == u8, NvU64 8-aligned). The C layouts (incl. the
//! struct-internal padding) are reproduced exactly and guarded by comptime
//! @sizeOf/@offsetOf asserts. Sources:
//!   - OR_GET_INFO / DFP_ASSIGN_SOR / DP_CTRL flag+data fields:
//!     nvkm/subdev/gsp/rm/r535/nvrm/disp.h  (identical numbers in r570)
//!   - DP_GET_CAPS / DP_CONFIG_STREAM:
//!     nvkm/subdev/gsp/rm/r570/nvrm/disp.h
//!   - watermark/hBlankSym/vBlankSym math: nv50_sor_dp_watermark_sst,
//!     dispnv50/disp.c:1607-1740 (cited inline at each constant).

const std = @import("std");
const log = @import("../base/log.zig").gpu;
const rm = @import("../gsp/rm.zig");
const nvrm = @import("../base/nvrm.zig");
const gsp = @import("../gsp/gsp.zig");
const shim = @import("../base/shim.zig");

pub const Error = error{
    DpNoSor, // DFP_ASSIGN_SOR returned no SOR for this displayId
    DpTrainFailed, // DP_CTRL reported err != 0 after all retries
    DpWatermarkInvalid, // nv50_sor_dp_watermark_sst rejected the mode (would HW-hang)
    DpNotDisplayPort, // OR_GET_INFO protocol is not SOR DP_A/DP_B
    DpAuxBadLen, // native AUX write length outside 1..AUXCH_MAX_DATA
} || rm.Error;

// ── Mode geometry (caller-supplied) ────────────────────────────────────────────
// Fields chosen to feed the watermark math directly. `h`/`v` are the *active*
// pixel counts; `h_blank`/`h_sync_w` describe the horizontal blanking so the total
// raster width is `h + h_blank`. Pixel clock is in kHz (matches asyh->mode.clock).
// Single source of truth: the full mode descriptor lives in disp.zig. The SST
// watermark math here reads only h/v/clock_khz/h_blank; the extra disp.Mode fields
// (sync widths, polarity) carry defaults and are harmless.
pub const Mode = @import("disp.zig").Mode;

pub const DpLink = struct {
    sor_id: u32,
    protocol: u32, // NV0073 OR protocol: DP_A=8, DP_B=9
    sublink: u32, // 1 for DP_A, 2 for DP_B (dpLink = sublink==2)
    link_bw: u8, // DP_CTRL bw byte actually used (0x06/0x0a/0x14/0x1e)
    lane_count: u32, // lanes actually used (4)
    trained: bool, // DP_CTRL err == 0
    // Watermark/blanking for the deferred CONFIG_STREAM (after the EVO SOR push).
    waterMark: u32,
    hBlankSym: u32,
    vBlankSym: u32,
    enhanced_framing: bool,
};

// ── NV0073 ctrl command numbers (r535==r570 for these) ───────────────────────────
const CTRL_SPECIFIC_OR_GET_INFO: u32 = 0x73028b;
const CTRL_DP_GET_CAPS: u32 = 0x731369;
const CTRL_DFP_ASSIGN_SOR: u32 = nvrm.CTRL_DFP_ASSIGN_SOR; // 0x731152
const CTRL_DP_CTRL: u32 = nvrm.CTRL_DP_CTRL; // 0x731343
const CTRL_DP_CONFIG_STREAM: u32 = 0x731362;

// ── OR protocol values (r535/nvrm/disp.h:114-115) ───────────────────────────────
const OR_TYPE_SOR: u32 = 0x2;
const OR_PROTOCOL_SOR_DP_A: u32 = 0x8;
const OR_PROTOCOL_SOR_DP_B: u32 = 0x9;

// ── DP_GET_CAPS maxLinkRate decode (r535/nvrm/disp.h:92-97) ──────────────────────
// maxLinkRate enum → DP_CTRL data bw byte.
pub const MAX_LINK_RATE_1_62: u32 = 0x1;
pub const MAX_LINK_RATE_2_70: u32 = 0x2;
pub const MAX_LINK_RATE_5_40: u32 = 0x3;
pub const MAX_LINK_RATE_8_10: u32 = 0x4;

// DP_CTRL `data` SET_LINK_BW byte values (r535/nvrm/disp.h:577-584).
pub const BW_1_62: u8 = 0x06;
pub const BW_2_70: u8 = 0x0a;
pub const BW_5_40: u8 = 0x14;
pub const BW_8_10: u8 = 0x1e;

// ── DP_CTRL `cmd` bit positions (r535/nvrm/disp.h:500-537) ───────────────────────
const DP_CMD_SET_LANE_COUNT: u32 = 1 << 0; // bit0
const DP_CMD_SET_LINK_BW: u32 = 1 << 1; // bit1
const DP_CMD_SET_ENHANCED_FRAMING: u32 = 1 << 7; // bit7
const DP_CMD_TRAIN_PHY_REPEATER: u32 = 1 << 13; // bit13

// ── DP_CTRL `data` bit-field shifts (r535/nvrm/disp.h:570-593) ───────────────────
const DP_DATA_LANE_COUNT_SHIFT: u5 = 0; // bits 4:0
const DP_DATA_LINK_BW_SHIFT: u5 = 8; // bits 15:8
const DP_DATA_ENHANCED_FRAMING: u32 = 1 << 18; // bit18
const DP_DATA_TARGET_SHIFT: u5 = 19; // bits 22:19, 0 == sink

// ── Param structs (byte-exact extern-struct mirrors) ─────────────────────────────

// NV0073_CTRL_SPECIFIC_OR_GET_INFO_PARAMS (r535/nvrm/disp.h:87-101).
// 10×NvU32 (40) + NvU64 vbiosAddress @40 + 2×NvBool, tail-padded to 8 → 56.
const OrGetInfoParams = extern struct {
    subDeviceInstance: u32,
    displayId: u32,
    index: u32, // OUT: SOR id
    type: u32, // OUT: OR_TYPE_SOR == 2
    protocol: u32, // OUT: DP_A==8 / DP_B==9
    ditherType: u32,
    ditherAlgo: u32,
    location: u32,
    rootPortId: u32,
    dcbIndex: u32,
    vbiosAddress: u64 align(8),
    bIsLitByVbios: u8,
    bIsDispDynamic: u8,
};
comptime {
    std.debug.assert(@sizeOf(OrGetInfoParams) == 56);
    std.debug.assert(@offsetOf(OrGetInfoParams, "vbiosAddress") == 40);
    std.debug.assert(@offsetOf(OrGetInfoParams, "protocol") == 16);
}

// NV0073_CTRL_CMD_DSC_CAP_PARAMS (r570/nvrm/disp.h:51-59).
// NvBool (1) + pad(3) + 6×NvU32 → 28.
const DscCapParams = extern struct {
    bDscSupported: u8,
    encoderColorFormatMask: u32 align(4),
    lineBufferSizeKB: u32,
    rateBufferSizeKB: u32,
    bitsPerPixelPrecision: u32,
    maxNumHztSlices: u32,
    lineBufferBitDepth: u32,
};
comptime {
    std.debug.assert(@sizeOf(DscCapParams) == 28);
    std.debug.assert(@offsetOf(DscCapParams, "encoderColorFormatMask") == 4);
}

// NV0073_CTRL_CMD_DP_GET_CAPS_PARAMS (r570/nvrm/disp.h:61-79).
// 6×NvU32 (24) + 10×NvBool (10) → pad to 36 → DSC (28) → 64.
const DpGetCapsParams = extern struct {
    subDeviceInstance: u32,
    sorIndex: u32,
    maxLinkRate: u32, // OUT
    dpVersionsSupported: u32,
    UHBRSupportedByGpu: u32,
    minPClkForCompressed: u32,
    bIsMultistreamSupported: u8,
    bIsSCEnabled: u8,
    bHasIncreasedWatermarkLimits: u8, // OUT
    bIsPC2Disabled: u8,
    isSingleHeadMSTSupported: u8,
    bFECSupported: u8,
    bIsTrainPhyRepeater: u8,
    bOverrideLinkBw: u8,
    bUseRgFlushSequence: u8,
    bSupportDPDownSpread: u8,
    DSC: DscCapParams align(4),
};
comptime {
    std.debug.assert(@sizeOf(DpGetCapsParams) == 64);
    std.debug.assert(@offsetOf(DpGetCapsParams, "bHasIncreasedWatermarkLimits") == 26);
    std.debug.assert(@offsetOf(DpGetCapsParams, "DSC") == 36);
}

// NV0073_CTRL_DFP_ASSIGN_SOR_INFO (r535/nvrm/disp.h:281-284).
const DfpAssignSorInfo = extern struct {
    displayMask: u32,
    sorType: u32,
};
comptime {
    std.debug.assert(@sizeOf(DfpAssignSorInfo) == 8);
}

// NV0073_CTRL_DFP_ASSIGN_SOR_PARAMS (r535/nvrm/disp.h:289-300).
// subDeviceInstance(0) displayId(4) sorExcludeMask u8(8)→pad→ slaveDisplayId(12)
// forceSublinkConfig(16) bIs2Head1Or u8(20)→pad→ sorAssignList[4](24..40)
// sorAssignListWithTag[4]{u32,u32}(40..72) reservedSorMask u8(72)→pad→ flags(76) → 80.
const DfpAssignSorParams = extern struct {
    subDeviceInstance: u32,
    displayId: u32,
    sorExcludeMask: u8,
    slaveDisplayId: u32 align(4),
    forceSublinkConfig: u32,
    bIs2Head1Or: u8,
    sorAssignList: [4]u32 align(4),
    sorAssignListWithTag: [4]DfpAssignSorInfo,
    reservedSorMask: u8,
    flags: u32 align(4),
};
comptime {
    std.debug.assert(@offsetOf(DfpAssignSorParams, "slaveDisplayId") == 12);
    std.debug.assert(@offsetOf(DfpAssignSorParams, "sorAssignList") == 24);
    std.debug.assert(@offsetOf(DfpAssignSorParams, "sorAssignListWithTag") == 40);
    std.debug.assert(@offsetOf(DfpAssignSorParams, "flags") == 76);
    std.debug.assert(@sizeOf(DfpAssignSorParams) == 80);
}

// NV0073_CTRL_DP_CTRL_PARAMS (r570/nvrm/disp.h:249-257) — 7×NvU32 → 28.
const DpCtrlParams = extern struct {
    subDeviceInstance: u32,
    displayId: u32,
    cmd: u32,
    data: u32,
    err: u32, // OUT
    retryTimeMs: u32, // OUT
    eightLaneDpcdBaseAddr: u32,
};
comptime {
    std.debug.assert(@sizeOf(DpCtrlParams) == 28);
}

// NV0073_CTRL_CMD_DP_CONFIG_STREAM_PARAMS (r570/nvrm/disp.h:259-289).
// MST sub-struct: slotStart..Timeslice (4×u32=16) sendACT u8→pad→
// singleHeadMSTPipeline(u32) bEnableAudioOverRightPanel u8→pad → 28.
// SST sub-struct: bEnhancedFraming u8→pad→ tuSize(u32) waterMark(u32)
// bEnableAudioOverRightPanel u8→pad → 16.
const DpConfigStreamMst = extern struct {
    slotStart: u32,
    slotEnd: u32,
    PBN: u32,
    Timeslice: u32,
    sendACT: u8,
    singleHeadMSTPipeline: u32 align(4),
    bEnableAudioOverRightPanel: u8,
};
comptime {
    std.debug.assert(@offsetOf(DpConfigStreamMst, "singleHeadMSTPipeline") == 20);
    std.debug.assert(@sizeOf(DpConfigStreamMst) == 28);
}
const DpConfigStreamSst = extern struct {
    bEnhancedFraming: u8,
    tuSize: u32 align(4),
    waterMark: u32,
    bEnableAudioOverRightPanel: u8,
};
comptime {
    std.debug.assert(@offsetOf(DpConfigStreamSst, "tuSize") == 4);
    std.debug.assert(@sizeOf(DpConfigStreamSst) == 16);
}

// NV0073_CTRL_DP_AUXCH_CTRL_PARAMS (r535/r570 nvrm/disp.h). Native AUX DPCD xfer.
const AUXCH_MAX_DATA: usize = 16;
const DpAuxchCtrlParams = extern struct {
    subDeviceInstance: u32,
    displayId: u32,
    bAddrOnly: u8,
    cmd: u32 align(4),
    addr: u32,
    data: [AUXCH_MAX_DATA]u8,
    size: u32 align(4),
    replyType: u32,
    retryTimeMs: u32,
};
// cmd for a native AUX write: TYPE_AUX (bit3=1) | REQ_TYPE_WRITE (bits1:0=0).
const AUXCH_CMD_NATIVE_WRITE: u32 = 0x8;
// cmd for a native AUX read: TYPE_AUX (bit3=1) | REQ_TYPE_READ (bits1:0=1).
const AUXCH_CMD_NATIVE_READ: u32 = 0x9;
// DPCD receiver caps (DP spec / drm_dp.h): MAX_LINK_RATE is in 0.27 Gb/s units —
// the SAME encoding as the DP_CTRL bw byte (0x0a=HBR, 0x14=HBR2, 0x1e=HBR3).
// MAX_LANE_COUNT is bits 4:0 of 0x002. nouveau reads these before training
// (nouveau_dp.c dpcd[DP_MAX_LINK_RATE]) and never trains past the SINK's max.
const DPCD_MAX_LINK_RATE: u32 = 0x001;
const DPCD_MAX_LANE_COUNT: u32 = 0x002;
// DPCD sink power register + D0 value (DP spec / drm_dp.h).
const DPCD_SET_POWER: u32 = 0x600;
const DPCD_SET_POWER_D0: u8 = 0x1;
const DpConfigStreamParams = extern struct {
    subDeviceInstance: u32,
    head: u32,
    sorIndex: u32,
    dpLink: u32,
    bEnableOverride: u8,
    bMST: u8,
    singleHeadMultistreamMode: u32 align(4),
    hBlankSym: u32,
    vBlankSym: u32,
    colorFormat: u32,
    bEnableTwoHeadOneOr: u8,
    MST: DpConfigStreamMst align(4),
    SST: DpConfigStreamSst,
};
comptime {
    std.debug.assert(@offsetOf(DpConfigStreamParams, "singleHeadMultistreamMode") == 20);
    std.debug.assert(@offsetOf(DpConfigStreamParams, "MST") == 40);
    std.debug.assert(@offsetOf(DpConfigStreamParams, "SST") == 68);
    std.debug.assert(@sizeOf(DpConfigStreamParams) == 84);
}

// ── Watermark constants (dispnv50/disp.c:1602-1605) ──────────────────────────────
const DP_CONFIG_WATERMARK_ADJUST: u64 = 2;
const DP_CONFIG_WATERMARK_LIMIT: u64 = 20;
const DP_CONFIG_INCREASED_WATERMARK_ADJUST: u64 = 8;
const DP_CONFIG_INCREASED_WATERMARK_LIMIT: u64 = 22;
const TU_SIZE: u32 = 64; // dispnv50/disp.c:1613 (fixed)

/// Map the GPU's DP_GET_CAPS maxLinkRate enum to a DP_CTRL bw byte, then clamp our
/// preferred 4×HBR2 choice to it (min(gpu, HBR2)). Returns the bw byte to program.
pub fn clampBw(gpu_max: u32) u8 {
    const gpu_byte: u8 = switch (gpu_max) {
        MAX_LINK_RATE_1_62 => BW_1_62,
        MAX_LINK_RATE_2_70 => BW_2_70,
        MAX_LINK_RATE_5_40 => BW_5_40,
        MAX_LINK_RATE_8_10 => BW_8_10,
        else => BW_5_40, // unknown/NONE: fall to HBR2
    };
    // Preferred is HBR2 (0x14); never exceed what the GPU reports. The bw bytes are
    // monotonic in rate, so min() on the byte is min() on the rate.
    return if (gpu_byte < BW_5_40) gpu_byte else BW_5_40;
}

/// Link symbol-clock (kHz) for a bw byte; minRate = link_bw*1000 in the math, where
/// nouveau's outp->dp.link_bw is this kHz value (HBR2 == 540000). See nouveau_dp.c.
pub fn linkRateKhz(bw: u8) u32 {
    return switch (bw) {
        BW_1_62 => 162000,
        BW_2_70 => 270000,
        BW_5_40 => 540000,
        BW_8_10 => 810000,
        else => 540000, // matches clampBw's HBR2 fallback
    };
}

/// SST stream watermark + blanking-symbol counts fed to DP_CONFIG_STREAM.
const Watermark = struct { waterMark: u32, hBlankSym: u32, vBlankSym: u32 };

/// Port of nv50_sor_dp_watermark_sst (dispnv50/disp.c:1607-1740) for SST. Computes
/// waterMark/hBlankSym/vBlankSym from the mode, lane count, link rate and depth.
/// Returns DpWatermarkInvalid for any case the original rejects (would HW-hang).
pub fn watermarkSst(
    mode: Mode,
    lanes: u32,
    bw: u8,
    bpc: u32,
    increased_wm: bool,
    enhanced_framing: bool,
) Error!Watermark {
    // dispnv50/disp.c:1612 — minRate = link_bw * 1000  (Hz)
    const minRate: u64 = @as(u64, linkRateKhz(bw)) * 1000;
    // :1617-1618 defaults, overridden by increased_wm below (:1638-1641)
    var watermarkAdjust: u64 = DP_CONFIG_WATERMARK_ADJUST;
    var watermarkMinimum: u64 = DP_CONFIG_WATERMARK_LIMIT;
    if (increased_wm) {
        watermarkAdjust = DP_CONFIG_INCREASED_WATERMARK_ADJUST;
        watermarkMinimum = DP_CONFIG_INCREASED_WATERMARK_LIMIT;
    }

    // :1624-1628 — geometry. surfaceWidth = active; rasterWidth = total (active+blank).
    // depth = bpc*3; DSC disabled so DSC_FACTOR = 1 (:1627).
    const surfaceWidth: u64 = mode.h;
    const rasterWidth: u64 = mode.h + mode.h_blank;
    const depth: u64 = bpc * 3;
    const DSC_FACTOR: u64 = 1;
    const pixelClockHz: u64 = @as(u64, mode.clock_khz) * 1000;
    const PrecisionFactor: u64 = 100000;
    const numLanesPerLink: u64 = lanes;
    const tuSize: u64 = TU_SIZE;

    // :1643 — bandwidth feasibility (must be strictly under).
    if (pixelClockHz * depth >= 8 * minRate * numLanesPerLink * DSC_FACTOR)
        return error.DpWatermarkInvalid;

    // :1663-1668 — ratioF (PrecisionFactor-scaled occupancy ratio).
    var ratioF: u64 = (pixelClockHz * depth * PrecisionFactor) / DSC_FACTOR;
    ratioF = ratioF / (8 * minRate * numLanesPerLink);
    if (PrecisionFactor < ratioF) return error.DpWatermarkInvalid;

    // :1670-1671 — watermark.
    const watermarkF: u64 = (ratioF * tuSize * (PrecisionFactor - ratioF)) / PrecisionFactor;
    var waterMark: u64 = watermarkAdjust +
        ((2 * ((depth * PrecisionFactor) / (8 * numLanesPerLink * DSC_FACTOR)) + watermarkF) / PrecisionFactor);

    // :1676-1685 — bounds + low-side clamp.
    const numSymbolsPerLine: u64 = (surfaceWidth * depth) / (8 * numLanesPerLink * DSC_FACTOR);
    if (waterMark > 39 or waterMark > numSymbolsPerLine) return error.DpWatermarkInvalid;
    if (waterMark < watermarkMinimum) waterMark = watermarkMinimum;

    // :1689-1704 — blanking bits → MinHBlank.
    var BlankingBits: u64 = 3 * 8 * numLanesPerLink +
        (if (enhanced_framing) 3 * 8 * numLanesPerLink else 0);
    BlankingBits += 3 * 8 * 4; // VBID/MVID/MAUD sent 4× (:1692)
    const surfaceWidthPerLink: u64 = surfaceWidth;
    const remain: u64 = surfaceWidthPerLink % numLanesPerLink;
    const PixelSteeringBits: u64 = if (remain != 0)
        ((numLanesPerLink - remain) * depth) / DSC_FACTOR
    else
        0;
    BlankingBits += PixelSteeringBits;
    const NumBlankingLinkClocks: u64 = (BlankingBits * PrecisionFactor) / (8 * numLanesPerLink);
    var MinHBlank: u64 = ((NumBlankingLinkClocks * pixelClockHz) / minRate) / PrecisionFactor;
    MinHBlank += 12;

    // :1706-1711 — sanity gates.
    if (MinHBlank > rasterWidth - surfaceWidth) return error.DpWatermarkInvalid;
    if (surfaceWidth <= 60) return error.DpWatermarkInvalid;

    // :1714-1722 — hBlankSym (signed, clamped to 0).
    var hblank_symbols: i64 =
        @intCast(((rasterWidth - surfaceWidth - MinHBlank) * minRate) / pixelClockHz);
    hblank_symbols -= 1; // stuffer latency to send BS (:1717)
    hblank_symbols -= 3; // SPKT latency (:1718)
    hblank_symbols -= switch (numLanesPerLink) { // :1720
        1 => @as(i64, 9),
        2 => @as(i64, 6),
        else => @as(i64, 3),
    };
    const hBlankSym: u32 = if (hblank_symbols < 0) 0 else @intCast(hblank_symbols);

    // :1727-1738 — vBlankSym (signed, clamped to 0).
    var vBlankSym: u32 = 0;
    if (surfaceWidth >= 40) {
        var vblank_symbols: i64 =
            @as(i64, @intCast(((surfaceWidth - 40) * minRate) / pixelClockHz)) - 1;
        vblank_symbols -= switch (numLanesPerLink) { // :1735
            1 => @as(i64, 39),
            2 => @as(i64, 21),
            else => @as(i64, 12),
        };
        vBlankSym = if (vblank_symbols < 0) 0 else @intCast(vblank_symbols);
    }

    return .{ .waterMark = @intCast(waterMark), .hBlankSym = hBlankSym, .vBlankSym = vBlankSym };
}

/// Wall-clock delay of `ms` milliseconds between DP_CTRL retries (the GSP reports a
/// retryTimeMs). Uses the timer-backed shim.delayUs, not a CPU-iteration count: a
/// bare spin count is CPU-speed/optimization dependent (near-zero on a fast core
/// under ReleaseFast), which would make the retry backoff not actually wait.
fn busyDelayMs(ms: u32) void {
    // Cap at 1 s so an absurd GSP-reported retryTimeMs can't overflow the u32 µs
    // argument (ms*1000) or stall the boot path unreasonably.
    const capped: u32 = @min(ms, 1000);
    shim.delayUs(capped * 1000);
}

/// Native AUX DPCD write to the sink (NV0073_CTRL_CMD_DP_AUXCH_CTRL). `data` is
/// 1..16 bytes written at DPCD `addr`. nouveau r535_dp_aux_xfer.
fn auxWrite(g: gsp.Gsp, displayId: u32, addr: u32, data: []const u8) Error!void {
    // A native AUX write carries 1..AUXCH_MAX_DATA bytes; `size` is len-1, so an
    // empty slice would underflow it and a too-long slice would overrun p.data.
    if (data.len == 0 or data.len > AUXCH_MAX_DATA) return error.DpAuxBadLen;
    var p = std.mem.zeroes(DpAuxchCtrlParams);
    p.subDeviceInstance = 0;
    p.displayId = displayId;
    p.bAddrOnly = 0;
    p.cmd = AUXCH_CMD_NATIVE_WRITE;
    p.addr = addr;
    p.size = @intCast(data.len - 1); // RM wants len-1
    @memcpy(p.data[0..data.len], data);
    try rm.control(g, nvrm.RM_DISP, nvrm.CTRL_DP_AUXCH_CTRL, std.mem.asBytes(&p));
    log("gpu.dp: AUX write DPCD 0x{x} = 0x{x} OK\n", .{ addr, data[0] });
}

/// Native AUX DPCD read (NV0073_CTRL_CMD_DP_AUXCH_CTRL, read cmd). Reads out.len
/// (1..16) bytes at DPCD `addr`. Only used PRE-training to fetch receiver caps —
/// nouveau does the same (nouveau_dp.c); AUX reads issued after training were
/// observed to perturb live links on this HW, so never call this post-train.
fn auxRead(g: gsp.Gsp, displayId: u32, addr: u32, out: []u8) Error!void {
    if (out.len == 0 or out.len > AUXCH_MAX_DATA) return error.DpAuxBadLen;
    var p = std.mem.zeroes(DpAuxchCtrlParams);
    p.subDeviceInstance = 0;
    p.displayId = displayId;
    p.bAddrOnly = 0;
    p.cmd = AUXCH_CMD_NATIVE_READ;
    p.addr = addr;
    p.size = @intCast(out.len - 1); // RM wants len-1
    try rm.control(g, nvrm.RM_DISP, nvrm.CTRL_DP_AUXCH_CTRL, std.mem.asBytes(&p));
    @memcpy(out, p.data[0..out.len]);
}

/// Train a DisplayPort SST link for `displayId` (== BIT(orIndex)), driving `mode`.
/// Steps 1-4 (OR_GET_INFO/GET_CAPS/ASSIGN_SOR/DP_CTRL — GSP auto-trains) plus the
/// watermark compute; DP_CONFIG_STREAM is deferred to `configStream` (called after
/// the EVO SOR push).
pub fn linkUp(g: gsp.Gsp, displayId: u32, sorExcludeMask: u8, mode: Mode) Error!DpLink {
    // 1. OR_GET_INFO → SOR index + protocol (DP_A/DP_B → sublink 1/2).
    var info = std.mem.zeroes(OrGetInfoParams);
    info.subDeviceInstance = 0;
    info.displayId = displayId;
    try rm.control(g, nvrm.RM_DISP, CTRL_SPECIFIC_OR_GET_INFO, std.mem.asBytes(&info));
    if (info.protocol != OR_PROTOCOL_SOR_DP_A and info.protocol != OR_PROTOCOL_SOR_DP_B) {
        log("gpu.dp: displayId=0x{x} OR protocol=0x{x} type=0x{x} not DP\n", .{ displayId, info.protocol, info.type });
        return error.DpNotDisplayPort;
    }
    const protocol = info.protocol;
    // sublink: DP_A→1, DP_B→2; dpLink for CONFIG_STREAM = (sublink==2)?1:0.
    const sublink: u32 = if (protocol == OR_PROTOCOL_SOR_DP_B) 2 else 1;
    log("gpu.dp: OR_GET_INFO displayId=0x{x} index={} type=0x{x} proto=0x{x} location={}\n", .{ displayId, info.index, info.type, info.protocol, info.location });

    // 2. DP_GET_CAPS (sorIndex = ~0) → GPU max link rate + increased-watermark flag.
    var caps = std.mem.zeroes(DpGetCapsParams);
    caps.subDeviceInstance = 0;
    caps.sorIndex = 0xFFFFFFFF;
    try rm.control(g, nvrm.RM_DISP, CTRL_DP_GET_CAPS, std.mem.asBytes(&caps));
    // The GPU's max link rate — nouveau trains highest-rate-first (nouveau_dp.c:
    // rate[] sorted descending, first feasible wins), NOT a "minimal fit for the
    // mode". The actual rate used is min(gpu, sink) — clamped against the sink's
    // DPCD receiver caps below, exactly as nouveau does.
    const gpu_bw = clampBw(caps.maxLinkRate);
    const increased_wm = caps.bHasIncreasedWatermarkLimits != 0;

    // 3. DFP_ASSIGN_SOR → scan sorAssignListWithTag[4] for displayMask & displayId.
    var assign = std.mem.zeroes(DfpAssignSorParams);
    assign.subDeviceInstance = 0;
    assign.displayId = displayId;
    assign.sorExcludeMask = sorExcludeMask; // exclude already-assigned SORs (multi-head)
    assign.flags = 0; // no audio
    try rm.control(g, nvrm.RM_DISP, CTRL_DFP_ASSIGN_SOR, std.mem.asBytes(&assign));
    for (assign.sorAssignListWithTag, 0..) |tag, i| {
        log("gpu.dp: ASSIGN_SOR[{}] displayMask=0x{x} sorType={}\n", .{ i, tag.displayMask, tag.sorType });
    }
    var sor_id: u32 = 0xFFFFFFFF;
    for (assign.sorAssignListWithTag, 0..) |tag, i| {
        if (tag.displayMask & displayId != 0) {
            sor_id = @intCast(i);
            break;
        }
    }
    if (sor_id == 0xFFFFFFFF) {
        log("gpu.dp: no SOR assigned for displayId=0x{x}\n", .{displayId});
        return error.DpNoSor;
    }

    // 3b. WAKE THE SINK: write DPCD 0x600 = D0 over AUX. Under
    //     DP_SET_MANUAL_DISPLAYPORT the GSP does NOT power the sink; DP_CTRL only
    //     programs the SOR PHY. nouveau does this before training (nouveau_dp.c:423).
    //     A sink left in D3 stays in power-standby/no-signal even with a trained
    //     link + scanning head — exactly the observed symptom.
    //     Swallowing this failure is exactly what leaves the panel dark, so it is
    //     fatal: a sink we could not wake will not display regardless of training.
    auxWrite(g, displayId, DPCD_SET_POWER, &[_]u8{DPCD_SET_POWER_D0}) catch |e| {
        log("gpu.dp: DPCD 0x600=D0 sink power-on failed: {}\n", .{e});
        return e;
    };

    // 3c. Read the SINK's receiver caps (DPCD 0x001/0x002, after D0 so a sleeping
    //     sink can't NACK the read) and clamp to them — nouveau never trains past
    //     the sink's max (nouveau_dp.c dpcd[DP_MAX_LINK_RATE]). Training the GPU's
    //     max (HBR2) into an HBR-max panel "succeeds" GPU-side but the sink never
    //     locks → no-signal/black (the ultrawide symptom); the 4K panels support
    //     HBR2 so they were unaffected. PRE-train AUX only (post-train reads were
    //     observed to perturb live links on this HW).
    var rxcaps: [2]u8 = .{ 0, 0 };
    try auxRead(g, displayId, DPCD_MAX_LINK_RATE, &rxcaps);
    const sink_bw: u8 = rxcaps[0];
    const sink_lanes: u32 = rxcaps[1] & 0x1f;
    if (sink_bw == 0 or sink_lanes == 0) {
        log("gpu.dp: displayId=0x{x} bad DPCD rx caps maxRate=0x{x} maxLanes={}\n", .{ displayId, sink_bw, sink_lanes });
        return error.DpTrainFailed;
    }
    const link_bw: u8 = @min(gpu_bw, sink_bw);
    log("gpu.dp: displayId=0x{x} sink DPCD maxRate=0x{x} maxLanes={} → training bw=0x{x} (gpu max 0x{x})\n", .{ displayId, sink_bw, sink_lanes, link_bw, gpu_bw });

    // 3d. LTTPR (DP 1.4 link-training-tunable PHY repeater) detection, DPCD
    //     0xF0000-0xF0002. A repeater in the cable/sink path that is not put in
    //     TRANSPARENT mode can pass link training yet block the video stream —
    //     black panel with a "trained" link. nouveau/drm force transparent mode
    //     (DP_PHY_REPEATER_MODE @ 0xF0003 = 0x55) whenever a repeater is present
    //     (drm_dp_lttpr_*, nouveau_dp.c). Pre-train AUX only.
    var lttpr: [3]u8 = .{ 0, 0, 0 };
    if (auxRead(g, displayId, 0xF0000, &lttpr)) |_| {
        log("gpu.dp: displayId=0x{x} LTTPR rev=0x{x} maxRate=0x{x} repCount=0x{x}\n", .{ displayId, lttpr[0], lttpr[1], lttpr[2] });
        if (lttpr[0] != 0 and lttpr[2] != 0) {
            auxWrite(g, displayId, 0xF0003, &[_]u8{0x55}) catch |e| {
                log("gpu.dp: LTTPR transparent-mode write failed: {}\n", .{e});
            };
        }
    } else |e| {
        // Pre-1.4 sinks NACK this read — normal, not an error.
        log("gpu.dp: displayId=0x{x} no LTTPR (read: {})\n", .{ displayId, e });
    }

    // 4. DP_CTRL → choose 4 lanes @ chosen bw; GSP runs CR+EQ. Retry up to 3×.
    //    SET_ENHANCED_FRAMING must match what CONFIG_STREAM uses (diff item [7]).
    const lane_count: u32 = @min(4, sink_lanes);
    // Enhanced framing ONLY if the sink advertises it (DPCD 0x002 bit7) — nouveau
    // r535_dp_train_target sets SET_ENHANCED_FRAMING conditionally on
    // DPCD_RC02_ENHANCED_FRAME_CAP and does NOT set the data-field EF bit at all.
    // Forcing EF on a non-EF sink trains (EQ is below framing) but the sink cannot
    // frame the video stream → black panel with a "trained" link.
    const sink_ef = (rxcaps[1] & 0x80) != 0;
    log("gpu.dp: displayId=0x{x} sink enhanced-framing cap={}\n", .{ displayId, sink_ef });
    const cmd: u32 = DP_CMD_SET_LANE_COUNT | DP_CMD_SET_LINK_BW | DP_CMD_TRAIN_PHY_REPEATER |
        (if (sink_ef) DP_CMD_SET_ENHANCED_FRAMING else 0);
    const data: u32 = (lane_count << DP_DATA_LANE_COUNT_SHIFT) |
        (@as(u32, link_bw) << DP_DATA_LINK_BW_SHIFT) |
        (0 << DP_DATA_TARGET_SHIFT); // target = sink; no EF bit in data (nouveau)

    var trained = false;
    var attempt: u32 = 0;
    var trained_data: u32 = data; // DP_CTRL `data` is IN/OUT: after training it holds
    while (attempt < 3) : (attempt += 1) { //   the NEGOTIATED lanes (4:0) + bw (15:8)
        var ctrl = std.mem.zeroes(DpCtrlParams);
        ctrl.subDeviceInstance = 0;
        ctrl.displayId = displayId;
        ctrl.cmd = cmd;
        ctrl.data = data;
        try rm.control(g, nvrm.RM_DISP, CTRL_DP_CTRL, std.mem.asBytes(&ctrl));
        if (ctrl.err == 0) {
            trained = true;
            trained_data = ctrl.data;
            break;
        }
        log("gpu.dp: DP_CTRL attempt {} err=0x{x} retryMs={}\n", .{ attempt, ctrl.err, ctrl.retryTimeMs });
        busyDelayMs(if (ctrl.retryTimeMs != 0) ctrl.retryTimeMs else 1);
    }
    if (!trained) {
        log("gpu.dp: link training failed sor={} lanes={} bw=0x{x}\n", .{ sor_id, lane_count, link_bw });
        return error.DpTrainFailed;
    }

    // Use the ACTUALLY-NEGOTIATED lanes + bw from DP_CTRL's return, not the requested
    // values — a link that trained down (shorter/weaker cable on one output) reports
    // fewer lanes / lower bw here, and the watermark MUST match the real link or the
    // stream under/overflows → flicker (the exact one-monitor-flickering symptom).
    // Fall back to the requested values only if the RM returned 0 (nothing negotiated).
    const neg_lanes_raw: u32 = trained_data & 0x1f;
    const neg_bw_raw: u32 = (trained_data >> 8) & 0xff;
    const act_lanes: u32 = if (neg_lanes_raw != 0) neg_lanes_raw else lane_count;
    const act_bw: u8 = if (neg_bw_raw != 0) @intCast(neg_bw_raw) else link_bw;
    log("gpu.dp: DP_CTRL negotiated data=0x{x} → {}lane bw=0x{x} (requested {}lane bw=0x{x})\n", .{ trained_data, act_lanes, act_bw, lane_count, link_bw });

    // 5. Compute the stream watermark/blanking from the REAL link params (8bpc →
    // depth=24). DP_CONFIG_STREAM is deferred to `configStream`, invoked BEFORE the
    // SOR_SET_CONTROL EVO push (nouveau nv50_sor_atomic_enable → watermark_sst).
    const enhanced_framing = sink_ef; // must match the trained link (diff item [7])
    const wm = try watermarkSst(mode, act_lanes, act_bw, 8, increased_wm, enhanced_framing);

    log("gpu.dp: trained sor={} proto=0x{x} {}lane bw=0x{x} wm={} hbs={} vbs={}\n", .{ sor_id, protocol, act_lanes, act_bw, wm.waterMark, wm.hBlankSym, wm.vBlankSym });

    return .{
        .sor_id = sor_id,
        .protocol = protocol,
        .sublink = sublink,
        .link_bw = act_bw,
        .lane_count = act_lanes,
        .trained = trained,
        .waterMark = wm.waterMark,
        .hBlankSym = wm.hBlankSym,
        .vBlankSym = wm.vBlankSym,
        .enhanced_framing = enhanced_framing,
    };
}

// DP_CONFIG_STREAM is deliberately NOT issued: the instrumented-nouveau trace of
// the working 3-monitor modeset (incl. the ultrawide at native) shows nouveau never
// sends it on GSP-RM — the GSP's internal stream defaults handle SST.
