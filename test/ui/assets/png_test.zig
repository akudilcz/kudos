//! PNG decoder tests (src/ui/assets/png.zig).
//!
//! Synthetic PNGs are ENCODED in-test (chunk builder + per-row filter
//! transform + std.compress.zlib compressor), so every row filter, color
//! type, and error class is exercised against pixels the test itself chose.
//! Then the real thing: Duck.glb's embedded 512×512 palette texture is
//! decoded and checked against goldens computed by an independent Python
//! zlib reference decode (crc32 of the BGRA stream + sampled pixels).

const std = @import("std");
const png = @import("png");
const glb = @import("glb");

const ta = std.testing.allocator;

/// zlib-compress `raw` into `out` — the fixture-building half the tests share.
/// (Zig 0.15 folded std.compress.zlib into flate; this is the one home of the
/// new plumbing so each fixture stays a one-liner.)
fn zlibCompress(raw: []const u8, out: *std.array_list.Managed(u8)) !void {
    var aw: std.Io.Writer.Allocating = try .initCapacity(ta, 64);
    defer aw.deinit();
    const window = try ta.alloc(u8, std.compress.flate.max_window_len);
    defer ta.free(window);
    var cmp = try std.compress.flate.Compress.init(&aw.writer, window, .zlib, .level_4);
    try cmp.writer.writeAll(raw);
    try cmp.finish();
    try out.appendSlice(aw.written());
}

test {
    std.testing.refAllDecls(png);
}

// ── in-test PNG encoder ──────────────────────────────────────────────────

fn appendInt(out: *std.array_list.Managed(u8), v: u32, endian: std.builtin.Endian) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, endian);
    try out.appendSlice(&b);
}

fn writeChunk(out: *std.array_list.Managed(u8), ctype: *const [4]u8, data: []const u8) !void {
    try appendInt(out, @intCast(data.len), .big);
    try out.appendSlice(ctype);
    try out.appendSlice(data);
    var crc = std.hash.Crc32.init();
    crc.update(ctype);
    crc.update(data);
    try appendInt(out, crc.final(), .big);
}

const Spec = struct {
    w: u32,
    h: u32,
    depth: u8 = 8,
    color_type: u8,
    interlace: u8 = 0,
    plte: ?[]const u8 = null,
    trns: ?[]const u8 = null,
    /// Unfiltered scanlines (h * w * channels bytes).
    pixels: []const u8,
    /// Filter type to encode every row with.
    filter: u8 = 0,
    /// Split the compressed stream into two IDAT chunks.
    split_idat: bool = false,
};

fn channelsOf(color_type: u8) u32 {
    return switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        6 => 4,
        else => unreachable,
    };
}

/// Apply filter `f` to `pixels` (the inverse of decode's defilter) and
/// prepend the per-row filter byte.
fn filterEncode(a: std.mem.Allocator, spec: Spec) ![]u8 {
    const ch = channelsOf(spec.color_type);
    const rb: usize = @as(usize, spec.w) * ch;
    const raw = try a.alloc(u8, @as(usize, spec.h) * (rb + 1));
    var y: usize = 0;
    while (y < spec.h) : (y += 1) {
        raw[y * (rb + 1)] = spec.filter;
        const src = spec.pixels[y * rb ..][0..rb];
        const prev: ?[]const u8 = if (y > 0) spec.pixels[(y - 1) * rb ..][0..rb] else null;
        var x: usize = 0;
        while (x < rb) : (x += 1) {
            const a_: u32 = if (x >= ch) src[x - ch] else 0;
            const b_: u32 = if (prev) |p| p[x] else 0;
            const c_: u32 = if (prev != null and x >= ch) prev.?[x - ch] else 0;
            const predictor: u32 = switch (spec.filter) {
                0 => 0,
                1 => a_,
                2 => b_,
                3 => (a_ + b_) / 2,
                4 => paeth(a_, b_, c_),
                else => unreachable,
            };
            raw[y * (rb + 1) + 1 + x] = @truncate(src[x] -% predictor);
        }
    }
    return raw;
}

