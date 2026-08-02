//! Host tests for src/apps/spin.zig — the model-viewer spin angle as a pure
//! function of a microsecond timestamp. The properties that make the rotation
//! silky: consecutive 60 Hz frames see uniform angle steps (a coarse-grain
//! clock alternates step sizes and judders), the step stays uniform after
//! weeks of uptime (an f32 time base would not), and the angle stays wrapped.

const std = @import("std");
const spin = @import("spin");

/// One 60 Hz frame in microseconds — the desktop's present cadence, the rate
/// this suite probes the angle at.
const FRAME_US: u64 = 16_667;

/// The unwrapped angle step between two instants (adds one revolution when
/// the raw difference crosses a wrap).
fn step(t0_us: u64, t1_us: u64) f64 {
    const a0: f64 = spin.angleRad(t0_us);
    var a1: f64 = spin.angleRad(t1_us);
    if (a1 < a0) a1 += std.math.tau;
    return a1 - a0;
}

/// Every step across `frames` consecutive frames starting at `base_us` is
/// within 0.1% of the ideal SPIN_RATE * frame-time step.
fn expectUniformSteps(base_us: u64, frames: u64) !void {
    const ideal: f64 = @as(f64, spin.SPIN_RATE) * (@as(f64, FRAME_US) / std.time.us_per_s);
    var i: u64 = 0;
    while (i < frames) : (i += 1) {
        const s = step(base_us + i * FRAME_US, base_us + (i + 1) * FRAME_US);
        try std.testing.expect(@abs(s - ideal) < ideal * 0.001);
    }
}

test "angle stays in [0, tau) at any uptime" {
    // Boot, one frame, near a wrap boundary, a day, thirty days.
    for ([_]u64{ 0, FRAME_US, 5_711_986, 86_400_000_000, 2_592_000_000_000 }) |t_us| {
        const a = spin.angleRad(t_us);
        try std.testing.expect(a >= 0);
        try std.testing.expect(a < std.math.tau);
    }
}

test "sixty-hertz steps are uniform from boot" {
    // 600 frames = 10 s, covering many wrap boundaries. A millisecond-grain
    // clock fails here: at 10 ms grain the steps alternate 1-vs-2 ticks.
    try expectUniformSteps(0, 600);
}

test "sixty-hertz steps are still uniform after thirty days" {
    // An angle carried unwrapped in f32 loses the per-frame step long before
    // this; the wrapped-in-f64 computation must not.
    try expectUniformSteps(2_592_000_000_000, 600);
}

test "the lamp is a unit-length DIRECTIONAL light" {
    // w = 0 makes GL_POSITION a direction, not a point — the viewer and the
    // render oracle both rely on that, and GL does not normalize it for us.
    const d = spin.LAMP_DIR;
    const len2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
    try std.testing.expect(@abs(len2 - 1.0) < 0.01);
    try std.testing.expectEqual(@as(f32, 0), d[3]);
}
