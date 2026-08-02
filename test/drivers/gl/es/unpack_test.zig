//! Host tests of src/drivers/gl/es/unpack.zig.

const std = @import("std");
const unpack = @import("unpack");
const Error = unpack.Error;
const GLenum = unpack.GLenum;
const enums = unpack.enums;
const expand = unpack.expand;
const expandPaletted = unpack.expandPaletted;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const indexBytes = unpack.indexBytes;
const paletted = unpack.paletted;
const palettedSize = unpack.palettedSize;
const sourcePixelSize = unpack.sourcePixelSize;
const sourceRowStride = unpack.sourceRowStride;
const storedFormat = unpack.storedFormat;
const widen = unpack.widen;

test "widening replicates high bits: five ones must be 255, not 248" {
    try expectEqual(@as(u8, 255), widen(5, 0x1F));
    try expectEqual(@as(u8, 0), widen(5, 0));
    try expectEqual(@as(u8, 255), widen(6, 0x3F));
    try expectEqual(@as(u8, 255), widen(4, 0xF));
    // Zero stays zero, and the midpoint stays near the middle rather than drifting.
    try expectEqual(@as(u8, 0), widen(4, 0x0));
    try expect(widen(5, 0x10) >= 128);
    try expect(widen(5, 0x10) <= 136);
}

test "GL_UNPACK_ALIGNMENT defaults to 4, and pads every row" {
    // 3 RGB pixels = 9 bytes, but the row is 12: the classic skewed-image bug.
    try expectEqual(@as(usize, 12), sourceRowStride(3, 3, 4));
    try expectEqual(@as(usize, 9), sourceRowStride(3, 3, 1));
    try expectEqual(@as(usize, 10), sourceRowStride(3, 3, 2));
    try expectEqual(@as(usize, 16), sourceRowStride(3, 3, 8));
    // A row already on the alignment is not padded further.
    try expectEqual(@as(usize, 16), sourceRowStride(4, 4, 4));
}

test "a padded image expands without skewing" {
    // 2x2 RGB with alignment 4: each row is 6 bytes of pixels padded to 8.
    var src: [16]u8 = @splat(0);
    src[0] = 10;
    src[1] = 20;
    src[2] = 30; // row 0, pixel 0
    src[3] = 40;
    src[4] = 50;
    src[5] = 60; // row 0, pixel 1
    // bytes 6,7 are padding
    src[8] = 70;
    src[9] = 80;
    src[10] = 90; // row 1, pixel 0

    var dst: [2 * 2 * 4]u8 = undefined;
    try expand(&dst, &src, 2, 2, enums.GL_RGB, enums.GL_UNSIGNED_BYTE, 4);
    // Row 1 must come from byte 8, not byte 6.
    try expectEqual(@as(u8, 90), dst[8]); // B of row 1 pixel 0 (RGB 70,80,90 -> BGR)
    try expectEqual(@as(u8, 70), dst[10]); // R
}

test "RGBA becomes blue-first, and RGB gains an alpha of 1" {
    const rgba = [_]u8{ 1, 2, 3, 4 };
    var dst: [4]u8 = undefined;
    try expand(&dst, &rgba, 1, 1, enums.GL_RGBA, enums.GL_UNSIGNED_BYTE, 1);
    try expectEqual([4]u8{ 3, 2, 1, 4 }, dst); // B G R A

    const rgb = [_]u8{ 1, 2, 3 };
    try expand(&dst, &rgb, 1, 1, enums.GL_RGB, enums.GL_UNSIGNED_BYTE, 1);
    try expectEqual([4]u8{ 3, 2, 1, 255 }, dst); // the missing alpha reads as 1
}

