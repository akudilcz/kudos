//! Analog clock-face geometry — PURE (imports only std): given seconds since
//! midnight, a centre, and a radius, produce the line segments for the twelve
//! hour ticks and the three hands. The clock app draws each returned segment
//! with `Painter.line`; all trigonometry lives here, host-tested.
//!
//! Convention: 12 o'clock points UP. Screen y grows DOWN, so a hand at angle
//! θ (clockwise from 12) ends at (cx + sin θ · len, cy − cos θ · len).

const std = @import("std");

/// One drawable line segment, in the caller's (screen) coordinates.
pub const Segment = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// Hour marks around the dial.
pub const TICK_COUNT: u32 = 12;

// Dial proportions, as fractions of the face radius. The tick band hugs the
// rim; hands are staggered so all three read at a glance.
const TICK_INNER: f32 = 0.84;
const TICK_OUTER: f32 = 0.95;
const HOUR_LEN: f32 = 0.50;
const MINUTE_LEN: f32 = 0.72;
const SECOND_LEN: f32 = 0.80;

const SECONDS_PER_MINUTE: f32 = 60;
const SECONDS_PER_HOUR: f32 = 60 * 60;
const SECONDS_PER_HALF_DAY: f32 = 12 * 60 * 60;
const TAU: f32 = 2.0 * std.math.pi;

/// A segment radiating from the centre: from `inner`·r to `outer`·r at angle
/// θ clockwise from 12 o'clock.
fn radial(cx: f32, cy: f32, r: f32, theta: f32, inner: f32, outer: f32) Segment {
    const s = @sin(theta);
    const c = @cos(theta);
    return .{
        .x0 = cx + s * (r * inner),
        .y0 = cy - c * (r * inner),
        .x1 = cx + s * (r * outer),
        .y1 = cy - c * (r * outer),
    };
}

/// The i-th hour tick (0 = 12 o'clock, clockwise).
pub fn tick(i: u32, cx: f32, cy: f32, r: f32) Segment {
    const theta = TAU * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(TICK_COUNT));
    return radial(cx, cy, r, theta, TICK_INNER, TICK_OUTER);
}

/// The hour hand: sweeps continuously (20:30 points midway between 8 and 9).
pub fn hourHand(seconds_since_midnight: u64, cx: f32, cy: f32, r: f32) Segment {
    const s: f32 = @floatFromInt(seconds_since_midnight);
    const theta = TAU * (@mod(s, SECONDS_PER_HALF_DAY) / SECONDS_PER_HALF_DAY);
    return radial(cx, cy, r, theta, 0, HOUR_LEN);
}

/// The minute hand: sweeps continuously within its hour.
pub fn minuteHand(seconds_since_midnight: u64, cx: f32, cy: f32, r: f32) Segment {
    const s: f32 = @floatFromInt(seconds_since_midnight);
    const theta = TAU * (@mod(s, SECONDS_PER_HOUR) / SECONDS_PER_HOUR);
    return radial(cx, cy, r, theta, 0, MINUTE_LEN);
}

/// The second hand: steps once per second.
pub fn secondHand(seconds_since_midnight: u64, cx: f32, cy: f32, r: f32) Segment {
    const s: f32 = @floatFromInt(seconds_since_midnight);
    const theta = TAU * (@mod(s, SECONDS_PER_MINUTE) / SECONDS_PER_MINUTE);
    return radial(cx, cy, r, theta, 0, SECOND_LEN);
}
