//! Host tests for the TrueType rasteriser: the real shipped face is parsed, its
//! metrics checked against the values the atlas generator derives from the same
//! file, and glyphs are rasterised at several sizes to prove the outline decoder,
//! the flattener and the scanline filler agree about where ink belongs.

const std = @import("std");
const truetype = @import("truetype");

/// The shipped face — the same file scripts/gen-font.py bakes its atlas from.
const FONT_BYTES = @embedFile("font_ttf");

fn face() truetype.Font {
    return truetype.Font.parse(FONT_BYTES) catch unreachable;
}

/// Coverage sum over a rasterised glyph — the "how much ink" measure the shape
/// assertions below are built on.
fn inkOf(f: truetype.Font, cp: u21, px: f32, buf: []u8) struct { m: truetype.Metrics, ink: u64 } {
    @memset(buf, 0);
    const gid = f.glyphIndex(cp);
    const m = f.rasterize(gid, px, buf, truetype.MAX_GLYPH_WIDTH) catch unreachable;
    var sum: u64 = 0;
    var row: u32 = 0;
    while (row < m.height) : (row += 1) {
        var col: u32 = 0;
        while (col < m.width) : (col += 1) sum += buf[row * truetype.MAX_GLYPH_WIDTH + col];
    }
    return .{ .m = m, .ink = sum };
}

test "parse reports the face's design metrics" {
    const f = face();
    try std.testing.expectEqual(@as(u16, 2048), f.units_per_em);
    try std.testing.expect(f.num_glyphs > 100);
    try std.testing.expect(f.ascent > 0);
    try std.testing.expect(f.descent < 0);
}

test "cmap maps ASCII to distinct glyphs and rejects the unmapped" {
    const f = face();
    const a = f.glyphIndex('A');
    const b = f.glyphIndex('B');
    try std.testing.expect(a != 0);
    try std.testing.expect(b != 0);
    try std.testing.expect(a != b);
    // A code point no text face carries maps to .notdef rather than to garbage.
    try std.testing.expectEqual(@as(u16, 0), f.glyphIndex(0x10FFFD));
}

test "the face is monospaced: every printable ASCII glyph shares one advance" {
    const f = face();
    const want: i32 = f.advanceUnits(f.glyphIndex('M'));
    try std.testing.expect(want > 0);
    var cp: u21 = 0x21;
    while (cp <= 0x7E) : (cp += 1) {
        // Roboto Mono's design advance is 1229/2048 em, but '-' and 'f' carry
        // 1230 — a rounding artefact in the face itself, well under a tenth of a
        // pixel at any UI size. One unit of slack keeps the assertion about
        // monospacing rather than about the vendor's rounding.
        const got: i32 = f.advanceUnits(f.glyphIndex(cp));
        try std.testing.expect(@abs(got - want) <= 1);
    }
}

// RND-009: glyphs rasterise from outlines at ANY requested pixel size — a
// size-quantised or atlas-only path cannot satisfy a linear advance.
test "advance scales linearly with the requested pixel size" {
    const f = face();
    const gid = f.glyphIndex('M');
    const at14 = f.advancePx(gid, 14);
    const at28 = f.advancePx(gid, 28);
    try std.testing.expectApproxEqAbs(at14 * 2, at28, 0.001);
    // 1229/2048 em × 14 px = 8.40 px. The baked 9 px cell in font.zig is the
    // CEILING of that (scripts/gen-font.py), so the rasteriser and the atlas
    // agree: a run of text laid out on the true advance is fractionally tighter
    // than the same run on the baked grid.
    try std.testing.expectApproxEqAbs(@as(f32, 8.40), at14, 0.01);
    try std.testing.expectEqual(@as(u32, 9), @as(u32, @intFromFloat(@ceil(at14))));
}

test "space is blank and still advances" {
    const f = face();
    var buf: [truetype.MAX_GLYPH_WIDTH * 128]u8 = undefined;
    const r = inkOf(f, ' ', 32, &buf);
    try std.testing.expectEqual(@as(u32, 0), r.m.width);
    try std.testing.expectEqual(@as(u64, 0), r.ink);
    try std.testing.expect(r.m.advance > 0);
}

