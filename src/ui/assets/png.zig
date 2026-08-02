//! PNG decoder — PURE module (std only), host-tested (test/ui/assets/png_test.zig).
//! Decodes the embedded base-color textures GLB models carry into the BGRA8
//! layout the kGL texture unit samples (tex.zig ticPitchBgra8 — byte order B,G,R,A =
//! little-endian 0xAARRGGBB, straight alpha).
//!
//! Supported subset (PNG spec, https://www.w3.org/TR/png-3/): bit depth 8,
//! color types 2 (RGB), 3 (palette, with optional tRNS alpha), 6 (RGBA),
//! non-interlaced, all five row filters, multiple IDAT chunks, per-chunk
//! CRC-32 verified (std.hash.Crc32 is the PNG polynomial), zlib inflate via
//! std.compress.zlib (which checks the adler32). Everything else — 16-bit,
//! grayscale, Adam7, color-key tRNS on RGB — is a distinct loud error, never
//! a silently-wrong texture.

const std = @import("std");

pub const Error = error{
    PngBadSignature, // not a PNG at all
    PngBadChunk, // chunk structure truncated / IHDR not first / no IDAT
    PngBadCrc, // a chunk's CRC-32 mismatches (corrupt file)
    PngBadHeader, // IHDR field invalid (zero dim, bad compression/filter)
    PngUnsupported, // valid PNG outside the subset (depth/type/interlace/tRNS-on-RGB)
    PngTooLarge, // dimension beyond MAX_DIM (texture-unit sanity bound)
    PngMissingPalette, // color type 3 with no PLTE
    PngBadData, // inflate failure, wrong decompressed size, bad filter/palette index
} || std.mem.Allocator.Error;

/// Hard upper bound per axis: larger than any sane base-color texture, small
/// enough that w*h*4 cannot approach overflow (8192² × 4 = 256 MiB).
pub const MAX_DIM: u32 = 8192;

pub const Image = struct {
    w: u32,
    h: u32,
    bgra: []u8, // w*h*4, rows top-down, bytes B,G,R,A

    pub fn deinit(self: Image, a: std.mem.Allocator) void {
        a.free(self.bgra);
    }
};

/// The 8-byte PNG file signature (PNG spec §5.2) — public so a caller that
/// sniffs a byte stream's format checks the one authoritative copy.
pub const SIGNATURE = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

