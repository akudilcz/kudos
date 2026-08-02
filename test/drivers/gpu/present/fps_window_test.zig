//! Host tests of src/drivers/gpu/present/fps_window.zig.

const std = @import("std");
const fps_window = @import("fps_window");
const FpsWindow = fps_window.FpsWindow;
const expectEqual = std.testing.expectEqual;

// 1 tick = 1 µs in these tests; a 5 s window like present.zig's FPS_WINDOW_S.
const HZ: u64 = 1_000_000;
const WINDOW: u64 = 5 * HZ;

test "fewer than 2 samples reads 0" {
    var w = FpsWindow(16).init();
    try expectEqual(@as(u32, 0), w.rate(HZ));
    w.push(100, WINDOW + 1_000, WINDOW);
    try expectEqual(@as(u32, 0), w.rate(HZ));
}

test "dt=0 guard: two samples at the same instant read 0" {
    var w = FpsWindow(16).init();
    w.push(100, WINDOW, WINDOW);
    w.push(200, WINDOW, WINDOW);
    try expectEqual(@as(u32, 0), w.rate(HZ));
}

test "correct rate for a synthetic 60Hz stream sampled at 2Hz" {
    var w = FpsWindow(16).init();
    // 30 frames per 500 ms sample period = 60 fps.
    var t: u64 = WINDOW; // start late enough that the cutoff never underflows
    var frames: u64 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        w.push(frames, t, WINDOW);
        t += HZ / 2;
        frames += 30;
    }
    try expectEqual(@as(u32, 60), w.rate(HZ));
}

test "eviction at the window edge: stale samples drop, rate follows the recent window" {
    var w = FpsWindow(16).init();
    const t0: u64 = WINDOW;
    // Two old samples at 120 fps, 4.9 s apart — still inside the window at first.
    w.push(0, t0, WINDOW);
    w.push(588, t0 + 4_900_000, WINDOW);
    try expectEqual(@as(u32, 120), w.rate(HZ));
    // A sample 5.5 s after t0: t0 is now older than the window → evicted; the
    // rate spans only the surviving pair (588→618 over 0.6 s = 50 fps).
    w.push(618, t0 + 5_500_000, WINDOW);
    try expectEqual(@as(u32, 50), w.rate(HZ));
}

test "eviction always keeps at least one sample (sparse pushes)" {
    var w = FpsWindow(16).init();
    w.push(0, WINDOW, WINDOW);
    // Next push arrives 10 s later — the old sample is way past the cutoff, but
    // the count>1 guard keeps it until this push lands, so the pair still spans
    // real time: 600 frames / 10 s = 60 fps.
    w.push(600, WINDOW + 10 * HZ, WINDOW);
    try expectEqual(@as(u32, 60), w.rate(HZ));
    try expectEqual(@as(usize, 2), w.count);
}

test "full-ring drop: capacity bounds the window, oldest goes first" {
    var w = FpsWindow(4).init();
    // 6 pushes into a 4-slot ring, 100 ms apart (all inside the time window):
    // pushes 5 and 6 must each drop the oldest.
    var t: u64 = WINDOW;
    var frames: u64 = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        w.push(frames, t, WINDOW);
        t += 100_000;
        frames += 6; // 60 fps
    }
    try expectEqual(@as(usize, 4), w.count);
    // Oldest surviving sample is push #3 (frames=12, t=WINDOW+200ms).
    try expectEqual(@as(u64, 12), w.smp[w.head].count);
    try expectEqual(@as(u32, 60), w.rate(HZ));
}
