//! JPEG decoder tests (src/ui/assets/jpeg.zig).
//!
//! Real .jpg fixtures (test/ui/assets/fixtures/jpeg_*.jpg, produced by ImageMagick =
//! libjpeg-turbo 2.1.5) are decoded and compared PIXEL-EXACT against .ppm
//! goldens decoded by that same libjpeg-turbo — but with FANCY UPSAMPLING
//! DISABLED (`-define jpeg:fancy-upsampling=off`), because jpeg.zig uses
//! replicating/box chroma upsampling. Under that matching upsample the decode
//! is bit-exact for every fixture: baseline
//! (SOF0), progressive (SOF2), 4:4:4 / 4:2:2 / 4:2:0 subsampling, restart
//! markers (DRI/RSTn), and grayscale. A tiny per-channel tolerance is allowed
//! only as a safety net (IDCT rounding can differ by ±1 LSB between builds);
//! see TOLERANCE below.
//!
//! The loud-rejection matrix (arithmetic, lossless, CMYK, truncated, non-JPEG)
//! asserts the specific Error, mirroring png.zig's "never a silently-wrong
//! texture" contract.

const std = @import("std");
const jpeg = @import("jpeg");

const ta = std.testing.allocator;

test {
    std.testing.refAllDecls(jpeg);
}

/// Max allowed per-channel abs difference vs the golden. The fixtures decode
/// bit-exact (tolerance could be 0), but ±1 guards against a benign IDCT
/// rounding drift without hiding a real bug (a broken decode is off by tens).
const TOLERANCE: u8 = 1;

const Ppm = struct {
    w: u32,
    h: u32,
    rgb: []const u8, // w*h*3, interleaved R,G,B (borrows the input)
};

/// Parse a binary P6 PPM header + pixel span (what ImageMagick writes).
fn parsePpm(bytes: []const u8) !Ppm {
    if (bytes.len < 2 or bytes[0] != 'P' or bytes[1] != '6') return error.NotPpm;
    var i: usize = 2;
    var vals: [3]u32 = undefined; // width, height, maxval
    var vi: usize = 0;
    while (vi < 3) : (vi += 1) {
        // skip whitespace + comments
        while (i < bytes.len) {
            const c = bytes[i];
            if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
                i += 1;
            } else if (c == '#') {
                while (i < bytes.len and bytes[i] != '\n') i += 1;
            } else break;
        }
        var v: u32 = 0;
        var any = false;
        while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') {
            v = v * 10 + (bytes[i] - '0');
            i += 1;
            any = true;
        }
        if (!any) return error.NotPpm;
        vals[vi] = v;
    }
    if (vals[2] != 255) return error.UnexpectedMaxval;
    i += 1; // exactly one whitespace byte separates the header from the data
    const w = vals[0];
    const h = vals[1];
    const need = @as(usize, w) * h * 3;
    if (i + need > bytes.len) return error.PpmShort;
    return .{ .w = w, .h = h, .rgb = bytes[i .. i + need] };
}

/// Decode `jpg` and assert it matches the box-upsampled golden `ppm`.
fn expectMatches(jpg: []const u8, ppm_bytes: []const u8) !void {
    const gold = try parsePpm(ppm_bytes);
    const img = try jpeg.decode(ta, jpg);
    defer img.deinit(ta);
    try std.testing.expectEqual(gold.w, img.w);
    try std.testing.expectEqual(gold.h, img.h);
    var p: usize = 0;
    const n = @as(usize, img.w) * img.h;
    while (p < n) : (p += 1) {
        const gr = gold.rgb[p * 3];
        const gg = gold.rgb[p * 3 + 1];
        const gb = gold.rgb[p * 3 + 2];
        const b = img.bgra[p * 4]; // BGRA layout
        const g = img.bgra[p * 4 + 1];
        const r = img.bgra[p * 4 + 2];
        const aa = img.bgra[p * 4 + 3];
        try std.testing.expectEqual(@as(u8, 255), aa); // opaque
        if (diff(gr, r) > TOLERANCE or diff(gg, g) > TOLERANCE or diff(gb, b) > TOLERANCE) {
            std.debug.print("pixel {d} ({d},{d}): golden RGB=({d},{d},{d}) got=({d},{d},{d})\n", .{
                p, p % img.w, p / img.w, gr, gg, gb, r, g, b,
            });
            return error.PixelMismatch;
        }
    }
}

fn diff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

// ── real-fixture decode: baseline, progressive, subsampling, restart, gray ───

