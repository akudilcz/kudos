//! Host tests of src/kernel/timer/uptime.zig — the wall-clock definition, and
//! the proof of its invariant: with the TSC calibrated, the clock advances even
//! when the tick counter is dead (a core captured the rotating tick with
//! interrupts masked and the PIT edge is never serviced again).

const std = @import("std");
const uptime = @import("uptime");

// A free test parameter: the PIT rate is an input to the definition (the
// kernel passes timer's live configuration).
const TICK_HZ: u32 = 100;

test "invariant: a dead tick cannot stop the calibrated clock" {
    // The tick counter froze at 500 (the captured rotation); TSC-derived
    // milliseconds keep climbing — and so must the clock, monotonically.
    const dead_tick: u64 = 500;
    var last: u64 = 0;
    var tsc_ms: u64 = 10_000;
    while (tsc_ms < 10_100) : (tsc_ms += 1) {
        const now = uptime.ms(tsc_ms, dead_tick, TICK_HZ);
        try std.testing.expect(now > last);
        try std.testing.expectEqual(tsc_ms, now);
        last = now;
    }
}

test "before calibration the tick counter backs the clock" {
    // tsc_ms == 0 means "no TSC frequency yet": 100 Hz ticks are 10 ms each.
    try std.testing.expectEqual(@as(u64, 0), uptime.ms(0, 0, TICK_HZ));
    try std.testing.expectEqual(@as(u64, 10), uptime.ms(0, 1, TICK_HZ));
    try std.testing.expectEqual(@as(u64, 5_000), uptime.ms(0, 500, TICK_HZ));
}

test "no clock source at all reads as zero" {
    try std.testing.expectEqual(@as(u64, 0), uptime.ms(0, 12345, 0));
}
