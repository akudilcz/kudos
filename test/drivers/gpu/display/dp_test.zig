//! Host tests of src/drivers/gpu/display/dp.zig (reached through the gpu_root module-root shim).

const std = @import("std");
const dp = @import("testroot").gpu.dp;
const BW_1_62 = dp.BW_1_62;
const BW_2_70 = dp.BW_2_70;
const BW_5_40 = dp.BW_5_40;
const BW_8_10 = dp.BW_8_10;
const MAX_LINK_RATE_1_62 = dp.MAX_LINK_RATE_1_62;
const MAX_LINK_RATE_2_70 = dp.MAX_LINK_RATE_2_70;
const MAX_LINK_RATE_5_40 = dp.MAX_LINK_RATE_5_40;
const MAX_LINK_RATE_8_10 = dp.MAX_LINK_RATE_8_10;
const Mode = dp.Mode;
const clampBw = dp.clampBw;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const linkRateKhz = dp.linkRateKhz;
const watermarkSst = dp.watermarkSst;

/// Ultrawide native mode (the centre 3440x1440 panel, hand-decoded from its
/// EDID, which the ultrawide bring-up ruled out as the fault).
const test_mode_uw = Mode{
    .h = 3440,
    .v = 1440,
    .clock_khz = 319750,
    .h_blank = 160,
    .h_sync_off = 48,
    .h_sync_w = 32,
    .v_blank = 41,
    .v_sync_off = 3,
    .v_sync_w = 10,
    .h_sync_neg = false,
    .v_sync_neg = true,
};

/// The forced 4K60 timing (identical values to disp.zig mode4k, restated here as
/// a test vector — disp.zig's constant is private and hardware-scoped).
const test_mode_4k = Mode{
    .h = 3840,
    .v = 2160,
    .clock_khz = 533250,
    .h_blank = 160,
    .h_sync_off = 48,
    .h_sync_w = 32,
    .v_blank = 62,
    .v_sync_off = 3,
    .v_sync_w = 5,
    .h_sync_neg = false,
    .v_sync_neg = true,
};

test "clampBw: GPU maxLinkRate enum → bw byte, clamped to preferred HBR2" {
    try expectEqual(@as(u8, BW_1_62), clampBw(MAX_LINK_RATE_1_62)); // 0x06
    try expectEqual(@as(u8, BW_2_70), clampBw(MAX_LINK_RATE_2_70)); // 0x0a
    try expectEqual(@as(u8, BW_5_40), clampBw(MAX_LINK_RATE_5_40)); // 0x14
    // GPU reports HBR3 but the preferred choice is HBR2 → clamp down to 0x14.
    try expectEqual(@as(u8, BW_5_40), clampBw(MAX_LINK_RATE_8_10));
    // Unknown/NONE falls to HBR2.
    try expectEqual(@as(u8, BW_5_40), clampBw(0));
    try expectEqual(@as(u8, BW_5_40), clampBw(0xFFFFFFFF));
}

test "linkRateKhz: bw byte → link symbol clock (kHz), 0.27 Gb/s units" {
    try expectEqual(@as(u32, 162000), linkRateKhz(BW_1_62)); // RBR
    try expectEqual(@as(u32, 270000), linkRateKhz(BW_2_70)); // HBR
    try expectEqual(@as(u32, 540000), linkRateKhz(BW_5_40)); // HBR2
    try expectEqual(@as(u32, 810000), linkRateKhz(BW_8_10)); // HBR3
    try expectEqual(@as(u32, 540000), linkRateKhz(0x00)); // matches clampBw fallback
}

test "watermarkSst ultrawide native, 4-lane HBR2, 8bpc, EF (the real link config)" {
    // Hand-evaluated against dispnv50/disp.c:1607-1740 with these inputs:
    //   ratioF = 44409, watermarkF = 1579994 → waterMark = 2+17 = 19, clamped up
    //   to the DP_CONFIG_WATERMARK_LIMIT of 20.
    //   MinHBlank = 17 → hblank_symbols = 241-1-3-3 = 234.
    //   vblank_symbols = 5741-1-12 = 5728.
    const wm = try watermarkSst(test_mode_uw, 4, BW_5_40, 8, false, true);
    try expectEqual(@as(u32, 20), wm.waterMark);
    try expectEqual(@as(u32, 234), wm.hBlankSym);
    try expectEqual(@as(u32, 5728), wm.vBlankSym);
}

