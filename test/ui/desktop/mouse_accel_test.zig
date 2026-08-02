//! Host tests of src/ui/desktop/mouse_accel.zig.

const std = @import("std");
const mouse_accel = @import("mouse_accel");
const Accelerator = mouse_accel.Accelerator;
const HZ = mouse_accel.HZ;
const accelFactor = mouse_accel.accelFactor;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "first sample passes through unaccelerated (no prior timestamp)" {
    var a = Accelerator{};
    const r = a.apply(5, 3, 1000, HZ);
    try expectEqual(@as(i32, 5), r.dx);
    try expectEqual(@as(i32, 3), r.dy);
}

// DSK-019: pointer acceleration — the factor must VARY with speed; the slow,
// moderate and fast cases together fail any fixed multiplier.
test "slow motion is damped below 1:1" {
    var a = Accelerator{};
    _ = a.apply(1, 0, 0, HZ);
    // speed = 1/dt_ms; want speed < 0.07 => dt_ms > 1/0.07 ~= 14.3ms
    const r = a.apply(1, 0, 20_000_000, HZ); // dt = 20ms
    // speed = 1/20 = 0.05 u/ms -> factor = 10*0.05+0.3 = 0.8 -> round(0.8) = 1
    try expectEqual(@as(i32, 1), r.dx);
    // The 0.2 rounded away must be preserved as carry, not dropped.
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), a.carry_x, 1e-9);
}

test "moderate motion is 1:1" {
    var a = Accelerator{};
    _ = a.apply(1, 0, 0, HZ);
    // speed = 10 / 1ms = 10 u/ms is way past threshold; pick a mid value instead.
    // want 0.07 <= speed < 0.4: dx=1, dt such that speed=0.2 -> dt = 1/0.2 = 5ms
    const r = a.apply(1, 0, 5_000_000, HZ);
    try expectEqual(@as(i32, 1), r.dx); // factor == 1.0 exactly in the plateau
}

test "fast motion is amplified above the threshold" {
    var a = Accelerator{};
    _ = a.apply(1, 0, 0, HZ);
    // speed = 10 / dt_ms; want speed >> threshold(0.4), e.g. speed = 2 u/ms -> dt = 5ms, dx=10
    const r = a.apply(10, 0, 5_000_000, HZ);
    // factor = 1.1*(2-0.4)+1 = 2.76 -> capped at 2.0
    try expectEqual(@as(i32, 20), r.dx); // 10 * 2.0 (capped)
}

test "fractional carry accumulates and eventually emits a pixel" {
    var a = Accelerator{};
    _ = a.apply(1, 0, 0, HZ);
    // Repeated slow samples at factor 0.8 (dt=20ms as above): 0.8 + 0.8 + 0.8 ...
    // should eventually round up to 1 without losing motion (sum stays exact).
    var total_out: i32 = 0;
    var t: u64 = 20_000_000;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const r = a.apply(1, 0, t, HZ);
        total_out += r.dx;
        t += 20_000_000;
    }
    // 10 samples * 0.8 = 8.0 total motion; carry must not lose any of it.
    try expectEqual(@as(i32, 8), total_out);
}

test "duplicate timestamp (dt == 0) takes the dt_ms > 0 else-branch: factor 1.0" {
    var a = Accelerator{};
    _ = a.apply(1, 0, 1000, HZ);
    const r = a.apply(1, 0, 1000, HZ); // same t_tsc as prev -> dt_ticks == 0
    try expectEqual(@as(i32, 1), r.dx); // unaccelerated, no NaN/inf from a 0/0 speed
}

test "resetVelocity forces the next sample to pass through unaccelerated" {
    var a = Accelerator{};
    _ = a.apply(1, 0, 0, HZ);
    a.resetVelocity();
    const r = a.apply(7, 0, 5_000_000, HZ); // would otherwise compute a real factor
    try expectEqual(@as(i32, 7), r.dx);
}

