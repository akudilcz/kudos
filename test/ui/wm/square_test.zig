//! Host tests of src/ui/wm/square.zig.

const std = @import("std");
const square = @import("square");
const Motion = square.Motion;
const SIZE = square.SIZE;
const STEP = square.STEP;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "reflects off the right edge: vx flips negative, stays in bounds" {
    // Screen 200 wide → max_x = 200 - SIZE. Start one step short of the wall
    // moving right; the step reaches/overshoots it and flips.
    const W: i32 = 200;
    const H: i32 = 200;
    const max_x = W - SIZE;
    var m = Motion{ .x = max_x - STEP + 1, .y = 0, .vx = STEP, .vy = STEP };
    m.step(W, H);
    try expectEqual(max_x, m.x); // clamped to the wall
    try expect(m.vx < 0); // reversed
}

test "reflects off the left edge: vx flips positive" {
    var m = Motion{ .x = STEP - 1, .y = 50, .vx = -STEP, .vy = STEP };
    m.step(400, 400);
    try expectEqual(@as(i32, 0), m.x);
    try expect(m.vx > 0);
}

test "reflects off top and bottom edges (vy)" {
    var top = Motion{ .x = 50, .y = STEP - 1, .vx = STEP, .vy = -STEP };
    top.step(400, 400);
    try expectEqual(@as(i32, 0), top.y);
    try expect(top.vy > 0);

    const H: i32 = 300;
    const max_y = H - SIZE;
    var bot = Motion{ .x = 50, .y = max_y - STEP + 1, .vx = STEP, .vy = STEP };
    bot.step(400, H);
    try expectEqual(max_y, bot.y);
    try expect(bot.vy < 0);
}

test "corner reflects both components" {
    const W: i32 = 200;
    const H: i32 = 200;
    var m = Motion{ .x = (W - SIZE) - STEP + 1, .y = (H - SIZE) - STEP + 1, .vx = STEP, .vy = STEP };
    m.step(W, H);
    try expect(m.vx < 0 and m.vy < 0);
    try expectEqual(W - SIZE, m.x);
    try expectEqual(H - SIZE, m.y);
}

test "never escapes the screen over a long random-ish run" {
    const W: i32 = 640;
    const H: i32 = 480;
    var m = Motion{ .x = 100, .y = 100, .vx = STEP, .vy = -STEP };
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        m.step(W, H);
        try expect(m.x >= 0 and m.x <= W - SIZE);
        try expect(m.y >= 0 and m.y <= H - SIZE);
    }
}

test "degenerate screen smaller than the square pins to origin" {
    var m = Motion{ .x = 0, .y = 0, .vx = STEP, .vy = STEP };
    m.step(SIZE - 10, SIZE - 10); // max_x/max_y clamp to 0
    try expectEqual(@as(i32, 0), m.x);
    try expectEqual(@as(i32, 0), m.y);
}

test "tick steps only on a NEW cadence phase" {
    var m = Motion.init(0);
    const x0 = m.x;
    try expect(!m.tick(0, 400, 400)); // phase 0 is the initial phase — no step
    try expect(m.tick(1, 400, 400)); // new phase: one step
    try expect(m.x != x0 or m.y != 0);
    const x1 = m.x;
    try expect(!m.tick(1, 400, 400)); // same phase again: no step
    try expectEqual(x1, m.x);
}
