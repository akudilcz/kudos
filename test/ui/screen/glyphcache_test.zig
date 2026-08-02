//! Host tests for the packed glyph sheet: sizes bake into one sheet, every glyph
//! lands inside it, the recorded boxes point at the ink that was actually drawn,
//! and the reported height is enough room for the bake it describes.

const std = @import("std");
const glyphcache = @import("glyphcache");
const truetype = @import("truetype");
const gltext = @import("gltext");

const FONT_BYTES = @embedFile("font_ttf");

const SHEET_W: u32 = 512;
const SHEET_H: u32 = 512;

fn face() truetype.Font {
    return truetype.Font.parse(FONT_BYTES) catch unreachable;
}

/// One bake into a heap sheet, so a test can look at both the pixels and the table.
const Baked = struct {
    sheet: []u8,
    sizes: []glyphcache.Size,
    usage: glyphcache.Usage,

    fn init(a: std.mem.Allocator, px: []const f32) !Baked {
        const sheet = try a.alloc(u8, SHEET_W * SHEET_H);
        @memset(sheet, 0);
        const sizes = try a.alloc(glyphcache.Size, px.len);
        const usage = try glyphcache.bake(face(), px, sheet, SHEET_W, SHEET_H, sizes);
        return .{ .sheet = sheet, .sizes = sizes, .usage = usage };
    }

    fn deinit(self: Baked, a: std.mem.Allocator) void {
        a.free(self.sheet);
        a.free(self.sizes);
    }
};

test "a bake fills one size table per requested size" {
    const a = std.testing.allocator;
    const b = try Baked.init(a, &.{ 14, 26 });
    defer b.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), b.sizes.len);
    try std.testing.expectEqual(@as(f32, 14), b.sizes[0].px);
    try std.testing.expectEqual(@as(f32, 26), b.sizes[1].px);
    // 95 printable characters minus the blank space glyph, twice over.
    try std.testing.expectEqual(@as(u32, 2 * (glyphcache.CHAR_COUNT - 1)), b.usage.placed);
}

test "every glyph box lies inside the sheet" {
    const a = std.testing.allocator;
    const b = try Baked.init(a, &.{ 11, 19, 40 });
    defer b.deinit(a);
    for (b.sizes) |*s| {
        for (s.glyphs) |g| {
            try std.testing.expect(g.u0 >= 0 and g.u1 <= 1);
            try std.testing.expect(g.v0 >= 0 and g.v1 <= 1);
            try std.testing.expect(g.u1 >= g.u0 and g.v1 >= g.v0);
        }
    }
}

test "a glyph's recorded box contains the ink that was drawn there" {
    const a = std.testing.allocator;
    const b = try Baked.init(a, &.{32});
    defer b.deinit(a);
    const g = b.sizes[0].glyph('M').?;
    try std.testing.expect(g.w > 0 and g.h > 0);
    const x0: u32 = @intFromFloat(@round(g.u0 * @as(f32, SHEET_W)));
    const y0: u32 = @intFromFloat(@round(g.v0 * @as(f32, SHEET_H)));
    var ink: u64 = 0;
    var row: u32 = 0;
    while (row < @as(u32, @intFromFloat(g.h))) : (row += 1) {
        var col: u32 = 0;
        while (col < @as(u32, @intFromFloat(g.w))) : (col += 1) {
            ink += b.sheet[(y0 + row) * SHEET_W + x0 + col];
        }
    }
    try std.testing.expect(ink > 0);
}

test "glyph boxes do not overlap" {
    const a = std.testing.allocator;
    const b = try Baked.init(a, &.{ 14, 22 });
    defer b.deinit(a);
    // Mark every box's texels; a second visit to any texel is an overlap.
    const marks = try a.alloc(bool, SHEET_W * SHEET_H);
    defer a.free(marks);
    @memset(marks, false);
    for (b.sizes) |*s| {
        for (s.glyphs) |g| {
            if (g.w == 0) continue;
            const x0: u32 = @intFromFloat(@round(g.u0 * @as(f32, SHEET_W)));
            const y0: u32 = @intFromFloat(@round(g.v0 * @as(f32, SHEET_H)));
            var row: u32 = 0;
            while (row < @as(u32, @intFromFloat(g.h))) : (row += 1) {
                var col: u32 = 0;
                while (col < @as(u32, @intFromFloat(g.w))) : (col += 1) {
                    const idx = (y0 + row) * SHEET_W + x0 + col;
                    try std.testing.expect(!marks[idx]);
                    marks[idx] = true;
                }
            }
        }
    }
}