test "ramp segment below the cap is NOT clamped to max_accel" {
    var a = Accelerator{};
    _ = a.apply(1, 0, 0, HZ);
    // Want threshold(0.4) <= speed < the speed where factor hits 2.0 (cap).
    // factor = 1.1*(speed-0.4)+1 = 2.0 => speed = 0.4 + 1/1.1 ~= 1.309.
    // Pick speed = 0.6 u/ms: dx=3, dt=5ms -> speed = 0.6.
    const r = a.apply(3, 0, 5_000_000, HZ);
    // factor = 1.1*(0.6-0.4)+1 = 1.22 (well under the 2.0 cap)
    try expectEqual(@as(i32, 4), r.dx); // round(3 * 1.22) = round(3.66) = 4
}

test "hz_ticks_per_sec == 0 falls back to factor 1.0 (no crash, no div-by-zero)" {
    var a = Accelerator{};
    _ = a.apply(1, 0, 0, HZ);
    const r = a.apply(9, 0, 5_000_000, 0); // hz=0 despite a real dt
    try expectEqual(@as(i32, 9), r.dx); // unaccelerated: hz==0 guard short-circuits
}

test "accelFactor: exact values at libinput's documented reference speeds" {
    // Decel segment: 10*speed + 0.3.
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), accelFactor(0.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.65), accelFactor(0.035), 1e-9);
    // Segment boundaries are continuous (both sides evaluate to 1.0).
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), accelFactor(0.07), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), accelFactor(0.4 - 1e-9), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), accelFactor(0.4), 1e-9);
    // Ramp segment: 1.1*(speed-0.4)+1.
    try std.testing.expectApproxEqAbs(@as(f64, 1.22), accelFactor(0.6), 1e-9);
    // Exactly the speed where the ramp reaches the 2.0 cap: 0.4 + 1/1.1.
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), accelFactor(0.4 + 1.0 / 1.1), 1e-9);
    // Past the cap speed, factor stays clamped at 2.0, does not keep climbing.
    try expectEqual(@as(f64, 2.0), accelFactor(5.0));
}

test "dy axis is accelerated independently of dx, with its own carry" {
    var a = Accelerator{};
    _ = a.apply(0, 1, 0, HZ);
    // Same slow-speed setup as the dx damping test, but on Y: factor 0.8.
    const r = a.apply(0, 1, 20_000_000, HZ);
    try expectEqual(@as(i32, 0), r.dx);
    try expectEqual(@as(i32, 1), r.dy);
    try std.testing.expectApproxEqAbs(@as(f64, 0), a.carry_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), a.carry_y, 1e-9);
}

test "negative (leftward/upward) motion accelerates symmetrically by magnitude" {
    var a = Accelerator{};
    _ = a.apply(-1, 0, 0, HZ);
    // Same speed as the "fast motion" test (2 u/ms, capped at 2.0x) but negative.
    const r = a.apply(-10, 0, 5_000_000, HZ);
    try expectEqual(@as(i32, -20), r.dx); // -10 * 2.0, sign preserved
}

test "diagonal motion uses combined (hypot) magnitude, not per-axis speed" {
    var a = Accelerator{};
    _ = a.apply(0, 0, 0, HZ);
    // dx=3, dy=4 -> magnitude 5. dt=5ms -> speed = 5/5 = 1.0 u/ms (ramp segment).
    const r = a.apply(3, 4, 5_000_000, HZ);
    // factor = 1.1*(1.0-0.4)+1 = 1.66
    try expectEqual(@as(i32, 5), r.dx); // round(3*1.66) = round(4.98) = 5
    try expectEqual(@as(i32, 7), r.dy); // round(4*1.66) = round(6.64) = 7
}

test "diagonal motion in the damped segment (factor < 1) is also hypot-combined" {
    var a = Accelerator{};
    _ = a.apply(0, 0, 0, HZ);
    // dx=3, dy=4 -> magnitude 5. dt=100ms -> speed = 5/100 = 0.05 u/ms (decel segment).
    const r = a.apply(3, 4, 100_000_000, HZ);
    // factor = 10*0.05 + 0.3 = 0.8
    try expectEqual(@as(i32, 2), r.dx); // round(3*0.8) = round(2.4) = 2
    try expectEqual(@as(i32, 3), r.dy); // round(4*0.8) = round(3.2) = 3
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), a.carry_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), a.carry_y, 1e-9);
}

