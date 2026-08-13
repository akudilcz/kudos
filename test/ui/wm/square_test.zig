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

test "spin angle: wrapped to [0,360), uniform steps, exact at large uptimes" {
    // One cadence step advances by exactly the rate constant.
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatCast(square.SPIN_DEG_PER_STEP)),
        square.angleDeg(1) - square.angleDeg(0),
        1e-6,
    );
    // Always inside one revolution, wherever the phase lands.
    var p: u64 = 0;
    while (p < 1000) : (p += 97) {
        const a = square.angleDeg(p);
        try expect(a >= 0 and a < 360);
    }
    // Decades of 100 Hz uptime: the f64 wrap keeps the per-step increment
    // accurate — an unwrapped f32 would have lost it within hours.
    const late: u64 = 10_000_000_000;
    const d = @mod(square.angleDeg(late + 1) - square.angleDeg(late) + 360.0, 360.0);
    try std.testing.expectApproxEqAbs(@as(f32, @floatCast(square.SPIN_DEG_PER_STEP)), d, 1e-3);
}

test "cube mesh: on the unit cube, wound outward, normals match the geometry" {
    try expectEqual(@as(usize, square.CUBE_VERTS * 3), square.VERTS.len);
    try expectEqual(square.VERTS.len, square.NORMS.len);
    // Every coordinate sits on the [-1,1] cube surface (corner vertices).
    for (square.VERTS) |c| try expect(c == 1 or c == -1);
    // Each triangle's geometric normal (edge cross product, CCW) equals its
    // stored per-face normal — this is both the outward-facing and the
    // winding check: culling with the default front face never eats a face.
    var t: usize = 0;
    while (t < square.CUBE_VERTS / 3) : (t += 1) {
        const a = square.VERTS[t * 9 + 0 .. t * 9 + 3];
        const b = square.VERTS[t * 9 + 3 .. t * 9 + 6];
        const c = square.VERTS[t * 9 + 6 .. t * 9 + 9];
        const e1 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const e2 = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
        var n = [3]f32{
            e1[1] * e2[2] - e1[2] * e2[1],
            e1[2] * e2[0] - e1[0] * e2[2],
            e1[0] * e2[1] - e1[1] * e2[0],
        };
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        for (&n) |*v| v.* /= len;
        for (0..3) |k| try std.testing.expectApproxEqAbs(square.NORMS[t * 9 + k], n[k], 1e-6);
    }
}

test "no rotation projects outside the orthographic bound" {
    // PROJ_HALF_EXTENT is the circumsphere radius: every vertex lies within
    // it, and rotation preserves length — so the SIZE-box viewport contains
    // the whole body at every spin angle (the scissor guarantees it anyway).
    var i: usize = 0;
    while (i < square.CUBE_VERTS) : (i += 1) {
        const v = square.VERTS[i * 3 .. i * 3 + 3];
        const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        try expect(len <= square.PROJ_HALF_EXTENT + 1e-6);
    }
}
