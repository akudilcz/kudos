//! Host tests of src/drivers/gpu/display/edid.zig.

const std = @import("std");
const edid = @import("edid");
const edid1080p = edid.edid1080p;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const headerValid = edid.headerValid;
const parsePreferredMode = edid.parsePreferredMode;

test "headerValid: accepts the magic, rejects garbage/short" {
    const e = edid1080p();
    try expect(headerValid(&e));
    var bad = e;
    bad[1] = 0x00;
    try expect(!headerValid(&bad));
    try expect(!headerValid(&[_]u8{ 0x00, 0xFF })); // too short
}

test "parsePreferredMode: 1920x1080@60 fields decode correctly (RND-002: the native mode the display is driven at)" {
    const e = edid1080p();
    const m = parsePreferredMode(&e);
    try expectEqual(@as(u32, 1920), m.h);
    try expectEqual(@as(u32, 1080), m.v);
    try expectEqual(@as(u32, 148500), m.clock_khz); // 14850 * 10
    try expectEqual(@as(u32, 280), m.h_blank);
    try expectEqual(@as(u32, 45), m.v_blank);
    try expectEqual(@as(u32, 88), m.h_sync_off);
    try expectEqual(@as(u32, 44), m.h_sync_w);
    try expectEqual(@as(u32, 4), m.v_sync_off);
    try expectEqual(@as(u32, 5), m.v_sync_w);
    // 0x1E = digital separate (0x18) + hsync-positive (0x02) + vsync-positive (0x04)
    // → EVO negative sense is false for both.
    try expect(!m.h_sync_neg);
    try expect(!m.v_sync_neg);
}

test "parsePreferredMode: high bits of the 12-bit splits + negative sync" {
    var e = edid1080p();
    // Force upper-nibble/high-bit values: h_active |= 0xF00, h_blank |= 0xF00 via
    // d[4] = 0xFF; v likewise via d[7]=0xFF; sync high bits via d[11]=0xFF.
    e[54 + 4] = 0xFF; // h_active high nibble = 0xF, h_blank high nibble = 0xF
    e[54 + 7] = 0xFF; // v_active/v_blank high nibbles = 0xF
    e[54 + 11] = 0xFF; // all sync high bits set
    // Negative sync: digital separate but BOTH polarity bits 0 → neg = true.
    e[54 + 17] = 0x18;
    const m = parsePreferredMode(&e);
    try expectEqual(@as(u32, 0x80 | 0xF00), m.h); // low d2=0x80 + high 0xF00
    try expectEqual(@as(u32, 0x18 | 0xF00), m.h_blank);
    try expectEqual(@as(u32, 0x38 | 0xF00), m.v);
    try expectEqual(@as(u32, 0x2D | 0xF00), m.v_blank);
    try expect(m.h_sync_neg);
    try expect(m.v_sync_neg);
}

test "parsePreferredMode: non-digital-separate flags → sync not negated" {
    var e = edid1080p();
    e[54 + 17] = 0x00; // analog / not digital-separate
    const m = parsePreferredMode(&e);
    try expect(!m.h_sync_neg);
    try expect(!m.v_sync_neg);
}