test "space occupies no sheet room but still advances the pen" {
    const a = std.testing.allocator;
    const b = try Baked.init(a, &.{18});
    defer b.deinit(a);
    const sp = b.sizes[0].glyph(' ').?;
    try std.testing.expectEqual(@as(f32, 0), sp.w);
    try std.testing.expectEqual(@as(f32, 0), sp.h);
    try std.testing.expect(sp.advance > 0);
}

// RND-011: text metrics are reported to callers so layout matches what is drawn.
test "string width is the advance times the character count" {
    const a = std.testing.allocator;
    const b = try Baked.init(a, &.{16});
    defer b.deinit(a);
    const s = &b.sizes[0];
    const str = "cpu 37%";
    try std.testing.expectApproxEqAbs(s.width(str), gltext.glyphWidth(s.sheet(), str), 0.001);
    try std.testing.expectApproxEqAbs(s.advance * 7, s.width(str), 0.001);
}

test "vertical metrics grow with the size and bracket the ink" {
    const a = std.testing.allocator;
    const b = try Baked.init(a, &.{ 12, 48 });
    defer b.deinit(a);
    try std.testing.expect(b.sizes[1].ascent > b.sizes[0].ascent);
    try std.testing.expect(b.sizes[1].line_height > b.sizes[0].line_height);
    for (b.sizes) |*s| {
        try std.testing.expect(s.line_height >= s.ascent + s.descent);
        // 'M' rises no higher than the ascender; 'p' drops no lower than the descender.
        try std.testing.expect(-s.glyph('M').?.top <= s.ascent + 1);
        const p = s.glyph('p').?;
        try std.testing.expect(p.top + p.h <= s.descent + 1);
    }
}

test "the predicted sheet height is enough for the bake it predicts" {
    const f = face();
    const px = [_]f32{ 11, 14, 19, 26, 40 };
    const need = glyphcache.sheetHeight(f, &px, SHEET_W);
    try std.testing.expect(need > 0 and need <= SHEET_H);

    const a = std.testing.allocator;
    const sheet = try a.alloc(u8, SHEET_W * need);
    defer a.free(sheet);
    @memset(sheet, 0);
    const sizes = try a.alloc(glyphcache.Size, px.len);
    defer a.free(sizes);
    const usage = try glyphcache.bake(f, &px, sheet, SHEET_W, need, sizes);
    try std.testing.expect(usage.rows_used <= need);
}

test "a sheet too small is reported, not overrun" {
    const f = face();
    const a = std.testing.allocator;
    const sheet = try a.alloc(u8, 64 * 64);
    defer a.free(sheet);
    @memset(sheet, 0);
    var sizes: [1]glyphcache.Size = undefined;
    try std.testing.expectError(
        glyphcache.Error.AtlasFull,
        glyphcache.bake(f, &.{64}, sheet, 64, 64, &sizes),
    );
}

test "a size table shorter than the size list is reported" {
    const f = face();
    var sheet: [16]u8 = undefined;
    var sizes: [1]glyphcache.Size = undefined;
    try std.testing.expectError(
        glyphcache.Error.TableTooSmall,
        glyphcache.bake(f, &.{ 12, 14 }, &sheet, 4, 4, &sizes),
    );
}

test "PERF-016: a frame's text path reads the baked sheet and rasterises nothing" {
    const a = std.testing.allocator;
    var b = try Baked.init(a, &[_]f32{ 14, 20 });
    defer b.deinit(a);

    // What a frame does: measure the string, then look up every glyph in it.
    // Snapshot the sheet first — an on-demand rasterisation would have to write
    // ink into it, so byte-identity after the whole path IS the assertion.
    const before = try a.dupe(u8, b.sheet);
    defer a.free(before);
    for (b.sizes) |*sz| {
        var ch: u8 = glyphcache.FIRST_CHAR;
        while (ch < glyphcache.FIRST_CHAR + glyphcache.CHAR_COUNT) : (ch += 1) {
            try std.testing.expect(sz.glyph(ch) != null);
        }
        _ = sz.width("the quick brown fox jumps over the lazy dog");
        // A character the bake never covered is REPORTED ABSENT, not rasterised
        // on the spot — the frame has no path that could call the rasteriser.
        try std.testing.expect(sz.glyph(0x1F) == null);
        try std.testing.expect(sz.glyph(glyphcache.FIRST_CHAR + glyphcache.CHAR_COUNT) == null);
    }
    try std.testing.expectEqualSlices(u8, before, b.sheet);
}