fn paeth(a: u32, b: u32, c: u32) u32 {
    const p: i32 = @as(i32, @intCast(a)) + @as(i32, @intCast(b)) - @as(i32, @intCast(c));
    const pa = @abs(p - @as(i32, @intCast(a)));
    const pb = @abs(p - @as(i32, @intCast(b)));
    const pc = @abs(p - @as(i32, @intCast(c)));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn makePng(spec: Spec) ![]u8 {
    var out = std.array_list.Managed(u8).init(ta);
    errdefer out.deinit();
    try out.appendSlice(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], spec.w, .big);
    std.mem.writeInt(u32, ihdr[4..8], spec.h, .big);
    ihdr[8] = spec.depth;
    ihdr[9] = spec.color_type;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = spec.interlace;
    try writeChunk(&out, "IHDR", &ihdr);
    if (spec.plte) |p| try writeChunk(&out, "PLTE", p);
    if (spec.trns) |t| try writeChunk(&out, "tRNS", t);

    const raw = try filterEncode(ta, spec);
    defer ta.free(raw);
    var compressed = std.array_list.Managed(u8).init(ta);
    defer compressed.deinit();
    try zlibCompress(raw, &compressed);

    if (spec.split_idat) {
        const half = compressed.items.len / 2;
        try writeChunk(&out, "IDAT", compressed.items[0..half]);
        try writeChunk(&out, "IDAT", compressed.items[half..]);
    } else {
        try writeChunk(&out, "IDAT", compressed.items);
    }
    try writeChunk(&out, "IEND", "");
    return out.toOwnedSlice();
}

fn decodeSpec(spec: Spec) !png.Image {
    const file = try makePng(spec);
    defer ta.free(file);
    return png.decode(ta, file);
}

/// Golden BGRA of an RGB/RGBA pixel stream (what decode must produce).
fn expectBgraFromRgb(img: png.Image, pixels: []const u8, ch: u32) !void {
    var i: usize = 0;
    while (i < @as(usize, img.w) * img.h) : (i += 1) {
        try std.testing.expectEqual(pixels[i * ch + 2], img.bgra[i * 4]); // B
        try std.testing.expectEqual(pixels[i * ch + 1], img.bgra[i * 4 + 1]); // G
        try std.testing.expectEqual(pixels[i * ch], img.bgra[i * 4 + 2]); // R
        const alpha: u8 = if (ch == 4) pixels[i * ch + 3] else 255;
        try std.testing.expectEqual(alpha, img.bgra[i * 4 + 3]);
    }
}

/// A deterministic 4×3 RGB gradient — enough variety that every filter's
/// predictor differs from the sample.
fn gradientRgb() [36]u8 {
    var px: [36]u8 = undefined;
    for (0..12) |i| {
        const x = i % 4;
        const y = i / 4;
        px[i * 3] = @truncate(x * 40 + y * 3);
        px[i * 3 + 1] = @truncate(200 -% x * 13 +% y * 31);
        px[i * 3 + 2] = @truncate(x * x * 7 +% y * 90);
    }
    return px;
}

// ── row filters ──────────────────────────────────────────────────────────

test "RGB decode round-trips through every filter type (0..4)" {
    const px = gradientRgb();
    inline for (0..5) |f| {
        const img = try decodeSpec(.{ .w = 4, .h = 3, .color_type = 2, .pixels = &px, .filter = f });
        defer img.deinit(ta);
        try std.testing.expectEqual(@as(u32, 4), img.w);
        try std.testing.expectEqual(@as(u32, 3), img.h);
        try expectBgraFromRgb(img, &px, 3);
    }
}

