//! Application pixels -> pixels a sampler can read.
//!
//! The standard lets an application hand over its image in more shapes than any sampler
//! decodes: five component orders, three packed 16-bit types, and — via the mandatory
//! OES_compressed_paletted_texture — an index into a palette. The silicon reads four
//! layouts. So every upload is expanded here, on the CPU, once.
//!
//! Three rules that are easy to get wrong and silent when you do:
//!
//! **Rows are padded.** GL_UNPACK_ALIGNMENT (default **4**, not 1) rounds every row up.
//! A 3-pixel-wide RGB image has 9 bytes of pixels and a 12-byte row. Ignore it and every
//! row after the first is shifted, which looks like a skewed image rather than a crash.
//!
//! **Expanding 5 bits to 8 is not a shift.** 0b11111 must become 255, not 248 — so the
//! high bits are replicated into the low ones (`v << 3 | v >> 2`). A plain shift makes
//! white slightly grey and never quite looks wrong enough to notice.
//!
//! **RGB gets an alpha of 1.** There is no three-byte sampler format worth having, so
//! RGB widens to four channels, and the standard says the missing alpha reads as 1.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §3.7.1 (texture image
//! specification), §3.6.2 (unpacking); OES_compressed_paletted_texture.

const std = @import("std");
const idraw = @import("idraw");
pub const enums = @import("enums.zig");

pub const GLenum = enums.GLenum;

pub const Error = error{ BadFormat, ShortData, OutOfMemory };

/// GL_BGRA_EXT (Khronos EXT_texture_format_BGRA8888, spec RND-008): pixels
/// already in the sampler's blue-first layout — the native output of kudos's
/// image decoders and the compositor's surface layout — stored as-is, no
/// per-texel swap. The token lives here, in the format owner: enums.zig is
/// generated from the ES 1.1 core header and must not carry extension names.
pub const GL_BGRA_EXT: GLenum = 0x80E1;

/// Which sampler layout an external format expands into.
pub fn storedFormat(format: GLenum) ?idraw.TexFormat {
    return switch (format) {
        enums.GL_ALPHA => .alpha8,
        enums.GL_LUMINANCE => .luminance8,
        enums.GL_LUMINANCE_ALPHA => .luminance_alpha8,
        enums.GL_RGB, enums.GL_RGBA, GL_BGRA_EXT => .bgra8,
        else => null,
    };
}

pub fn bytesPerStoredPixel(f: idraw.TexFormat) usize {
    return switch (f) {
        .bgra8 => 4,
        .luminance_alpha8 => 2,
        .luminance8, .alpha8 => 1,
    };
}

/// Bytes one source pixel occupies, or null when the format/type pair is not one the
/// standard allows.
pub fn sourcePixelSize(format: GLenum, type_token: GLenum) ?usize {
    const components: usize = switch (format) {
        enums.GL_ALPHA, enums.GL_LUMINANCE => 1,
        enums.GL_LUMINANCE_ALPHA => 2,
        enums.GL_RGB => 3,
        enums.GL_RGBA => 4,
        // The extension admits GL_UNSIGNED_BYTE only (EXT_texture_format_BGRA8888).
        GL_BGRA_EXT => return if (type_token == enums.GL_UNSIGNED_BYTE) 4 else null,
        else => return null,
    };
    return switch (type_token) {
        enums.GL_UNSIGNED_BYTE => components,
        // Each packed type carries a whole pixel in one short, and each is legal with
        // exactly one format: 5_6_5 has no alpha to give RGBA, and 4_4_4_4 has one that
        // RGB could not use.
        enums.GL_UNSIGNED_SHORT_5_6_5 => if (format == enums.GL_RGB) 2 else null,
        enums.GL_UNSIGNED_SHORT_4_4_4_4, enums.GL_UNSIGNED_SHORT_5_5_5_1 => if (format == enums.GL_RGBA) 2 else null,
        else => null,
    };
}

/// The stride of one source row: the pixels, rounded up to the unpack alignment.
pub fn sourceRowStride(w: u32, pixel: usize, alignment: u32) usize {
    const row = @as(usize, w) * pixel;
    const a: usize = alignment;
    return (row + a - 1) / a * a;
}

/// Widen an n-bit channel to 8 bits by replicating its high bits down. 5 bits of all
/// ones must give 255; a shift alone would give 248.
pub fn widen(comptime bits: u5, v: u32) u8 {
    const shifted = v << (8 - bits);
    return @intCast((shifted | (v >> (2 * bits - 8))) & 0xFF);
}