test "watermarkSst ultrawide with increased watermark limits (GPU cap flag)" {
    // increased_wm swaps adjust/limit to 8/22: waterMark = 8+17 = 25 (no clamp).
    // The blanking math is unchanged.
    const wm = try watermarkSst(test_mode_uw, 4, BW_5_40, 8, true, true);
    try expectEqual(@as(u32, 25), wm.waterMark);
    try expectEqual(@as(u32, 234), wm.hBlankSym);
    try expectEqual(@as(u32, 5728), wm.vBlankSym);
}

test "watermarkSst ultrawide without enhanced framing: BlankingBits shrink, hBlankSym grows" {
    // EF off drops 3*8*lanes from BlankingBits: MinHBlank = 15 → 244-1-3-3 = 237.
    const wm = try watermarkSst(test_mode_uw, 4, BW_5_40, 8, false, false);
    try expectEqual(@as(u32, 20), wm.waterMark);
    try expectEqual(@as(u32, 237), wm.hBlankSym);
    try expectEqual(@as(u32, 5728), wm.vBlankSym);
}

test "watermarkSst 4K60, 4-lane HBR2, 8bpc, EF" {
    // ratioF = 74062, watermarkF = 1229452 → waterMark = 2+13 = 15 → clamped to 20.
    // MinHBlank = 20 → hblank_symbols = 141-1-3-3 = 134.
    // vblank_symbols = 3848-1-12 = 3835.
    const wm = try watermarkSst(test_mode_4k, 4, BW_5_40, 8, false, true);
    try expectEqual(@as(u32, 20), wm.waterMark);
    try expectEqual(@as(u32, 134), wm.hBlankSym);
    try expectEqual(@as(u32, 3835), wm.vBlankSym);
}

test "watermarkSst rejects a mode over the link bandwidth (disp.c:1643 gate)" {
    // 4K60 needs 533.25 MHz * 24 bpp = 12.798 Gb/s of pixel data; a 1-lane HBR
    // link carries 8 * 270 MHz * 1 = 2.16 Gsym/s * 8 bits — the strict-under gate
    // pixelClockHz*depth >= 8*minRate*lanes fails → DpWatermarkInvalid (HW-hang
    // territory in the original, hence the rejection).
    try expectError(error.DpWatermarkInvalid, watermarkSst(test_mode_4k, 1, BW_2_70, 8, false, true));
}

test "watermarkSst rejects surfaceWidth <= 60 (disp.c:1711 gate)" {
    const tiny = Mode{
        .h = 60,
        .v = 60,
        .clock_khz = 1000,
        .h_blank = 200,
        .h_sync_off = 48,
        .h_sync_w = 32,
        .v_blank = 41,
        .v_sync_off = 3,
        .v_sync_w = 10,
        .h_sync_neg = false,
        .v_sync_neg = false,
    };
    try expectError(error.DpWatermarkInvalid, watermarkSst(tiny, 4, BW_5_40, 8, false, true));
}

test "watermarkSst rejects MinHBlank wider than the mode's real blanking (disp.c:1706 gate)" {
    // Same ultrawide active/clock but with only 16 pixels of hblank: MinHBlank (17)
    // exceeds rasterWidth - surfaceWidth (16) → rejected.
    const squeezed = Mode{
        .h = 3440,
        .v = 1440,
        .clock_khz = 319750,
        .h_blank = 16,
        .h_sync_off = 4,
        .h_sync_w = 8,
        .v_blank = 41,
        .v_sync_off = 3,
        .v_sync_w = 10,
        .h_sync_neg = false,
        .v_sync_neg = true,
    };
    try expectError(error.DpWatermarkInvalid, watermarkSst(squeezed, 4, BW_5_40, 8, false, true));
}