pub fn decode(a: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &SIGNATURE)) return Error.PngBadSignature;

    // ── chunk walk: IHDR fields + PLTE/tRNS slices + IDAT total ──────────
    var w: u32 = 0;
    var h: u32 = 0;
    var color_type: u8 = 0;
    var seen_ihdr = false;
    var plte: ?[]const u8 = null;
    var trns: ?[]const u8 = null;
    var idat_len: usize = 0;
    var seen_iend = false;

    var off: usize = 8;
    while (off < bytes.len) {
        if (bytes.len - off < 12) return Error.PngBadChunk;
        const len = std.mem.readInt(u32, bytes[off..][0..4], .big);
        if (bytes.len - off - 12 < len) return Error.PngBadChunk;
        const ctype = bytes[off + 4 .. off + 8];
        const data = bytes[off + 8 .. off + 8 + len];
        const crc_stored = std.mem.readInt(u32, bytes[off + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[off + 4 .. off + 8 + len]) != crc_stored) return Error.PngBadCrc;

        if (!seen_ihdr and !std.mem.eql(u8, ctype, "IHDR")) return Error.PngBadChunk;
        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (seen_ihdr or len != 13) return Error.PngBadChunk;
            seen_ihdr = true;
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            const depth = data[8];
            color_type = data[9];
            const compression = data[10];
            const filter = data[11];
            const interlace = data[12];
            if (w == 0 or h == 0 or compression != 0 or filter != 0) return Error.PngBadHeader;
            if (w > MAX_DIM or h > MAX_DIM) return Error.PngTooLarge;
            if (depth != 8) return Error.PngUnsupported;
            if (color_type != 2 and color_type != 3 and color_type != 6) return Error.PngUnsupported;
            if (interlace != 0) return Error.PngUnsupported;
        } else if (std.mem.eql(u8, ctype, "PLTE")) {
            if (len == 0 or len % 3 != 0 or len / 3 > 256) return Error.PngBadChunk;
            plte = data;
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            idat_len += len;
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            seen_iend = true;
            break;
        } // ancillary chunks (pHYs, tEXt, …) are skipped
        off += 12 + len;
    }
    if (!seen_ihdr or !seen_iend or idat_len == 0) return Error.PngBadChunk;

    const channels: u32 = switch (color_type) {
        2 => 3,
        3 => 1,
        6 => 4,
        else => unreachable, // IHDR admitted only these
    };
    const palette = if (color_type == 3) (plte orelse return Error.PngMissingPalette) else null;
    // Color-key transparency (tRNS on an RGB image) would silently decode
    // opaque — outside the subset, loud.
    if (color_type != 3 and trns != null) return Error.PngUnsupported;
    if (trns) |t| if (t.len > palette.?.len / 3) return Error.PngBadChunk;

    // ── scratch: concatenated IDAT + the raw (filtered) scanlines ────────
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idat = try arena.alloc(u8, idat_len);
    {
        var at: usize = 0;
        off = 8;
        while (off < bytes.len) {
            const len = std.mem.readInt(u32, bytes[off..][0..4], .big);
            if (std.mem.eql(u8, bytes[off + 4 .. off + 8], "IDAT")) {
                @memcpy(idat[at .. at + len], bytes[off + 8 .. off + 8 + len]);
                at += len;
            }
            if (std.mem.eql(u8, bytes[off + 4 .. off + 8], "IEND")) break;
            off += 12 + len;
        }
    }

    const row_bytes: usize = @as(usize, w) * channels;
    const raw = try arena.alloc(u8, @as(usize, h) * (row_bytes + 1));
    {
        // THE DECOMPRESSOR AND ITS WINDOW MUST NEVER EXIST ON A STACK. The
        // LZ77 history window is 64 KiB — larger than any stack kudos has
        // (64 KiB at boot, 32 KiB per task). Overflowing one does not panic: it
        // runs off the end into the page tables and triple-faults, silently.
        // Everything, including the fixed input reader the decompressor holds a
        // pointer into, lives in the arena.
        const in = try arena.create(std.Io.Reader);
        in.* = .fixed(idat);
        const window = try arena.alloc(u8, std.compress.flate.max_window_len);
        const inflate = try arena.create(std.compress.flate.Decompress);
        inflate.* = .init(in, .zlib, window);
        const r = &inflate.reader;
        r.readSliceAll(raw) catch return Error.PngBadData; // short stream
        if (r.takeByte()) |_| {
            return Error.PngBadData; // stream longer than the image
        } else |_| {}
    }

    defilter(raw, h, row_bytes, channels) catch return Error.PngBadData;

    // ── swizzle to BGRA8 ─────────────────────────────────────────────────
    const out = try a.alloc(u8, @as(usize, w) * h * 4);
    errdefer a.free(out);
    var y: usize = 0;
    var o: usize = 0;
    while (y < h) : (y += 1) {
        const line = raw[y * (row_bytes + 1) + 1 ..][0..row_bytes];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            switch (color_type) {
                2 => {
                    out[o] = line[x * 3 + 2]; // B
                    out[o + 1] = line[x * 3 + 1]; // G
                    out[o + 2] = line[x * 3]; // R
                    out[o + 3] = 255;
                },
                6 => {
                    out[o] = line[x * 4 + 2];
                    out[o + 1] = line[x * 4 + 1];
                    out[o + 2] = line[x * 4];
                    out[o + 3] = line[x * 4 + 3];
                },
                3 => {
                    const pi: usize = line[x];
                    const pal = palette.?;
                    if (pi * 3 + 3 > pal.len) return Error.PngBadData;
                    out[o] = pal[pi * 3 + 2];
                    out[o + 1] = pal[pi * 3 + 1];
                    out[o + 2] = pal[pi * 3];
                    out[o + 3] = if (trns) |t| (if (pi < t.len) t[pi] else 255) else 255;
                },
                else => unreachable,
            }
            o += 4;
        }
    }
    return .{ .w = w, .h = h, .bgra = out };
}

/// Undo the per-row filter in place (PNG spec §9; `bpp` = bytes per pixel,
/// which equals the channel count at bit depth 8). Row layout in `raw`:
/// filter byte + row_bytes of filtered samples.
fn defilter(raw: []u8, h: u32, row_bytes: usize, bpp: u32) error{BadFilter}!void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const f = raw[y * (row_bytes + 1)];
        const line = raw[y * (row_bytes + 1) + 1 ..][0..row_bytes];
        const prev: ?[]const u8 = if (y > 0) raw[(y - 1) * (row_bytes + 1) + 1 ..][0..row_bytes] else null;
        var x: usize = 0;
        while (x < row_bytes) : (x += 1) {
            const a: u32 = if (x >= bpp) line[x - bpp] else 0; // left
            const b: u32 = if (prev) |p| p[x] else 0; // up
            const c: u32 = if (prev != null and x >= bpp) prev.?[x - bpp] else 0; // up-left
            line[x] = switch (f) {
                0 => line[x],
                1 => @truncate(line[x] + a),
                2 => @truncate(line[x] + b),
                3 => @truncate(line[x] + (a + b) / 2),
                4 => @truncate(line[x] + paeth(a, b, c)),
                else => return error.BadFilter,
            };
        }
    }
}

/// The Paeth predictor (PNG spec §9.4).
fn paeth(a: u32, b: u32, c: u32) u32 {
    const p: i32 = @as(i32, @intCast(a)) + @as(i32, @intCast(b)) - @as(i32, @intCast(c));
    const pa = @abs(p - @as(i32, @intCast(a)));
    const pb = @abs(p - @as(i32, @intCast(b)));
    const pc = @abs(p - @as(i32, @intCast(c)));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}