test "RGBA (type 6) carries alpha through; multiple IDAT chunks concatenate" {
    const px = [16]u8{ 255, 0, 0, 10, 0, 255, 0, 128, 0, 0, 255, 200, 9, 8, 7, 255 };
    const img = try decodeSpec(.{ .w = 2, .h = 2, .color_type = 6, .pixels = &px, .filter = 4, .split_idat = true });
    defer img.deinit(ta);
    try expectBgraFromRgb(img, &px, 4);
}

test "palette (type 3) with tRNS: colors from PLTE, alpha from tRNS, 255 past its end" {
    const plte = [12]u8{ 10, 20, 30, 200, 100, 50, 0, 0, 0, 250, 240, 230 };
    const trns = [2]u8{ 0, 77 }; // entries 2/3 default to alpha 255
    const px = [10]u8{ 0, 1, 2, 3, 0, 3, 2, 1, 0, 1 }; // 5×2 indices
    const img = try decodeSpec(.{ .w = 5, .h = 2, .color_type = 3, .plte = &plte, .trns = &trns, .pixels = &px, .filter = 1 });
    defer img.deinit(ta);
    for (px, 0..) |pi, i| {
        try std.testing.expectEqual(plte[@as(usize, pi) * 3 + 2], img.bgra[i * 4]); // B
        try std.testing.expectEqual(plte[@as(usize, pi) * 3 + 1], img.bgra[i * 4 + 1]);
        try std.testing.expectEqual(plte[@as(usize, pi) * 3], img.bgra[i * 4 + 2]);
        const want_a: u8 = if (pi < trns.len) trns[pi] else 255;
        try std.testing.expectEqual(want_a, img.bgra[i * 4 + 3]);
    }
}

// ── error taxonomy ───────────────────────────────────────────────────────

test "not a PNG / truncated chunk / corrupt CRC" {
    try std.testing.expectError(png.Error.PngBadSignature, png.decode(ta, "JFIF----"));
    const px = gradientRgb();
    const file = try makePng(.{ .w = 4, .h = 3, .color_type = 2, .pixels = &px });
    defer ta.free(file);
    // Truncate mid-chunk.
    try std.testing.expectError(png.Error.PngBadChunk, png.decode(ta, file[0 .. file.len - 6]));
    // Flip a byte inside IHDR's data: the stored CRC no longer matches.
    const corrupt = try ta.dupe(u8, file);
    defer ta.free(corrupt);
    corrupt[16] ^= 0x40;
    try std.testing.expectError(png.Error.PngBadCrc, png.decode(ta, corrupt));
}

test "unsupported: 16-bit, grayscale, Adam7, tRNS color key; bad header: zero dim; too large" {
    const px = gradientRgb();
    try std.testing.expectError(png.Error.PngUnsupported, decodeSpec(.{ .w = 4, .h = 3, .depth = 16, .color_type = 2, .pixels = &px }));
    const gray = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    try std.testing.expectError(png.Error.PngUnsupported, decodeSpec(.{ .w = 4, .h = 3, .color_type = 0, .pixels = &gray }));
    try std.testing.expectError(png.Error.PngUnsupported, decodeSpec(.{ .w = 4, .h = 3, .interlace = 1, .color_type = 2, .pixels = &px }));
    try std.testing.expectError(png.Error.PngUnsupported, decodeSpec(.{ .w = 4, .h = 3, .color_type = 2, .pixels = &px, .trns = &.{ 0, 0, 0, 0, 0, 0 } }));
    try std.testing.expectError(png.Error.PngBadHeader, decodeSpec(.{ .w = 0, .h = 3, .color_type = 2, .pixels = &.{} }));
    // Dimension cap fires at the header, before any pixel data is touched.
    var big = std.array_list.Managed(u8).init(ta);
    defer big.deinit();
    try big.appendSlice(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });
    var ihdr: [13]u8 = .{0} ** 13;
    std.mem.writeInt(u32, ihdr[0..4], png.MAX_DIM + 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = 2;
    try writeChunk(&big, "IHDR", &ihdr);
    try std.testing.expectError(png.Error.PngTooLarge, png.decode(ta, big.items));
}

