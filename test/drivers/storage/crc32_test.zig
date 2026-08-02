//! Host tests of src/drivers/storage/crc32.zig.

const std = @import("std");
const mod = @import("crc32");
const crc32 = mod.crc32;

test "crc32 vectors" {
    // Canonical check values (RFC 3720 appendix / zlib).
    try std.testing.expectEqual(@as(u32, 0x00000000), crc32(""));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0x414FA339), crc32("The quick brown fox jumps over the lazy dog"));
}
