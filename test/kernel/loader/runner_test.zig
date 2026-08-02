//! Host tests of src/kernel/loader/runner.zig — the .kudos loader's placement logic:
//! code copied, .bss tail zeroed, memory beyond mem_len untouched, the entry
//! pointer is the image base, and every rejection path fires. Actual EXECUTION
//! of a real compiled .kudos is proved separately by scripts/agent/hostload.zig
//! driven from scripts/agent/test_factory.py; here we cover the pure mechanics.

const std = @import("std");
const runner = @import("runner");
const abi = runner.abi;

/// Lay a valid blob (header + code) into `buf` and return the used slice.
fn blobInto(buf: []u8, kind: abi.Kind, code: []const u8, mem_len: usize) []u8 {
    var hdr: [abi.HEADER_SIZE]u8 = undefined;
    abi.writeHeader(&hdr, kind, code, mem_len);
    @memcpy(buf[0..abi.HEADER_SIZE], &hdr);
    @memcpy(buf[abi.HEADER_SIZE..][0..code.len], code);
    return buf[0 .. abi.HEADER_SIZE + code.len];
}

test "loadApp copies code, zeroes the bss tail, leaves the rest, returns base (MOD-002)" {
    const code = [_]u8{ 0x90, 0x91, 0x92, 0x93, 0x94 };
    const mem_len: usize = 16;
    var filebuf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    const blob = blobInto(&filebuf, .app, &code, mem_len);

    var image: [32]u8 = undefined;
    @memset(&image, 0xAA);
    const entry = try runner.loadApp(blob, image[0..]);

    try std.testing.expectEqualSlices(u8, &code, image[0..code.len]);
    for (image[code.len..mem_len]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (image[mem_len..]) |b| try std.testing.expectEqual(@as(u8, 0xAA), b); // untouched
    try std.testing.expectEqual(@intFromPtr(&image), @intFromPtr(entry));
}

test "loadFeature loads a feature image; loadApp rejects it as WrongKind" {
    const code = [_]u8{ 0x01, 0x02, 0x03 };
    var filebuf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    const blob = blobInto(&filebuf, .feature, &code, code.len);

    var image: [16]u8 = undefined;
    _ = try runner.loadFeature(blob, image[0..]);
    try std.testing.expectError(error.WrongKind, runner.loadApp(blob, image[0..]));
}

test "ImageTooSmall when the buffer is shorter than mem_len" {
    const code = [_]u8{ 0xAA, 0xBB };
    const mem_len: usize = 64;
    var filebuf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    const blob = blobInto(&filebuf, .app, &code, mem_len);

    var image: [32]u8 = undefined;
    try std.testing.expectError(error.ImageTooSmall, runner.loadApp(blob, image[0..]));
}

test "verify errors bubble through the loader (ARCH-014: nothing unverified executes)" {
    const code = [_]u8{ 0xAA, 0xBB, 0xCC };
    var filebuf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    const blob = blobInto(&filebuf, .app, &code, code.len);

    filebuf[0] +%= 1; // corrupt the magic
    var image: [16]u8 = undefined;
    try std.testing.expectError(error.BadMagic, runner.loadApp(blob, image[0..]));
}

test "imageSize reports mem_len without loading" {
    const code = [_]u8{ 0x11, 0x22 };
    const mem_len: usize = 4096;
    var filebuf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    const blob = blobInto(&filebuf, .app, &code, mem_len);
    try std.testing.expectEqual(mem_len, try runner.imageSize(blob));
}
