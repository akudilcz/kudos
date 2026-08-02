//! Host tests of src/kernel/loader/abi.zig — the `.kudos` binary ABI: CRC parity with
//! the host factory, header round-trip, and every rejection case of `verify`.

const std = @import("std");
const abi = @import("abi");

// The CRC must equal Python's binascii.crc32 (the factory), which is the
// standard IEEE reflected CRC-32 with the well-known check values.
test "crc32 matches the standard vectors the factory uses" {
    try std.testing.expectEqual(@as(u32, 0x00000000), abi.crc32(""));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), abi.crc32("123456789"));
}

// A file stamped by writeHeader must verify, and hand back exactly the code
// slice and mem_len it was given.
test "writeHeader round-trips through verify (MOD-005)" {
    const code = "\x00\x01\x02hello-kudos-payload";
    const mem_len: usize = code.len + 4096; // a .bss tail

    var buf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    var hdr: [abi.HEADER_SIZE]u8 = undefined;
    abi.writeHeader(&hdr, .app, code, mem_len);
    @memcpy(buf[0..abi.HEADER_SIZE], &hdr);
    @memcpy(buf[abi.HEADER_SIZE..], code);

    const got = try abi.verify(&buf);
    try std.testing.expectEqual(abi.Kind.app, got.kind);
    try std.testing.expectEqualSlices(u8, code, got.code);
    try std.testing.expectEqual(mem_len, got.mem_len);
}

test "feature kind round-trips" {
    const code = "feat";
    var buf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    var hdr: [abi.HEADER_SIZE]u8 = undefined;
    abi.writeHeader(&hdr, .feature, code, code.len);
    @memcpy(buf[0..abi.HEADER_SIZE], &hdr);
    @memcpy(buf[abi.HEADER_SIZE..], code);
    const got = try abi.verify(&buf);
    try std.testing.expectEqual(abi.Kind.feature, got.kind);
}

// Build one valid blob, then mutate each invariant and assert the matching
// distinct error — the loader depends on telling these apart.
fn stamp(buf: []u8, code: []const u8, mem_len: usize) void {
    var hdr: [abi.HEADER_SIZE]u8 = undefined;
    abi.writeHeader(&hdr, .app, code, mem_len);
    @memcpy(buf[0..abi.HEADER_SIZE], &hdr);
    @memcpy(buf[abi.HEADER_SIZE..][0..code.len], code);
}

// The DrawApi vtable is ABI: a generated blob binds it by field OFFSET, so the
// layout must stay append-only. version is first (a blob checks it before calling),
// and each call pointer keeps its offset; a new call may only be appended.
test "DrawApi vtable layout is the committed ABI (append-only, ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.DrawApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.DrawApi, "open"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.DrawApi, "blit"));
    // Window bounds are sane and fit a u16 surface dimension.
    try std.testing.expect(abi.DRAW_MAX_W > 0 and abi.DRAW_MAX_W <= 0xFFFF);
    try std.testing.expect(abi.DRAW_MAX_H > 0 and abi.DRAW_MAX_H <= 0xFFFF);
}

test "verify rejects every corruption with its own error (ARCH-014)" {
    const code = "payload!!";
    var buf: [abi.HEADER_SIZE + code.len]u8 = undefined;

    // too small: fewer bytes than a header
    try std.testing.expectError(error.TooSmall, abi.verify(buf[0 .. abi.HEADER_SIZE - 1]));

    // bad magic
    stamp(&buf, code, code.len);
    buf[0] +%= 1;
    try std.testing.expectError(error.BadMagic, abi.verify(&buf));

    // bad version
    stamp(&buf, code, code.len);
    std.mem.writeInt(u32, buf[4..8], abi.ABI_VERSION + 1, .little);
    try std.testing.expectError(error.BadVersion, abi.verify(&buf));

    // bad kind
    stamp(&buf, code, code.len);
    std.mem.writeInt(u32, buf[8..12], 0, .little);
    try std.testing.expectError(error.BadKind, abi.verify(&buf));

    // mem_len < code_len
    stamp(&buf, code, code.len);
    std.mem.writeInt(u32, buf[16..20], @as(u32, code.len - 1), .little);
    try std.testing.expectError(error.BadLengths, abi.verify(&buf));

    // code_len runs past the end of the blob
    stamp(&buf, code, code.len);
    std.mem.writeInt(u32, buf[12..16], @as(u32, code.len + 1), .little);
    // mem_len must stay >= code_len to reach the length/bounds check
    std.mem.writeInt(u32, buf[16..20], @as(u32, code.len + 1), .little);
    try std.testing.expectError(error.BadLengths, abi.verify(&buf));

    // bad crc: flip a code byte, leaving the stored crc stale
    stamp(&buf, code, code.len);
    buf[abi.HEADER_SIZE] +%= 1;
    try std.testing.expectError(error.BadCrc, abi.verify(&buf));
}
