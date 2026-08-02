//! Host tests of src/widgets/hudcontrol.zig — the heads-up display's control
//! state and rate arithmetic. Every one of these behaviours lived inside the
//! kernel-side sampler, where no test could reach it: an alarm that cleared
//! itself, a freeze that kept sampling, or a rate divided by the wrong
//! interval would all leave a display that looked entirely plausible.

const std = @import("std");
const hudcontrol = @import("hudcontrol");

test "showing samples immediately and clears any freeze (HUD-002)" {
    var c = hudcontrol.Control{};
    try std.testing.expect(c.toggle(1000)); // asks for an immediate sample
    try std.testing.expect(c.shown);
    try std.testing.expect(!c.frozen);

    // Frozen, hidden, then shown again: the freeze must NOT survive, or the
    // display returns showing numbers from before it was hidden.
    c.toggleFreeze();
    try std.testing.expect(c.frozen);
    try std.testing.expect(!c.toggle(2000)); // hide: no sample
    _ = c.toggle(3000); // show
    try std.testing.expect(!c.frozen);
}

test "a freeze stops sampling, and lifting it resumes (HUD-030)" {
    var c = hudcontrol.Control{};
    _ = c.toggle(0);
    try std.testing.expect(c.due(hudcontrol.SAMPLE_MS)); // a period later: sampled
    c.toggleFreeze();
    // However much time passes, a frozen display takes no new sample.
    try std.testing.expect(!c.due(hudcontrol.SAMPLE_MS * 10));
    try std.testing.expect(!c.due(hudcontrol.SAMPLE_MS * 100));
    c.toggleFreeze();
    try std.testing.expect(c.due(hudcontrol.SAMPLE_MS * 200));
}

test "a hidden display never samples, and freezing it does nothing" {
    var c = hudcontrol.Control{};
    try std.testing.expect(!c.due(hudcontrol.SAMPLE_MS * 10));
    c.toggleFreeze();
    try std.testing.expect(!c.frozen); // freeze is meaningless while hidden
}

test "sampling waits a full period, and is wrap-safe (HUD-032)" {
    var c = hudcontrol.Control{};
    _ = c.toggle(0);
    try std.testing.expect(!c.due(hudcontrol.SAMPLE_MS - 1)); // a millisecond early
    try std.testing.expect(c.due(hudcontrol.SAMPLE_MS));
    try std.testing.expect(!c.due(hudcontrol.SAMPLE_MS)); // already sampled at this instant

    // A clock that wraps must not stall sampling for the counter's whole age.
    var w = hudcontrol.Control{};
    _ = w.toggle(std.math.maxInt(u64) - 100);
    try std.testing.expect(w.due(std.math.maxInt(u64) -% 100 +% hudcontrol.SAMPLE_MS));
}

test "the alarm latches until acknowledged, and re-raises on the next fault (HUD-029)" {
    var c = hudcontrol.Control{};
    _ = c.toggle(0);
    c.observeFaults(0);
    try std.testing.expect(!c.alarm);

    c.observeFaults(1);
    try std.testing.expect(c.alarm);
    // THE POINT OF LATCHING: a fault that ticked once between samples must not
    // vanish because the next sample found the count unchanged.
    c.observeFaults(0);
    try std.testing.expect(c.alarm);

    c.acknowledge();
    try std.testing.expect(!c.alarm);
    c.observeFaults(0);
    try std.testing.expect(!c.alarm); // stays down while nothing new faults
    c.observeFaults(3);
    try std.testing.expect(c.alarm); // and re-raises on the next one
}

test "a counter's per-second rate is its delta over the real interval (HUD-020)" {
    // 250 events in half a second is 500/s.
    try std.testing.expectApproxEqAbs(
        @as(f64, 500),
        hudcontrol.ratePerSecond(1000, 1250, 500, true),
        0.001,
    );
    // The same delta over twice the interval is half the rate — the interval
    // is measured, not assumed to be one sampling period.
    try std.testing.expectApproxEqAbs(
        @as(f64, 250),
        hudcontrol.ratePerSecond(1000, 1250, 1000, true),
        0.001,
    );
}

test "the first sample and a counter that went backwards both read as no activity (HUD-020)" {
    // Nothing to difference against yet.
    try std.testing.expectEqual(@as(f64, 0), hudcontrol.ratePerSecond(0, 5000, 500, false));
    // A re-registered counter restarting at zero: the subtraction would
    // underflow into an enormous positive rate on an idle machine.
    try std.testing.expectEqual(@as(f64, 0), hudcontrol.ratePerSecond(5000, 3, 500, true));
    // A zero interval cannot be divided by.
    try std.testing.expectEqual(@as(f64, 0), hudcontrol.ratePerSecond(0, 100, 0, true));
}