test "a rasterised glyph has ink, fits its box, and sits above the baseline" {
    const f = face();
    var buf: [truetype.MAX_GLYPH_WIDTH * 128]u8 = undefined;
    const r = inkOf(f, 'M', 32, &buf);
    try std.testing.expect(r.m.width > 0 and r.m.height > 0);
    try std.testing.expect(r.ink > 0);
    // 'M' is a cap-height glyph: it rises above the baseline and does not descend.
    try std.testing.expect(r.m.top < 0);
    try std.testing.expect(@as(i32, @intCast(r.m.height)) + r.m.top <= 1);
    // Cap height is around 70% of the em; allow a wide band, catch nonsense.
    try std.testing.expect(r.m.height >= 16 and r.m.height <= 32);
}

test "a descender drops below the baseline" {
    const f = face();
    var buf: [truetype.MAX_GLYPH_WIDTH * 128]u8 = undefined;
    const p = inkOf(f, 'p', 48, &buf);
    // top is the distance up from the baseline; height carries it past it again.
    try std.testing.expect(@as(i32, @intCast(p.m.height)) + p.m.top > 1);
}

test "ink grows with size, roughly as area" {
    const f = face();
    var buf: [truetype.MAX_GLYPH_WIDTH * 256]u8 = undefined;
    const small = inkOf(f, 'M', 16, &buf);
    const large = inkOf(f, 'M', 64, &buf);
    const ratio = @as(f64, @floatFromInt(large.ink)) / @as(f64, @floatFromInt(small.ink));
    // Four times the size is sixteen times the area; rasteriser error and hinting
    // absence move it, so assert the order of magnitude, not the exact figure.
    try std.testing.expect(ratio > 10.0 and ratio < 22.0);
}

test "a filled glyph is solid in the middle and antialiased at the edges (RND-010)" {
    const f = face();
    var buf: [truetype.MAX_GLYPH_WIDTH * 128]u8 = undefined;
    @memset(&buf, 0);
    const gid = f.glyphIndex('|');
    const m = try f.rasterize(gid, 40, &buf, truetype.MAX_GLYPH_WIDTH);
    try std.testing.expect(m.width > 0 and m.height > 0);
    // The bar's middle row must be fully covered somewhere across its width.
    const mid_row = m.height / 2;
    var peak: u8 = 0;
    var col: u32 = 0;
    while (col < m.width) : (col += 1) peak = @max(peak, buf[mid_row * truetype.MAX_GLYPH_WIDTH + col]);
    try std.testing.expectEqual(@as(u8, 255), peak);
    // Antialiasing (RND-010): the outline's edges carry PARTIAL coverage — a
    // rasteriser that only ever writes 0 or 255 is a bitmapper, not this one.
    var partial = false;
    var row: u32 = 0;
    while (row < m.height) : (row += 1) {
        col = 0;
        while (col < m.width) : (col += 1) {
            const v = buf[row * truetype.MAX_GLYPH_WIDTH + col];
            if (v > 0 and v < 255) partial = true;
        }
    }
    try std.testing.expect(partial);
}

test "every printable ASCII glyph rasterises without error at UI sizes" {
    const f = face();
    var buf: [truetype.MAX_GLYPH_WIDTH * 256]u8 = undefined;
    for ([_]f32{ 11, 14, 19, 26, 40, 64 }) |px| {
        var cp: u21 = 0x20;
        while (cp <= 0x7E) : (cp += 1) {
            @memset(&buf, 0);
            const gid = f.glyphIndex(cp);
            const m = try f.rasterize(gid, px, &buf, truetype.MAX_GLYPH_WIDTH);
            try std.testing.expect(m.height <= 256);
            try std.testing.expect(m.advance > 0);
        }
    }
}

test "a truncated font is reported, not read past" {
    try std.testing.expectError(truetype.Error.BadFormat, truetype.Font.parse(FONT_BYTES[0..8]));
    try std.testing.expectError(truetype.Error.BadFormat, truetype.Font.parse("not a font"));
}
