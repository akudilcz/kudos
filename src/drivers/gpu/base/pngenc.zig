//! PNG encoder — the native image WRITE half (spec R33; ui/assets/png.zig is the read
//! half). PURE (imports only std): 0xAARRGGBB pixels in, a complete PNG out —
//! 8-bit RGB, filter 0 scanlines, one zlib IDAT (std.compress.zlib, real
//! deflate — a 3440x1440 desktop screenshot compresses ~10x vs raw).
//!
//! The deflate state is a few hundred KiB, far too big for a kernel task
//! stack, so the compressor lives on the caller's allocator for the duration
//! of one encode. Nothing is retained between calls.

const std = @import("std");

const PNG_SIGNATURE = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
const IHDR_LEN: u32 = 13;
const BIT_DEPTH_8: u8 = 8;
const COLOR_TYPE_RGB: u8 = 2;
const FILTER_NONE: u8 = 0;
const BYTES_PER_PIXEL: usize = 3;

pub const Error = std.mem.Allocator.Error;

/// Append one PNG chunk: length, tag, data, CRC-32 over tag+data.
fn writeChunk(out: *std.array_list.Managed(u8), tag: *const [4]u8, data: []const u8) Error!void {
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, @intCast(data.len), .big);
    try out.appendSlice(&be);
    try out.appendSlice(tag);
    try out.appendSlice(data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    std.mem.writeInt(u32, &be, crc.final(), .big);
    try out.appendSlice(&be);
}

/// Encode `w × h` pixels (0xAARRGGBB, rows top-down, `stride_px` pixels per
/// row) as an RGB PNG. Alpha is dropped — the desktop scanout this serves is
/// opaque by the time it reaches the screen. Caller owns the returned bytes.
/// Construct the compressor into its heap slot, in this function's OWN frame
/// (called never_inline): `Compress.init` returns the ~96 KiB hash/chain state
/// by value, and inlined that temporary joins the caller's frame for the
/// caller's whole lifetime. Here it lives only for the duration of this call,
/// at a depth where nothing else big is live.
fn initCompressInto(cmp: *std.compress.flate.Compress, out: *std.Io.Writer, window: []u8) Error!void {
    cmp.* = std.compress.flate.Compress.init(out, window, .zlib, .level_4) catch return Error.OutOfMemory;
}

pub fn encode(a: std.mem.Allocator, w: u32, h: u32, px: []const u32, stride_px: usize) Error![]u8 {
    // Raw scanline stream: one filter byte then w RGB triples per row.
    const row_bytes = 1 + @as(usize, w) * BYTES_PER_PIXEL;
    const raw = try a.alloc(u8, row_bytes * h);
    defer a.free(raw);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row = px[y * stride_px ..][0..w];
        const out_row = raw[y * row_bytes ..][0..row_bytes];
        out_row[0] = FILTER_NONE;
        for (row, 0..) |v, x| {
            out_row[1 + x * BYTES_PER_PIXEL + 0] = @truncate(v >> 16); // R
            out_row[1 + x * BYTES_PER_PIXEL + 1] = @truncate(v >> 8); // G
            out_row[1 + x * BYTES_PER_PIXEL + 2] = @truncate(v); // B
        }
    }

    // zlib-compress the stream. The whole compressor — the ~64 KiB history
    // window AND the ~225 KiB `Compress` state itself — is heap-hosted (see
    // the module doc); a kernel task stack is 128 KiB, so a stack-local
    // `Compress` overflows it. `Compress` holds no pointer into itself
    // (its writer buffer is the window slice, its bit writer points at the
    // output), so constructing it into a heap slot is sound.
    var idat: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(a, 64) catch return Error.OutOfMemory;
    defer idat.deinit();
    const window = a.alloc(u8, std.compress.flate.max_window_len) catch return Error.OutOfMemory;
    defer a.free(window);
    const cmp = a.create(std.compress.flate.Compress) catch return Error.OutOfMemory;
    defer a.destroy(cmp);
    @call(.never_inline, initCompressInto, .{ cmp, &idat.writer, window }) catch return Error.OutOfMemory;
    cmp.writer.writeAll(raw) catch return Error.OutOfMemory;
    cmp.finish() catch return Error.OutOfMemory;

    // Assemble: signature, IHDR, IDAT, IEND.
    var out = std.array_list.Managed(u8).init(a);
    errdefer out.deinit();
    try out.appendSlice(&PNG_SIGNATURE);
    var ihdr: [IHDR_LEN]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = BIT_DEPTH_8;
    ihdr[9] = COLOR_TYPE_RGB;
    ihdr[10] = 0; // compression: deflate (the only defined method)
    ihdr[11] = 0; // filter method 0
    ihdr[12] = 0; // no interlace
    try writeChunk(&out, "IHDR", &ihdr);
    try writeChunk(&out, "IDAT", idat.written());
    try writeChunk(&out, "IEND", &.{});
    return out.toOwnedSlice();
}
