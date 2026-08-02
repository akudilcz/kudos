//! EDID (VESA E-EDID) parsing — pure byte logic, host-testable (`zig build test`).
//! Owns the display `Mode` and the preferred-timing parse; disp.zig re-exports
//! `Mode` and calls `parsePreferredMode`. The 12-bit active/blank values are split
//! across upper-nibble bytes in the 18-byte detailed-timing descriptor — exactly
//! the bit-packing where an off-by-one silently blanks a head, so it is tested.

/// A display mode's active resolution + pixel clock (the head raster-timing source).
pub const Mode = struct {
    h: u32, // horizontal active pixels
    v: u32, // vertical active pixels
    clock_khz: u32, // pixel clock in kHz (EDID stores it in 10 kHz units)
    // Full blanking timings (for the mode-set).
    h_blank: u32 = 0,
    h_sync_off: u32 = 0,
    h_sync_w: u32 = 0,
    v_blank: u32 = 0,
    v_sync_off: u32 = 0,
    v_sync_w: u32 = 0,
    // Sync polarity from the EDID detailed-timing flags (digital separate sync).
    // The EVO HEAD_SET_CONTROL_OUTPUT_RESOURCE wants "negative" as the active bit
    // (nouveau asyh->or.nhsync = !(flags & POS_HSYNC)). true = negative.
    h_sync_neg: bool = false,
    v_sync_neg: bool = false,
};

/// The 8-byte EDID header magic (00 FF FF FF FF FF FF 00). A block missing it is
/// not a valid EDID — the caller must not derive a timing from garbage.
pub const HEADER = [8]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };

/// True if `edid` starts with the E-EDID header magic.
pub fn headerValid(edid: []const u8) bool {
    if (edid.len < 8) return false;
    for (HEADER, 0..) |b, i| {
        if (edid[i] != b) return false;
    }
    return true;
}

/// Parse the preferred detailed-timing descriptor (EDID block 0, 18 bytes at
/// offset 54) into a Mode. Encodes 12-bit active + blanking values split across
/// upper-nibble bytes (VESA E-EDID). This is the monitor's native mode. Caller
/// must ensure `edid.len >= 72` (a full 128-byte EDID block satisfies it).
pub fn parsePreferredMode(edid: []const u8) Mode {
    const d = edid[54..72]; // detailed timing descriptor 0
    const clock_10khz = @as(u32, d[0]) | (@as(u32, d[1]) << 8);
    const h_active = @as(u32, d[2]) | ((@as(u32, d[4]) >> 4) << 8);
    const h_blank = @as(u32, d[3]) | ((@as(u32, d[4]) & 0xf) << 8);
    const v_active = @as(u32, d[5]) | ((@as(u32, d[7]) >> 4) << 8);
    const v_blank = @as(u32, d[6]) | ((@as(u32, d[7]) & 0xf) << 8);
    const h_sync_off = @as(u32, d[8]) | ((@as(u32, d[11]) >> 6) << 8);
    const h_sync_w = @as(u32, d[9]) | (((@as(u32, d[11]) >> 4) & 0x3) << 8);
    const v_sync_off = (@as(u32, d[10]) >> 4) | (((@as(u32, d[11]) >> 2) & 0x3) << 4);
    const v_sync_w = (@as(u32, d[10]) & 0xf) | ((@as(u32, d[11]) & 0x3) << 4);
    // d[17] = feature flags. For digital separate sync (bits 4:3 == 0b11): bit2 =
    // vsync polarity (1=positive), bit1 = hsync polarity (1=positive). EVO wants
    // the negative sense, so neg = !(positive bit).
    const flags = d[17];
    const digital_separate = (flags & 0x18) == 0x18;
    const h_sync_neg = if (digital_separate) (flags & 0x02) == 0 else false;
    const v_sync_neg = if (digital_separate) (flags & 0x04) == 0 else false;
    return .{
        .h = h_active,
        .v = v_active,
        .clock_khz = clock_10khz * 10,
        .h_blank = h_blank,
        .h_sync_off = h_sync_off,
        .h_sync_w = h_sync_w,
        .v_blank = v_blank,
        .v_sync_off = v_sync_off,
        .v_sync_w = v_sync_w,
        .h_sync_neg = h_sync_neg,
        .v_sync_neg = v_sync_neg,
    };
}

// ── tests (host: `zig build test`) ───────────────────────────────────────────
const std = @import("std");

// A real 128-byte EDID (a 1920x1080@60 panel) — the first block, header + the
// preferred detailed timing at offset 54. Bytes chosen so the 12-bit splits are
// non-trivial (1920 = 0x780 needs the upper nibble; blanking spans the nibble).
pub fn edid1080p() [128]u8 {
    var e = [_]u8{0} ** 128;
    e[0..8].* = HEADER;
    // Detailed timing descriptor 0 at offset 54 for 1920x1080@60:
    //  pixel clock 148.5 MHz = 14850 (10 kHz units) = 0x3A02 → d0=0x02 d1=0x3A
    //  h_active 1920=0x780, h_blank 280=0x118 → d2=0x80 d3=0x18 d4=0x71
    //  v_active 1080=0x438, v_blank 45=0x2D   → d5=0x38 d6=0x2D d7=0x40
    //  h_sync_off 88=0x58, h_sync_w 44=0x2C   → d8=0x58 d9=0x2C
    //  v_sync_off 4, v_sync_w 5               → d10=0x45
    //  upper bits d11: hso[9:8]=0 hsw[9:8]=0 vso[5:4]=0 vsw[5:4]=0 → 0x00
    //  d17 flags: digital separate + both sync positive (0x1E)
    const d = [_]u8{ 0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C, 0x45, 0x00, 0, 0, 0, 0, 0, 0x1E };
    for (d, 0..) |b, i| e[54 + i] = b;
    return e;
}
