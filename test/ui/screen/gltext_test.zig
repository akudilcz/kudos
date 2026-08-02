//! Host tests of src/ui/screen/gltext.zig.

const std = @import("std");
const gltext = @import("gltext");
/// The system font's atlas layout (font_roboto.atlas header), as a plain
/// fixture — the geometry under test is independent of the real glyph pixels.
const ROBOTO = gltext.Atlas{ .cell_w = 9, .cell_h = 19, .first = 0x20, .count = 95 };
fn approx(a: f32, b: f32) bool {
    return @abs(a - b) <= 0.001;
}
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const glyphFloats = gltext.glyphFloats;
const string = gltext.string;
const width = gltext.width;

test "each glyph is a 6-vertex quad; the pen advances one cell" {
    var pos: [glyphFloats(3)]f32 = undefined;
    var uv: [glyphFloats(3)]f32 = undefined;
    const n = string(&pos, &uv, ROBOTO, "AbC", 100, 50);
    try expectEqual(@as(u32, 3), n);
    // First glyph's top-left is the pen.
    try expect(approx(pos[0], 100) and approx(pos[1], 50));
    // Second glyph starts one cell (9px) to the right: vertex 6 (index 12) is its TL.
    try expect(approx(pos[12], 109) and approx(pos[13], 50));
    // Third glyph another cell over.
    try expect(approx(pos[24], 118));
}

test "the texcoord v-span selects the glyph's row in the strip" {
    var pos: [glyphFloats(1)]f32 = undefined;
    var uv: [glyphFloats(1)]f32 = undefined;
    // 'A' is 0x41; index = 0x41 - 0x20 = 33 of 95.
    _ = string(&pos, &uv, ROBOTO, "A", 0, 0);
    const i: f32 = 33;
    const n: f32 = 95;
    // First vertex uv is (0, i/n); the bottom vertices use (i+1)/n.
    try expect(approx(uv[0], 0) and approx(uv[1], i / n));
    try expect(approx(uv[5], (i + 1) / n)); // vertex 2 (BL) v-coord
}

test "a non-printable byte advances the pen but emits nothing" {
    var pos: [glyphFloats(3)]f32 = undefined;
    var uv: [glyphFloats(3)]f32 = undefined;
    // Tab (0x09) is outside [0x20,0x7F): emitted count is 2, but 'B' lands two
    // cells over — the blank still took a column.
    const n = string(&pos, &uv, ROBOTO, "A\tB", 0, 0);
    try expectEqual(@as(u32, 2), n);
    // Second EMITTED glyph ('B') is at x = 2*9 = 18 (the tab consumed column 1).
    try expect(approx(pos[12], 18));
}

test "width is monospace cells across, printable or not" {
    try expect(approx(width(ROBOTO, "hello"), 45)); // 5 * 9
    try expect(approx(width(ROBOTO, ""), 0));
}

test "proportional atlas: the pen advances per glyph and uv clips to the advance slice" {
    // A 3-glyph proportional atlas — advances 4/6/10 px in a 16px cell.
    const advs = [_]u8{ 4, 6, 10 };
    const prop = gltext.Atlas{ .cell_w = 16, .cell_h = 19, .first = ' ', .count = 3, .advances = &advs };
    // Width is the sum of advances, not count × cell.
    try expect(approx(width(prop, " !\""), 4 + 6 + 10));
    try expect(approx(prop.advance('!'), 6));
    var pos: [glyphFloats(3)]f32 = undefined;
    var uv: [glyphFloats(3)]f32 = undefined;
    _ = string(&pos, &uv, prop, " !\"", 0, 0);
    // Second glyph '!' begins after the space's 4px advance...
    try expect(approx(pos[12], 4)); // '!' top-left x
    try expect(approx(pos[14], 10)); // '!' top-right x = 4 + advance(6)
    // ...and its quad samples only the advance/cell_w = 6/16 left slice of the cell.
    try expect(approx(uv[14], 6.0 / 16.0)); // top-right u
}
