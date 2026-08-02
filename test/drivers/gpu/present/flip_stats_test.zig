//! Host tests of src/drivers/gpu/present/flip_stats.zig.

const std = @import("std");
const flip_stats = @import("flip_stats");
const JITTER_BUDGET_US = flip_stats.JITTER_BUDGET_US;
const MEAN_TOL_PPM = flip_stats.MEAN_TOL_PPM;
const isqrt = flip_stats.isqrt;
const judge = flip_stats.judge;

/// One 60 Hz refresh interval in microseconds, the cadence every case is built on.
const REFRESH_60HZ_US: u64 = 16_667;

test "perfectly locked 60Hz window passes every criterion" {
    const ivs = [_]u64{REFRESH_60HZ_US} ** 512;
    const v = judge(&ivs, REFRESH_60HZ_US);
    try std.testing.expect(v.pass());
    try std.testing.expectEqual(REFRESH_60HZ_US, v.mean_us);
    try std.testing.expectEqual(@as(u64, 0), v.stdev_us);
}

test "realistic locked window (sub-ms jitter inside the budget) passes" {
    // Alternate ±300µs around the refresh — well inside JITTER_BUDGET_US.
    var ivs: [512]u64 = undefined;
    for (&ivs, 0..) |*iv, i| iv.* = if (i % 2 == 0) REFRESH_60HZ_US + 300 else REFRESH_60HZ_US - 300;
    const v = judge(&ivs, REFRESH_60HZ_US);
    try std.testing.expect(v.pass());
    try std.testing.expectEqual(@as(u64, 300), v.stdev_us);
}

test "the measured-bad 78-presents/s cadence FAILS `locked`" {
    // 78/s → mean ~12.8ms against a 16.67ms refresh (flip-sample-clean baseline).
    const ivs = [_]u64{12_820} ** 512;
    const v = judge(&ivs, REFRESH_60HZ_US);
    try std.testing.expect(!v.locked);
    try std.testing.expect(!v.pass());
}

test "one missed vblank in the window FAILS `steady`" {
    var ivs = [_]u64{REFRESH_60HZ_US} ** 512;
    ivs[300] = REFRESH_60HZ_US * 2; // a whole skipped refresh
    const v = judge(&ivs, REFRESH_60HZ_US);
    try std.testing.expect(v.locked); // one outlier barely moves the mean...
    try std.testing.expect(!v.steady); // ...but the absolute bound catches it
    try std.testing.expect(!v.pass());
}

test "a double-present (two composites, one scanout slot) FAILS `no_double`" {
    var ivs = [_]u64{REFRESH_60HZ_US} ** 512;
    ivs[10] = 2_000; // second present raced in 2ms after the first
    const v = judge(&ivs, REFRESH_60HZ_US);
    try std.testing.expect(!v.no_double);
    try std.testing.expect(!v.pass());
}

test "jitter exactly AT the budget still passes; one µs over fails" {
    var at = [_]u64{REFRESH_60HZ_US} ** 64;
    at[0] = REFRESH_60HZ_US + JITTER_BUDGET_US;
    try std.testing.expect(judge(&at, REFRESH_60HZ_US).steady);
    var over = [_]u64{REFRESH_60HZ_US} ** 64;
    over[0] = REFRESH_60HZ_US + JITTER_BUDGET_US + 1;
    try std.testing.expect(!judge(&over, REFRESH_60HZ_US).steady);
}

test "mean tolerance boundary (±2%)" {
    const tol = REFRESH_60HZ_US * MEAN_TOL_PPM / 1_000_000;
    const inside = [_]u64{REFRESH_60HZ_US + tol} ** 64;
    try std.testing.expect(judge(&inside, REFRESH_60HZ_US).locked);
    const outside = [_]u64{REFRESH_60HZ_US + tol + 1} ** 64;
    try std.testing.expect(!judge(&outside, REFRESH_60HZ_US).locked);
}

test "single-sample window is judged without dividing by zero" {
    const one = [_]u64{REFRESH_60HZ_US};
    try std.testing.expect(judge(&one, REFRESH_60HZ_US).pass());
}

test "isqrt sanity" {
    try std.testing.expectEqual(@as(u64, 0), isqrt(0));
    try std.testing.expectEqual(@as(u64, 1), isqrt(1));
    try std.testing.expectEqual(@as(u64, 300), isqrt(90_000));
    try std.testing.expectEqual(@as(u64, 4200), isqrt(4_200_000 * 4_200_000 / 1_000_000));
}

// ── the frame-drop rule (DIAG-003) ───────────────────────────────────────────
// The permanent per-present counter and the windowed FLIPSTAT verdict ask the
// same question through this one predicate. Its positive direction is what a
// suite cannot otherwise assert: every driver checks that `gpu.frame_drops`
// does not MOVE, which a counter wedged at zero satisfies perfectly.

test "an interval past refresh + the jitter budget is a missed deadline (DIAG-003)" {
    // A frame that took two refresh periods: the display showed the previous
    // frame twice, and that must be counted.
    try std.testing.expect(flip_stats.missedDeadline(2 * REFRESH_60HZ_US, REFRESH_60HZ_US));
    // Just past the budget still counts — the budget is the whole tolerance.
    try std.testing.expect(flip_stats.missedDeadline(
        REFRESH_60HZ_US + flip_stats.JITTER_BUDGET_US + 1,
        REFRESH_60HZ_US,
    ));
}

test "an on-time or early interval is not a missed deadline (DIAG-003)" {
    // Exactly on the refresh period, and exactly at the budget's edge: neither
    // is a drop, or the counter would climb through a perfectly smooth run and
    // the evidence would be worthless.
    try std.testing.expect(!flip_stats.missedDeadline(REFRESH_60HZ_US, REFRESH_60HZ_US));
    try std.testing.expect(!flip_stats.missedDeadline(
        REFRESH_60HZ_US + flip_stats.JITTER_BUDGET_US,
        REFRESH_60HZ_US,
    ));
    // A frame delivered early (the compositor beat the scanout) is not a drop.
    try std.testing.expect(!flip_stats.missedDeadline(REFRESH_60HZ_US / 2, REFRESH_60HZ_US));
}

test "the verdict's steady flag and the drop counter cannot disagree (DIAG-003)" {
    // One rule, one home: judge()'s `steady` is the same predicate over the
    // window's worst interval, so a run FLIPSTAT calls steady can never also
    // have incremented the permanent counter.
    const smooth = [_]u64{ REFRESH_60HZ_US, REFRESH_60HZ_US + 500, REFRESH_60HZ_US - 400 };
    const v = flip_stats.judge(&smooth, REFRESH_60HZ_US);
    try std.testing.expect(v.steady);
    for (smooth) |iv| try std.testing.expect(!flip_stats.missedDeadline(iv, REFRESH_60HZ_US));

    const stuttered = [_]u64{ REFRESH_60HZ_US, 3 * REFRESH_60HZ_US, REFRESH_60HZ_US };
    const v2 = flip_stats.judge(&stuttered, REFRESH_60HZ_US);
    try std.testing.expect(!v2.steady);
    try std.testing.expect(flip_stats.missedDeadline(stuttered[1], REFRESH_60HZ_US));
}