/// How many bytes `expand` will write.
pub fn expandedSize(w: u32, h: u32, format: GLenum) ?usize {
    const sf = storedFormat(format) orelse return null;
    return @as(usize, w) * @as(usize, h) * bytesPerStoredPixel(sf);
}

/// Expand one image into `dst`, which must be `expandedSize` bytes. `src` is the
/// application's pixels, rows top-down, each `sourceRowStride` apart.
pub fn expand(
    dst: []u8,
    src: []const u8,
    w: u32,
    h: u32,
    format: GLenum,
    type_token: GLenum,
    alignment: u32,
) Error!void {
    const pixel = sourcePixelSize(format, type_token) orelse return Error.BadFormat;
    const sf = storedFormat(format) orelse return Error.BadFormat;
    const stride = sourceRowStride(w, pixel, alignment);
    const out_px = bytesPerStoredPixel(sf);

    if (dst.len < @as(usize, w) * h * out_px) return Error.ShortData;
    // The last row needs only its pixels, not its padding — an image whose final row is
    // unpadded is legal and common.
    if (h > 0 and src.len < (h - 1) * stride + @as(usize, w) * pixel) return Error.ShortData;

    for (0..h) |y| {
        const row = src[y * stride ..];
        const out = dst[y * @as(usize, w) * out_px ..];
        for (0..w) |x| {
            const s = row[x * pixel ..];
            const d = out[x * out_px ..];
            switch (type_token) {
                enums.GL_UNSIGNED_BYTE => switch (format) {
                    // The sampler's layout is blue first, so this is where the swap
                    // happens rather than in a shader swizzle on every fetch.
                    enums.GL_RGBA => {
                        d[0] = s[2];
                        d[1] = s[1];
                        d[2] = s[0];
                        d[3] = s[3];
                    },
                    // Already blue-first: stored verbatim (RND-008).
                    GL_BGRA_EXT => {
                        d[0] = s[0];
                        d[1] = s[1];
                        d[2] = s[2];
                        d[3] = s[3];
                    },
                    enums.GL_RGB => {
                        d[0] = s[2];
                        d[1] = s[1];
                        d[2] = s[0];
                        d[3] = 255; // the alpha the standard says a missing one reads as
                    },
                    enums.GL_LUMINANCE, enums.GL_ALPHA => d[0] = s[0],
                    enums.GL_LUMINANCE_ALPHA => {
                        d[0] = s[0];
                        d[1] = s[1];
                    },
                    else => return Error.BadFormat,
                },
                enums.GL_UNSIGNED_SHORT_5_6_5 => {
                    const v = std.mem.readInt(u16, s[0..2], .little);
                    d[0] = widen(5, v & 0x1F); // blue
                    d[1] = widen(6, (v >> 5) & 0x3F);
                    d[2] = widen(5, (v >> 11) & 0x1F);
                    d[3] = 255;
                },
                enums.GL_UNSIGNED_SHORT_4_4_4_4 => {
                    const v = std.mem.readInt(u16, s[0..2], .little);
                    d[0] = widen(4, (v >> 4) & 0xF); // blue
                    d[1] = widen(4, (v >> 8) & 0xF);
                    d[2] = widen(4, (v >> 12) & 0xF);
                    d[3] = widen(4, v & 0xF);
                },
                enums.GL_UNSIGNED_SHORT_5_5_5_1 => {
                    const v = std.mem.readInt(u16, s[0..2], .little);
                    d[0] = widen(5, (v >> 1) & 0x1F); // blue
                    d[1] = widen(5, (v >> 6) & 0x1F);
                    d[2] = widen(5, (v >> 11) & 0x1F);
                    // One bit of alpha: on or off, nothing between.
                    d[3] = if (v & 1 != 0) 255 else 0;
                },
                else => return Error.BadFormat,
            }
        }
    }
}

// ── OES_compressed_paletted_texture (mandatory) ──────────────────────────────

/// One of the ten paletted formats: the entry format, and how many bits an index is.
pub const Paletted = struct {
    entry_format: GLenum,
    entry_type: GLenum,
    index_bits: u4,

    pub fn entries(self: Paletted) u32 {
        return @as(u32, 1) << self.index_bits;
    }
};

