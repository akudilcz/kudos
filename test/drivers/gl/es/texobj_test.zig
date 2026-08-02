//! Host tests of src/drivers/gl/es/texobj.zig.

const std = @import("std");
const texobj = @import("texobj");
const GLenum = texobj.GLenum;
const enums = texobj.enums;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const externalPixelSize = texobj.externalPixelSize;
const isPalettedFormat = texobj.isPalettedFormat;
const storedFormat = texobj.storedFormat;

test "the ten paletted formats are recognised, and nothing else is" {
    // These are mandatory (OES_compressed_paletted_texture), so a missing one is a
    // conformance hole, not a missing nicety.
    const all = [_]GLenum{
        enums.GL_PALETTE4_RGB8_OES,     enums.GL_PALETTE4_RGBA8_OES,
        enums.GL_PALETTE4_R5_G6_B5_OES, enums.GL_PALETTE4_RGBA4_OES,
        enums.GL_PALETTE4_RGB5_A1_OES,  enums.GL_PALETTE8_RGB8_OES,
        enums.GL_PALETTE8_RGBA8_OES,    enums.GL_PALETTE8_R5_G6_B5_OES,
        enums.GL_PALETTE8_RGBA4_OES,    enums.GL_PALETTE8_RGB5_A1_OES,
    };
    try expectEqual(@as(usize, 10), all.len);
    for (all) |f| try expect(isPalettedFormat(f));
    try expect(!isPalettedFormat(enums.GL_RGBA));
}

test "external format and type pairs: only the standard's combinations" {
    try expectEqual(@as(?usize, 4), externalPixelSize(enums.GL_RGBA, enums.GL_UNSIGNED_BYTE));
    try expectEqual(@as(?usize, 3), externalPixelSize(enums.GL_RGB, enums.GL_UNSIGNED_BYTE));
    try expectEqual(@as(?usize, 1), externalPixelSize(enums.GL_ALPHA, enums.GL_UNSIGNED_BYTE));
    try expectEqual(@as(?usize, 2), externalPixelSize(enums.GL_LUMINANCE_ALPHA, enums.GL_UNSIGNED_BYTE));
    // A packed type carries a whole pixel in two bytes...
    try expectEqual(@as(?usize, 2), externalPixelSize(enums.GL_RGB, enums.GL_UNSIGNED_SHORT_5_6_5));
    try expectEqual(@as(?usize, 2), externalPixelSize(enums.GL_RGBA, enums.GL_UNSIGNED_SHORT_4_4_4_4));
    // ...but only with the format it was defined for: 5_6_5 has no alpha to give RGBA.
    try expectEqual(@as(?usize, null), externalPixelSize(enums.GL_RGBA, enums.GL_UNSIGNED_SHORT_5_6_5));
    try expectEqual(@as(?usize, null), externalPixelSize(enums.GL_RGB, enums.GL_UNSIGNED_SHORT_4_4_4_4));
    try expectEqual(@as(?usize, null), externalPixelSize(enums.GL_RGBA, enums.GL_FLOAT));
}

test "every external format has somewhere to be stored" {
    for ([_]GLenum{ enums.GL_ALPHA, enums.GL_LUMINANCE, enums.GL_LUMINANCE_ALPHA, enums.GL_RGB, enums.GL_RGBA }) |f|
        try expect(storedFormat(f) != null);
    try expect(storedFormat(enums.GL_TRIANGLES) == null);
}
