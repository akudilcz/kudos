//! Host tests of src/kernel/sched/cpustat.zig.

const std = @import("std");
const cpustat = @import("cpustat");
const busyPercent = cpustat.busyPercent;

test "busyPercent: a fully-pegged core reads 100% (no Nyquist 50%/0% bias)" {
    // The whole point of TSC-delta time accounting: all elapsed time is busy,
    // so a CPU-bound loop reads 100% regardless of cadence — never caps at 50%.
    try std.testing.expectEqual(@as(u32, 100), busyPercent(1_000_000, 0));
    try std.testing.expectEqual(@as(u32, 100), busyPercent(7, 0));
}

test "busyPercent: idle and mixed loads" {
    try std.testing.expectEqual(@as(u32, 0), busyPercent(0, 1_000)); // fully idle
    try std.testing.expectEqual(@as(u32, 50), busyPercent(500, 500)); // half busy
    try std.testing.expectEqual(@as(u32, 25), busyPercent(250, 750));
    try std.testing.expectEqual(@as(u32, 0), busyPercent(0, 0)); // no samples yet
}

test "tscToMs: ticks convert at the calibrated frequency, truncating sub-ms" {
    // Half a second of ticks at a 3 GHz TSC is 500 ms.
    try std.testing.expectEqual(@as(u64, 500), cpustat.tscToMs(1_500_000_000, 3_000_000_000));
    try std.testing.expectEqual(@as(u64, 0), cpustat.tscToMs(0, 3_000_000_000));
    // Just under one ms of ticks truncates to 0, not rounds to 1.
    try std.testing.expectEqual(@as(u64, 0), cpustat.tscToMs(2_999_999, 3_000_000_000));
}

test "tscToMs: uncalibrated frequency reads 0; huge tick counts do not overflow" {
    // tsc_hz == 0 (before calibration): 0, never a divide-by-zero.
    try std.testing.expectEqual(@as(u64, 0), cpustat.tscToMs(123_456, 0));
    // 2^63 ticks at 1 GHz (~292 years): ticks × 1000 overflows u64, so this
    // only passes through the 128-bit widening. 2^63 / 10^9 s = 9.22e12 ms.
    try std.testing.expectEqual(@as(u64, 9_223_372_036_854), cpustat.tscToMs(1 << 63, 1_000_000_000));
}