test "bad data: missing PLTE, palette index out of range, bad filter byte, wrong stream length" {
    const idx = [4]u8{ 0, 1, 1, 0 };
    try std.testing.expectError(png.Error.PngMissingPalette, decodeSpec(.{ .w = 2, .h = 2, .color_type = 3, .pixels = &idx }));
    const oob = [4]u8{ 0, 5, 0, 0 }; // palette has 2 entries
    try std.testing.expectError(png.Error.PngBadData, decodeSpec(.{ .w = 2, .h = 2, .color_type = 3, .plte = &.{ 1, 2, 3, 4, 5, 6 }, .pixels = &oob }));

    // Filter byte 7: encode filter 0 then patch the raw stream. Rebuild by
    // hand: compress a raw block whose first row filter byte is 7.
    var raw: [2 * (2 * 3 + 1)]u8 = .{0} ** 14;
    raw[0] = 7;
    var compressed = std.array_list.Managed(u8).init(ta);
    defer compressed.deinit();
    try zlibCompress(raw[0..], &compressed);
    var file = std.array_list.Managed(u8).init(ta);
    defer file.deinit();
    try file.appendSlice(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });
    var ihdr: [13]u8 = .{0} ** 13;
    std.mem.writeInt(u32, ihdr[0..4], 2, .big);
    std.mem.writeInt(u32, ihdr[4..8], 2, .big);
    ihdr[8] = 8;
    ihdr[9] = 2;
    try writeChunk(&file, "IHDR", &ihdr);
    try writeChunk(&file, "IDAT", compressed.items);
    try writeChunk(&file, "IEND", "");
    try std.testing.expectError(png.Error.PngBadData, png.decode(ta, file.items));

    // Stream shorter than h*(row+1): claim 2x2 but compress one row.
    var short = std.array_list.Managed(u8).init(ta);
    defer short.deinit();
    try zlibCompress(raw[0..7], &short);
    var file2 = std.array_list.Managed(u8).init(ta);
    defer file2.deinit();
    try file2.appendSlice(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });
    try writeChunk(&file2, "IHDR", &ihdr);
    try writeChunk(&file2, "IDAT", short.items);
    try writeChunk(&file2, "IEND", "");
    try std.testing.expectError(png.Error.PngBadData, png.decode(ta, file2.items));
}

// ── the real thing: Duck.glb's embedded texture ──────────────────────────

// IMG-001: PNG images are decoded natively — checked against an INDEPENDENT
// decode of the same file, not against this decoder's own output.
test "Duck.glb texture: 512x512 palette PNG matches the Python reference decode" {
    const model = try glb.parse(ta, @embedFile("model_duck"));
    defer model.deinit(ta);
    const img = try png.decode(ta, model.submeshes[0].tex.?);
    defer img.deinit(ta);
    try std.testing.expectEqual(@as(u32, 512), img.w);
    try std.testing.expectEqual(@as(u32, 512), img.h);
    // Golden crc32 of the whole BGRA stream (independent Python decode).
    try std.testing.expectEqual(@as(u32, 0x1b357055), std.hash.Crc32.hash(img.bgra));
    // Sampled pixels (B,G,R,A) from the same reference.
    const samples = [_]struct { x: u32, y: u32, bgra: [4]u8 }{
        .{ .x = 0, .y = 0, .bgra = .{ 0, 191, 225, 255 } },
        .{ .x = 256, .y = 256, .bgra = .{ 0, 216, 255, 255 } },
        .{ .x = 100, .y = 400, .bgra = .{ 0, 216, 255, 255 } },
        .{ .x = 511, .y = 511, .bgra = .{ 0, 191, 225, 255 } },
    };
    for (samples) |s| {
        const at = (@as(usize, s.y) * 512 + s.x) * 4;
        try std.testing.expectEqualSlices(u8, &s.bgra, img.bgra[at .. at + 4]);
    }
}
