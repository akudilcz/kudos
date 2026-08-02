//! Host tests of src/kernel/virt/msrarea.zig — the 16-byte MSR-area entry layout.

const std = @import("std");
const msrarea = @import("msrarea");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "entry is exactly the 16-byte layout the CPU walks" {
    try expectEqual(@as(usize, 16), msrarea.ENTRY_SIZE);
    try expectEqual(@as(usize, 16), @sizeOf(msrarea.Entry));
    try expectEqual(@as(usize, 0), @offsetOf(msrarea.Entry, "index"));
    try expectEqual(@as(usize, 4), @offsetOf(msrarea.Entry, "reserved"));
    try expectEqual(@as(usize, 8), @offsetOf(msrarea.Entry, "data"));
}

test "encode places index, reserved-zero, and data at the SDM byte offsets" {
    // A real SYSCALL setup: IA32_LSTAR (0xC000_0082) pointing at a kernel entry.
    const bytes = msrarea.encode(0xC000_0082, 0xFFFF_FFFF_8100_0000);
    // index at bytes 0..4, little-endian.
    try expectEqualSlices(u8, &.{ 0x82, 0x00, 0x00, 0xC0 }, bytes[0..4]);
    // reserved at bytes 4..8, all zero.
    try expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x00 }, bytes[4..8]);
    // data at bytes 8..16, little-endian.
    try expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x81, 0xFF, 0xFF, 0xFF, 0xFF }, bytes[8..16]);
}

test "encode round-trips through the Entry view" {
    // FMASK: the SYSCALL flag-mask MSR. Read the encoded bytes back as an Entry
    // and confirm every field survives — a layout swap of index/data goes red here.
    const bytes = msrarea.encode(0xC000_0084, 0x4700);
    const e: msrarea.Entry = @bitCast(bytes);
    try expectEqual(@as(u32, 0xC000_0084), e.index);
    try expectEqual(@as(u32, 0), e.reserved);
    try expectEqual(@as(u64, 0x4700), e.data);
}
