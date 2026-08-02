//! Host tests of src/widgets/clockface.zig — the hand/tick trigonometry.
//! The analog clock application face (spec APP-019).

const std = @import("std");
const clockface = @import("clockface");
const expect = std.testing.expect;

const EPS = 0.001;

fn approx(a: f32, b: f32) bool {
    return @abs(a - b) < EPS;
}

test "at midnight every hand points straight up" {
    inline for (.{ clockface.hourHand, clockface.minuteHand, clockface.secondHand }) |hand| {
        const seg = hand(0, 100, 100, 50);
        try expect(approx(seg.x0, 100) and approx(seg.y0, 100)); // from the centre
        try expect(approx(seg.x1, 100)); // straight up: no x displacement
        try expect(seg.y1 < 100); // up = smaller y in screen space
    }
}

test "hands at 09:15:45 point in their own quarter directions" {
    const t: u64 = 9 * 3600 + 15 * 60 + 45;
    const cx = 0.0;
    const cy = 0.0;
    const r = 1.0;

    // Second hand at 45 s: due LEFT (-x). It steps per second, so exactly 45.
    const sec = clockface.secondHand(t, cx, cy, r);
    try expect(sec.x1 < -0.5 and approx(sec.y1, 0));

    // Minute hand just past 15 min: pointing right (+x), slightly below level
    // because it sweeps continuously through the 45 extra seconds.
    const min = clockface.minuteHand(t, cx, cy, r);
    try expect(min.x1 > 0.5 and min.y1 > 0);

    // Hour hand just past 9: pointing left (-x), slightly above level.
    const hour = clockface.hourHand(t, cx, cy, r);
    try expect(hour.x1 < -0.25 and hour.y1 < 0);
}

test "the hour hand sweeps continuously between hours" {
    // 4:30 must point midway between 4 and 5, not at 4.
    const at4 = clockface.hourHand(4 * 3600, 0, 0, 1);
    const at430 = clockface.hourHand(4 * 3600 + 1800, 0, 0, 1);
    const at5 = clockface.hourHand(5 * 3600, 0, 0, 1);
    try expect(at430.x1 < at4.x1 and at430.x1 > at5.x1 or at430.x1 > at4.x1 and at430.x1 < at5.x1);
    try expect(!approx(at430.x1, at4.x1));
}

test "ticks: 12 o'clock is up, 3 o'clock is right, both hug the rim" {
    const top = clockface.tick(0, 0, 0, 10);
    try expect(approx(top.x0, 0) and approx(top.x1, 0));
    try expect(top.y1 < top.y0 and top.y1 < 0); // outward, upward

    const right = clockface.tick(3, 0, 0, 10);
    try expect(approx(right.y0, 0) and approx(right.y1, 0));
    try expect(right.x0 > 0); // the inner end sits on the +x side too
    try expect(right.x1 > right.x0 and right.x1 > 8); // outward, near the rim
}
