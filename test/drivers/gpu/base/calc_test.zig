//! Host tests of src/drivers/gpu/base/calc.zig.

const std = @import("std");
const calc = @import("calc");
const msiAddress = calc.msiAddress;
const msiData = calc.msiData;
const mtrrPhysBase = calc.mtrrPhysBase;
const mtrrPhysMask = calc.mtrrPhysMask;
const mtrrSize = calc.mtrrSize;

test "msiAddress targets the LAPIC with the apic id in bits[19:12]" {
    try std.testing.expectEqual(@as(u32, 0xFEE0_0000), msiAddress(0));
    try std.testing.expectEqual(@as(u32, 0xFEE0_1000), msiAddress(1));
    try std.testing.expectEqual(@as(u32, 0xFEE0_3000), msiAddress(3));
    // apic id 0xFF -> bits[19:12] = 0xFF
    try std.testing.expectEqual(@as(u32, 0xFEEF_F000), msiAddress(0xFF));
}

test "msiData carries the vector in the low byte (edge/fixed)" {
    try std.testing.expectEqual(@as(u16, 0x40), msiData(0x40));
    try std.testing.expectEqual(@as(u16, 0xFF), msiData(0xFF));
}

test "mtrrSize rounds up to a power of two, floored at 4 KiB" {
    try std.testing.expectEqual(@as(u64, 0x1000), mtrrSize(1));
    try std.testing.expectEqual(@as(u64, 0x1000), mtrrSize(0x1000));
    try std.testing.expectEqual(@as(u64, 0x2000), mtrrSize(0x1001));
    // BAR0 is 16 MiB -> already a power of two.
    try std.testing.expectEqual(@as(u64, 16 * 1024 * 1024), mtrrSize(16 * 1024 * 1024));
}

test "mtrrPhysBase aligns down and encodes the memory type" {
    // WC (=1) over a 16 MiB BAR at 0xF000_0000.
    const size = mtrrSize(16 * 1024 * 1024);
    const base = mtrrPhysBase(0xF000_0000, size, 0x01);
    try std.testing.expectEqual(@as(u64, 0xF000_0001), base); // aligned + type WC
    // UC (=0) keeps low bits clear.
    try std.testing.expectEqual(@as(u64, 0xF000_0000), mtrrPhysBase(0xF000_0000, size, 0x00));
}

test "mtrrPhysMask sets V and masks to phys-addr width" {
    // 39-bit phys addr, 16 MiB region.
    const size: u64 = 16 * 1024 * 1024; // 0x0100_0000
    const mask = mtrrPhysMask(size, 39);
    // V bit (1<<11) must be set.
    try std.testing.expect(mask & (1 << 11) != 0);
    // The size mask: ~(0x00FF_FFFF) within 39 bits, page-aligned.
    // bits below 24 are zero (region size), so mask & (size-1) == 0.
    try std.testing.expectEqual(@as(u64, 0), mask & (size - 1) & ~@as(u64, 0xFFF));
}