test "baseline 4:4:4 (SOF0, no subsampling) decodes bit-exact" {
    try expectMatches(@embedFile("fixtures/jpeg_baseline_444.jpg"), @embedFile("fixtures/jpeg_baseline_444.ppm"));
}

test "baseline 4:2:2 (SOF0, 2x1 horizontal subsample) decodes" {
    try expectMatches(@embedFile("fixtures/jpeg_baseline_422.jpg"), @embedFile("fixtures/jpeg_baseline_422.ppm"));
}

test "baseline 4:2:0 (SOF0, 2x2 subsample — the common case) decodes" {
    try expectMatches(@embedFile("fixtures/jpeg_baseline_420.jpg"), @embedFile("fixtures/jpeg_baseline_420.ppm"));
}

test "baseline 4:2:0 with restart markers (DRI/RSTn) decodes" {
    try expectMatches(@embedFile("fixtures/jpeg_baseline_rst.jpg"), @embedFile("fixtures/jpeg_baseline_rst.ppm"));
}

test "progressive 4:2:0 (SOF2, spectral selection + successive approximation) decodes" {
    try expectMatches(@embedFile("fixtures/jpeg_progressive_420.jpg"), @embedFile("fixtures/jpeg_progressive_420.ppm"));
}

test "progressive 4:2:2 (SOF2) decodes" {
    try expectMatches(@embedFile("fixtures/jpeg_progressive_422.jpg"), @embedFile("fixtures/jpeg_progressive_422.ppm"));
}

test "grayscale baseline (1-component) decodes to replicated luma" {
    try expectMatches(@embedFile("fixtures/jpeg_gray.jpg"), @embedFile("fixtures/jpeg_gray.ppm"));
}

// ── loud rejections ──────────────────────────────────────────────────────────

test "not a JPEG: missing SOI is a loud marker error" {
    try std.testing.expectError(jpeg.Error.JpegBadMarker, jpeg.decode(ta, "PK\x03\x04not a jpeg"));
    try std.testing.expectError(jpeg.Error.JpegBadMarker, jpeg.decode(ta, "\xff\xd7short"));
}

test "truncated stream (header cut mid-way) is JpegTruncated" {
    const full = @embedFile("fixtures/jpeg_baseline_420.jpg");
    // Cut inside the header region (well before EOI), so a segment length runs
    // off the buffer.
    try std.testing.expectError(jpeg.Error.JpegTruncated, jpeg.decode(ta, full[0..40]));
}

test "CMYK / 4-component (YCCK) is rejected: JpegUnsupportedComponents" {
    try std.testing.expectError(jpeg.Error.JpegUnsupportedComponents, jpeg.decode(ta, @embedFile("fixtures/jpeg_cmyk.jpg")));
}

test "arithmetic coding (SOF9) is rejected loudly" {
    // Patch a baseline fixture's SOF0 (0xC0) to SOF9 (0xC9, arithmetic).
    const src = @embedFile("fixtures/jpeg_baseline_444.jpg");
    const buf = try ta.dupe(u8, src);
    defer ta.free(buf);
    const i = std.mem.indexOf(u8, buf, &.{ 0xFF, 0xC0 }).?;
    buf[i + 1] = 0xC9;
    try std.testing.expectError(jpeg.Error.JpegArithmetic, jpeg.decode(ta, buf));
}

test "lossless (SOF3) is rejected as an unsupported mode" {
    const src = @embedFile("fixtures/jpeg_baseline_444.jpg");
    const buf = try ta.dupe(u8, src);
    defer ta.free(buf);
    const i = std.mem.indexOf(u8, buf, &.{ 0xFF, 0xC0 }).?;
    buf[i + 1] = 0xC3;
    try std.testing.expectError(jpeg.Error.JpegUnsupportedMode, jpeg.decode(ta, buf));
}

test "12-bit precision is rejected (JpegUnsupportedPrecision)" {
    // Patch the SOF0 precision byte (offset +4 past the FF C0) from 8 to 12.
    const src = @embedFile("fixtures/jpeg_baseline_444.jpg");
    const buf = try ta.dupe(u8, src);
    defer ta.free(buf);
    const i = std.mem.indexOf(u8, buf, &.{ 0xFF, 0xC0 }).?;
    // SOF0: FF C0, 2-byte length, then precision byte.
    buf[i + 4] = 12;
    try std.testing.expectError(jpeg.Error.JpegUnsupportedPrecision, jpeg.decode(ta, buf));
}