test "luminance and alpha keep their single channel" {
    var dst: [2]u8 = undefined;
    try expand(dst[0..1], &[_]u8{77}, 1, 1, enums.GL_LUMINANCE, enums.GL_UNSIGNED_BYTE, 1);
    try expectEqual(@as(u8, 77), dst[0]);
    try expect(storedFormat(enums.GL_LUMINANCE).? == .luminance8);
    try expect(storedFormat(enums.GL_ALPHA).? == .alpha8);
    try expect(storedFormat(enums.GL_LUMINANCE_ALPHA).? == .luminance_alpha8);
}

test "5-6-5 expands to full range, white staying white" {
    const white = [_]u8{ 0xFF, 0xFF }; // all ones
    var dst: [4]u8 = undefined;
    try expand(&dst, &white, 1, 1, enums.GL_RGB, enums.GL_UNSIGNED_SHORT_5_6_5, 1);
    try expectEqual([4]u8{ 255, 255, 255, 255 }, dst); // not 248/252/248

    // Pure red: r = 0x1F in the top five bits.
    var red: [2]u8 = undefined;
    std.mem.writeInt(u16, &red, 0x1F << 11, .little);
    try expand(&dst, &red, 1, 1, enums.GL_RGB, enums.GL_UNSIGNED_SHORT_5_6_5, 1);
    try expectEqual([4]u8{ 0, 0, 255, 255 }, dst); // B G R A
}

test "5-5-5-1 has one bit of alpha: on or off, nothing between" {
    var v: [2]u8 = undefined;
    var dst: [4]u8 = undefined;
    std.mem.writeInt(u16, &v, 0xFFFF, .little); // alpha bit set
    try expand(&dst, &v, 1, 1, enums.GL_RGBA, enums.GL_UNSIGNED_SHORT_5_5_5_1, 1);
    try expectEqual(@as(u8, 255), dst[3]);
    std.mem.writeInt(u16, &v, 0xFFFE, .little); // alpha bit clear
    try expand(&dst, &v, 1, 1, enums.GL_RGBA, enums.GL_UNSIGNED_SHORT_5_5_5_1, 1);
    try expectEqual(@as(u8, 0), dst[3]);
}

test "4-4-4-4 widens every channel" {
    var v: [2]u8 = undefined;
    var dst: [4]u8 = undefined;
    std.mem.writeInt(u16, &v, 0xFFFF, .little);
    try expand(&dst, &v, 1, 1, enums.GL_RGBA, enums.GL_UNSIGNED_SHORT_4_4_4_4, 1);
    try expectEqual([4]u8{ 255, 255, 255, 255 }, dst);
}

test "a packed type is legal only with the format it was defined for" {
    try expect(sourcePixelSize(enums.GL_RGB, enums.GL_UNSIGNED_SHORT_5_6_5) != null);
    try expect(sourcePixelSize(enums.GL_RGBA, enums.GL_UNSIGNED_SHORT_5_6_5) == null); // no alpha to give
    try expect(sourcePixelSize(enums.GL_RGB, enums.GL_UNSIGNED_SHORT_4_4_4_4) == null);
    var tmp: [4]u8 = undefined;
    try expectError(Error.BadFormat, expand(&tmp, &[_]u8{ 0, 0 }, 1, 1, enums.GL_RGBA, enums.GL_UNSIGNED_SHORT_5_6_5, 1));
}

test "short data is refused rather than read past" {
    var dst: [4 * 4]u8 = undefined;
    // 2x2 RGBA wants 16 bytes; give it 8.
    try expectError(Error.ShortData, expand(&dst, &[_]u8{0} ** 8, 2, 2, enums.GL_RGBA, enums.GL_UNSIGNED_BYTE, 1));
    // A destination too small is refused too.
    try expectError(Error.ShortData, expand(dst[0..4], &[_]u8{0} ** 16, 2, 2, enums.GL_RGBA, enums.GL_UNSIGNED_BYTE, 1));
}

test "the last row needs no padding — an unpadded final row is legal" {
    // 2x2 RGB, alignment 4: rows are 8 bytes, but the last row needs only its 6.
    const src = [_]u8{0} ** (8 + 6);
    var dst: [2 * 2 * 4]u8 = undefined;
    try expand(&dst, &src, 2, 2, enums.GL_RGB, enums.GL_UNSIGNED_BYTE, 4);
}