test "rounding at an exact .5 boundary goes away from zero, both signs" {
    // Seed a -0.5 carry via a damped sample (factor 0.5 exactly: 10*0.02+0.3), then land
    // a plateau (factor 1.0) sample exactly on an X.5 total: 3*1 + (-0.5) = 2.5.
    var pos = Accelerator{};
    _ = pos.apply(0, 0, 0, HZ);
    const seed = pos.apply(1, 0, 50_000_000, HZ); // dt=50ms, speed=0.02 -> factor 0.5
    try expectEqual(@as(i32, 1), seed.dx); // round(0.5) = 1 (away from zero)
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), pos.carry_x, 1e-9);
    const r = pos.apply(3, 0, 60_000_000, HZ); // dt=10ms from prev, speed=0.3 -> plateau factor 1.0
    try expectEqual(@as(i32, 3), r.dx); // fx = 3 - 0.5 = 2.5 -> round(2.5) = 3 (away from zero)

    // Mirror on the negative side.
    var neg = Accelerator{};
    _ = neg.apply(0, 0, 0, HZ);
    const nseed = neg.apply(-1, 0, 50_000_000, HZ);
    try expectEqual(@as(i32, -1), nseed.dx); // round(-0.5) = -1 (away from zero)
    const nr = neg.apply(-3, 0, 60_000_000, HZ);
    try expectEqual(@as(i32, -3), nr.dx); // fx = -2.5 -> round(-2.5) = -3 (away from zero)
}

test "resetVelocity: carry survives a reset (documented contract), verified by exact conservation" {
    var a = Accelerator{};
    _ = a.apply(0, 0, 0, HZ);
    const r1 = a.apply(1, 0, 20_000_000, HZ); // dt=20ms, speed=0.05 -> factor 0.8
    try expectEqual(@as(i32, 1), r1.dx); // round(0.8) = 1, carry = -0.2
    try std.testing.expectApproxEqAbs(@as(f64, -0.2), a.carry_x, 1e-9);

    a.resetVelocity();
    // Next sample is forced un-accelerated (factor 1.0, no prior timestamp) but the
    // carry from BEFORE the reset must still be applied — resetVelocity only clears
    // velocity history, not the fractional remainder owed to the cursor (line 48-49).
    const r2 = a.apply(1, 0, 999_000_000, HZ);
    try expectEqual(@as(i32, 1), r2.dx); // fx = 1*1.0 + (-0.2) = 0.8 -> round = 1

    // Exact conservation proof: total real motion owed across both calls is
    // 0.8 (damped) + 1.0 (unaccelerated) = 1.8 units. If the carry had been dropped
    // by resetVelocity, this sum would be 2.0 instead of 1.8 — the discrepancy a
    // silently-zeroed carry would introduce.
    const total_out: f64 = @as(f64, @floatFromInt(r1.dx + r2.dx)) + a.carry_x;
    try std.testing.expectApproxEqAbs(@as(f64, 1.8), total_out, 1e-9);
}

test "backwards/duplicate-source timestamp (t_tsc <= prev_t_tsc) wraps, does not crash or NaN" {
    var a = Accelerator{};
    _ = a.apply(0, 0, 1000, HZ);
    // t_tsc(500) < prev_t_tsc(1000): dt_ticks = 500 -% 1000 wraps to near u64::max,
    // producing a huge dt_ms and thus a near-zero speed -> the decel floor (factor 0.3).
    const r = a.apply(5, 0, 500, HZ);
    try expect(!std.math.isNan(@as(f64, @floatFromInt(r.dx))));
    try expectEqual(@as(i32, 2), r.dx); // round(5 * 0.3) = round(1.5) = 2 (away from zero)
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), a.carry_x, 1e-6);
}

test "very large dt without resetVelocity (long idle gap) settles at the decel floor, no NaN/Inf" {
    var a = Accelerator{};
    _ = a.apply(0, 0, 0, HZ);
    const one_hour_later: u64 = 3600 * HZ;
    const r = a.apply(5, 0, one_hour_later, HZ);
    try expect(!std.math.isNan(@as(f64, @floatFromInt(r.dx))));
    try expectEqual(@as(i32, 2), r.dx); // speed ~= 1.39e-6 u/ms -> factor ~= 0.3 -> round(1.5) = 2
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), a.carry_x, 1e-4);
}