/// Decode a paletted internal format, or null when it is not one.
pub fn paletted(f: GLenum) ?Paletted {
    return switch (f) {
        enums.GL_PALETTE4_RGB8_OES => .{ .entry_format = enums.GL_RGB, .entry_type = enums.GL_UNSIGNED_BYTE, .index_bits = 4 },
        enums.GL_PALETTE4_RGBA8_OES => .{ .entry_format = enums.GL_RGBA, .entry_type = enums.GL_UNSIGNED_BYTE, .index_bits = 4 },
        enums.GL_PALETTE4_R5_G6_B5_OES => .{ .entry_format = enums.GL_RGB, .entry_type = enums.GL_UNSIGNED_SHORT_5_6_5, .index_bits = 4 },
        enums.GL_PALETTE4_RGBA4_OES => .{ .entry_format = enums.GL_RGBA, .entry_type = enums.GL_UNSIGNED_SHORT_4_4_4_4, .index_bits = 4 },
        enums.GL_PALETTE4_RGB5_A1_OES => .{ .entry_format = enums.GL_RGBA, .entry_type = enums.GL_UNSIGNED_SHORT_5_5_5_1, .index_bits = 4 },
        enums.GL_PALETTE8_RGB8_OES => .{ .entry_format = enums.GL_RGB, .entry_type = enums.GL_UNSIGNED_BYTE, .index_bits = 8 },
        enums.GL_PALETTE8_RGBA8_OES => .{ .entry_format = enums.GL_RGBA, .entry_type = enums.GL_UNSIGNED_BYTE, .index_bits = 8 },
        enums.GL_PALETTE8_R5_G6_B5_OES => .{ .entry_format = enums.GL_RGB, .entry_type = enums.GL_UNSIGNED_SHORT_5_6_5, .index_bits = 8 },
        enums.GL_PALETTE8_RGBA4_OES => .{ .entry_format = enums.GL_RGBA, .entry_type = enums.GL_UNSIGNED_SHORT_4_4_4_4, .index_bits = 8 },
        enums.GL_PALETTE8_RGB5_A1_OES => .{ .entry_format = enums.GL_RGBA, .entry_type = enums.GL_UNSIGNED_SHORT_5_5_5_1, .index_bits = 8 },
        else => null,
    };
}

/// Bytes a paletted image occupies: the palette, then every mip level's indices.
///
/// The whole chain lives in ONE blob — that is what makes these formats worth having,
/// and it is why there is no sub-image update for them: the palette is shared, so a
/// partial update is not expressible.
pub fn palettedSize(p: Paletted, w: u32, h: u32, levels: u32) ?usize {
    const entry = sourcePixelSize(p.entry_format, p.entry_type) orelse return null;
    var total = @as(usize, p.entries()) * entry;
    for (0..levels) |l| {
        const lw = @max(1, w >> @intCast(l));
        const lh = @max(1, h >> @intCast(l));
        total += indexBytes(p, lw, lh);
    }
    return total;
}

/// Bytes the indices of one level occupy. At 4 bits, two pixels share a byte and an odd
/// width rounds up.
pub fn indexBytes(p: Paletted, w: u32, h: u32) usize {
    const px = @as(usize, w) * h;
    return if (p.index_bits == 4) (px + 1) / 2 else px;
}

/// Expand one level of a paletted image into `dst` (BGRA8-shaped per `storedFormat` of
/// the entry format). `src` is the whole blob: palette first, then the levels.
pub fn expandPaletted(dst: []u8, src: []const u8, p: Paletted, w: u32, h: u32, level: u32, base_w: u32, base_h: u32) Error!void {
    const entry = sourcePixelSize(p.entry_format, p.entry_type) orelse return Error.BadFormat;
    const sf = storedFormat(p.entry_format) orelse return Error.BadFormat;
    const out_px = bytesPerStoredPixel(sf);
    const pal_bytes = @as(usize, p.entries()) * entry;
    if (src.len < pal_bytes) return Error.ShortData;

    // The palette is itself in an external format, so it expands with the same code
    // every other image uses — one home for the 5-6-5 widening, not two.
    var pal: [256 * 4]u8 = undefined;
    try expand(pal[0 .. p.entries() * out_px], src[0..pal_bytes], p.entries(), 1, p.entry_format, p.entry_type, 1);

    // Skip the levels before this one to find our indices.
    var at = pal_bytes;
    for (0..level) |l| {
        at += indexBytes(p, @max(1, base_w >> @intCast(l)), @max(1, base_h >> @intCast(l)));
    }
    const idx = src[at..];
    if (idx.len < indexBytes(p, w, h)) return Error.ShortData;
    if (dst.len < @as(usize, w) * h * out_px) return Error.ShortData;

    for (0..@as(usize, w) * h) |i| {
        const e: usize = if (p.index_bits == 4)
            // Two pixels per byte, the FIRST in the high nibble.
            (if (i % 2 == 0) idx[i / 2] >> 4 else idx[i / 2] & 0xF)
        else
            idx[i];
        @memcpy(dst[i * out_px ..][0..out_px], pal[e * out_px ..][0..out_px]);
    }
}