test "all ten paletted formats decode, and nothing else does" {
    const all = [_]GLenum{
        enums.GL_PALETTE4_RGB8_OES,     enums.GL_PALETTE4_RGBA8_OES,
        enums.GL_PALETTE4_R5_G6_B5_OES, enums.GL_PALETTE4_RGBA4_OES,
        enums.GL_PALETTE4_RGB5_A1_OES,  enums.GL_PALETTE8_RGB8_OES,
        enums.GL_PALETTE8_RGBA8_OES,    enums.GL_PALETTE8_R5_G6_B5_OES,
        enums.GL_PALETTE8_RGBA4_OES,    enums.GL_PALETTE8_RGB5_A1_OES,
    };
    try expectEqual(@as(usize, 10), all.len); // the mandatory extension's whole set
    for (all) |f| try expect(paletted(f) != null);
    try expect(paletted(enums.GL_RGBA) == null);

    // 4-bit formats have 16 entries, 8-bit have 256.
    try expectEqual(@as(u32, 16), paletted(enums.GL_PALETTE4_RGB8_OES).?.entries());
    try expectEqual(@as(u32, 256), paletted(enums.GL_PALETTE8_RGB8_OES).?.entries());
}

test "4-bit indices pack two pixels per byte, the first in the HIGH nibble" {
    const p = paletted(enums.GL_PALETTE4_RGBA8_OES).?;
    try expectEqual(@as(usize, 2), indexBytes(p, 4, 1)); // 4 pixels -> 2 bytes
    try expectEqual(@as(usize, 2), indexBytes(p, 3, 1)); // an odd width rounds up
    const p8 = paletted(enums.GL_PALETTE8_RGBA8_OES).?;
    try expectEqual(@as(usize, 4), indexBytes(p8, 4, 1));

    // 16 RGBA entries, then two pixels: index 1 then index 0.
    var src: [16 * 4 + 1]u8 = @splat(0);
    src[0 * 4 + 0] = 10; // entry 0 red
    src[1 * 4 + 0] = 20; // entry 1 red
    src[64] = 0x10; // high nibble = 1, low nibble = 0
    var dst: [2 * 4]u8 = undefined;
    try expandPaletted(&dst, &src, p, 2, 1, 0, 2, 1);
    try expectEqual(@as(u8, 20), dst[2]); // pixel 0 took entry 1 (R at BGRA index 2)
    try expectEqual(@as(u8, 10), dst[6]); // pixel 1 took entry 0
}

test "a paletted image carries its palette and its whole mip chain in one blob" {
    const p = paletted(enums.GL_PALETTE8_RGB8_OES).?;
    // 256 entries x 3 bytes, then 2x2 + 1x1 indices.
    const want = 256 * 3 + 4 + 1;
    try expectEqual(@as(?usize, want), palettedSize(p, 2, 2, 2));
}

test "expandPaletted skips earlier levels to find the one asked for" {
    const p = paletted(enums.GL_PALETTE8_RGBA8_OES).?;
    var src: [256 * 4 + 4 + 1]u8 = @splat(0);
    src[7 * 4 + 2] = 99; // entry 7, blue channel
    // Level 0 is 2x2 (4 indices), then level 1 is 1x1 at offset 256*4+4.
    src[256 * 4 + 4] = 7;
    var dst: [4]u8 = undefined;
    try expandPaletted(&dst, &src, p, 1, 1, 1, 2, 2); // level 1
    try expectEqual(@as(u8, 99), dst[0]); // entry 7's blue landed in B
}

test "a paletted blob that is too short is refused" {
    const p = paletted(enums.GL_PALETTE8_RGBA8_OES).?;
    var dst: [4]u8 = undefined;
    try expectError(Error.ShortData, expandPaletted(&dst, &[_]u8{0} ** 8, p, 1, 1, 0, 1, 1));
}
