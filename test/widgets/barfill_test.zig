//! Host tests of src/widgets/barfill.zig.

const std = @import("std");
const barfill = @import("barfill");
const fillWidth = barfill.fillWidth;

test "empty when total is zero (uninitialised counters)" {
    try std.testing.expectEqual(@as(usize, 0), fillWidth(100, 50, 0));
}

test "too-narrow bar cannot underflow-wrap (the resize crash)" {
    // w in 0.2 has no interior; the old `(w - 2)` wrapped to ~2^64 here.
    try std.testing.expectEqual(@as(usize, 0), fillWidth(0, 999, 1000));
    try std.testing.expectEqual(@as(usize, 0), fillWidth(1, 999, 1000));
    // w == 2: interior is 0px, full ratio still yields 0.
    try std.testing.expectEqual(@as(usize, 0), fillWidth(2, 1000, 1000));
}

test "fraction maps into the interior width" {
    // interior = 100 - 2 = 98.
    try std.testing.expectEqual(@as(usize, 0), fillWidth(100, 0, 1000));
    try std.testing.expectEqual(@as(usize, 49), fillWidth(100, 500, 1000));
    try std.testing.expectEqual(@as(usize, 98), fillWidth(100, 1000, 1000));
}

test "byte-scale operands do not overflow (used = real memory bytes)" {
    // 16 GiB used of 32 GiB: interior*used would overflow u32/usize-32 but the
    // u64 widening keeps it exact; result is half the interior.
    const gib: usize = 1 << 30;
    try std.testing.expectEqual(@as(usize, 49), fillWidth(100, 16 * gib, 32 * gib));
    // Fully used near the usize ceiling still clamps to the interior, never past.
    try std.testing.expectEqual(@as(usize, 98), fillWidth(100, std.math.maxInt(usize), std.math.maxInt(usize)));
}

test "fill never exceeds the interior even if used > total" {
    // Defensive: a transient used>total (racy sample) clamps, not paints past.
    try std.testing.expectEqual(@as(usize, 98), fillWidth(100, 2000, 1000));
}
