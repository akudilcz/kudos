//! Host tests of src/drivers/gl/ada/til.zig.

const std = @import("std");
const til = @import("til");
const blockHeightLog2 = til.blockHeightLog2;
const layout2d = til.layout2d;

test "blockHeightLog2 clamps for small surfaces" {
    // 8-px-tall surface: even one 2-GOB block (16 rows) is ≥ 2×8 → bh=0.
    try std.testing.expectEqual(@as(u5, 0), blockHeightLog2(8));
    // 64 rows: block of 2^3 GOBs = 64 rows; 2^3 from (8<<2=32 < 64 keeps 3?)
    // rule: halve while (GOB_H << (bh-1)) >= h  → for 64: 8<<4=128 ≥ 64 → …
    try std.testing.expectEqual(@as(u5, 3), blockHeightLog2(64));
    // Large surface keeps the maximum 32-GOB block.
    try std.testing.expectEqual(@as(u5, 5), blockHeightLog2(1024));
}

test "layout2d 1024x1024 Z32F" {
    const l = layout2d(1024, 1024, 4);
    try std.testing.expectEqual(@as(u5, 5), l.bh_log2);
    // 4096 B rows = 64 blocks per row; block = 64B × 256 rows = 16 KiB.
    try std.testing.expectEqual(@as(u32, 4096), l.row_stride_bytes);
    try std.testing.expectEqual(@as(u64, 64 * 4 * 16384), l.size_bytes);
    try std.testing.expectEqual(@as(u64, 16384), l.align_bytes);
}

test "layout2d covers every pixel" {
    const l = layout2d(100, 30, 4);
    try std.testing.expect(l.size_bytes >= 100 * 30 * 4);
    try std.testing.expect(l.row_stride_bytes >= 100 * 4);
    try std.testing.expectEqual(@as(u64, 0), l.size_bytes % l.align_bytes);
}
