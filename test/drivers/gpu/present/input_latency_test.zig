//! Host tests of src/drivers/gpu/present/input_latency.zig (spec PERF-008).

const std = @import("std");
const input_latency = @import("input_latency");
const Latch = input_latency.Latch;
const deltaUs = input_latency.deltaUs;
const overBudget = input_latency.overBudget;

/// An arbitrary TSC rate for the conversion tests: 1 GHz makes 1 tick = 1 ns,
/// so expected µs values read directly off the tick deltas.
const TSC_1GHZ: u64 = 1_000_000_000;

test "empty latch: a present with no sampled input reports nothing" {
    var l = Latch{};
    try std.testing.expectEqual(@as(?u64, null), l.presented(1_000));
}

test "one event: presented returns receipt→present delta and re-arms" {
    var l = Latch{};
    l.consumed(100);
    try std.testing.expectEqual(@as(?u64, 400), l.presented(500));
    // Re-armed: the next present with no new input reports nothing.
    try std.testing.expectEqual(@as(?u64, null), l.presented(900));
}

test "a burst sampled into one frame is judged by its OLDEST receipt" {
    var l = Latch{};
    l.consumed(300); // arrives first…
    l.consumed(700); // …later events must not shrink the frame's worst latency
    l.consumed(500);
    try std.testing.expectEqual(@as(?u64, 700), l.presented(1_000));
}

test "receipts across two frames are judged per frame, not merged" {
    var l = Latch{};
    l.consumed(100);
    try std.testing.expectEqual(@as(?u64, 900), l.presented(1_000));
    l.consumed(1_200);
    try std.testing.expectEqual(@as(?u64, 800), l.presented(2_000));
}

test "a zero receipt stamp (unstamped producer) is skipped" {
    var l = Latch{};
    l.consumed(0);
    try std.testing.expectEqual(@as(?u64, null), l.presented(1_000));
    // And it must not displace a real pending receipt either.
    l.consumed(400);
    l.consumed(0);
    try std.testing.expectEqual(@as(?u64, 600), l.presented(1_000));
}

test "non-monotonic now reports 0, never a wrapped astronomical delta" {
    var l = Latch{};
    l.consumed(1_000);
    try std.testing.expectEqual(@as(?u64, 0), l.presented(500));
}

test "deltaUs converts ticks at the calibrated rate" {
    // 1 GHz: 16_700_000 ticks = 16_700 µs (the one-frame scale this measures).
    try std.testing.expectEqual(@as(u64, 16_700), deltaUs(16_700_000, TSC_1GHZ));
    try std.testing.expectEqual(@as(u64, 0), deltaUs(999, TSC_1GHZ));
}

test "deltaUs on an uncalibrated TSC reports 0, not a division artifact" {
    try std.testing.expectEqual(@as(u64, 0), deltaUs(123_456, 0));
    try std.testing.expectEqual(@as(u64, 0), deltaUs(123_456, 999_999));
}

test "overBudget is a strict threshold: at budget passes, past it fails" {
    try std.testing.expect(!overBudget(0, 16_700));
    try std.testing.expect(!overBudget(16_700, 16_700));
    try std.testing.expect(overBudget(16_701, 16_700));
}
