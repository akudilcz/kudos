//! Host tests of src/drivers/gpu/present/flip_pacing.zig.

const std = @import("std");
const flip_pacing = @import("flip_pacing");
const Decision = flip_pacing.Decision;
const decide = flip_pacing.decide;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const frameUs = flip_pacing.frameUs;
const spacedEnough = flip_pacing.spacedEnough;
const spacingUs = flip_pacing.spacingUs;

// Synthetic beam simulation: drive the SAME wait structure present_real runs (the
// decision selects which waits happen; the waits advance simulated time to the
// beam edges) and assert exactly ONE go lands in every refresh — the pacing
// contract both field bugs violated (30fps = some refreshes got zero; 78/s = some
// got two).
const Beam = struct {
    period: u64, // refresh interval, ticks (1 tick = 1 µs here)
    active: u64, // active-scanout portion; the rest of the period is vblank

    fn inBlank(self: Beam, t: u64) bool {
        return (t % self.period) >= self.active;
    }
    /// Next instant strictly at/after `t` when the beam is in ACTIVE (phase-1 wait).
    fn nextActive(self: Beam, t: u64) u64 {
        if (!self.inBlank(t)) return t;
        return (t / self.period + 1) * self.period; // active starts each period
    }
    /// Next ACTIVE→BLANK rising edge at/after `t` (phase-2 wait: loops while active).
    fn nextBlankEdge(self: Beam, t: u64) u64 {
        if (self.inBlank(t)) return t; // already in blank → the loop exits at once
        return (t / self.period) * self.period + self.active;
    }
};

/// One waitFlipLatched call at time `t.*`: run the decision + the selected waits
/// against the beam, advance `t.*` to when the wait returns (the go instant).
fn simulateWait(beam: Beam, t: *u64, last_flip: u64, spacing: u64) void {
    switch (decide(beam.inBlank(t.*), t.*, last_flip, spacing)) {
        .go => {},
        .wait_active_then_edge => {
            t.* = beam.nextActive(t.*); // phase 1: wait OUT of blank
            t.* = beam.nextBlankEdge(t.*); // phase 2: catch the rising edge
        },
        .wait_edge => t.* = beam.nextBlankEdge(t.*),
    }
}

test "frameUs: h_total*v_total*1000/clk" {
    // 1000×500 total pixels at 500 MHz pixel clock → 1000 µs.
    try expectEqual(@as(u64, 1000), frameUs(.{ .h = 800, .h_blank = 200, .v = 450, .v_blank = 50, .clock_khz = 500_000 }));
    // The primary ultrawide-ish shape: sanity that a ~60 Hz mode lands near 16.7 ms.
    const us = frameUs(.{ .h = 3440, .h_blank = 560, .v = 1440, .v_blank = 72, .clock_khz = 365_000 });
    try expect(us > 16_000 and us < 17_500);
}

test "frameUs: clk=0 is clamped, never traps, still finite" {
    try expectEqual(@as(u64, 1000 * 500 * 1000), frameUs(.{ .h = 800, .h_blank = 200, .v = 450, .v_blank = 50, .clock_khz = 0 }));
}

test "spacedEnough: warm start (last_flip==0) is always spaced" {
    try expect(spacedEnough(0, 0, 12_500));
    try expect(spacedEnough(999_999, 0, 12_500));
}

test "spacedEnough: boundary at exactly the spacing threshold (PERF-004: one new frame per refresh)" {
    const spacing: u64 = spacingUs(16_667); // 12500
    try expectEqual(@as(u64, 12_500), spacing);
    try expect(!spacedEnough(100_000 + spacing - 1, 100_000, spacing)); // 1 under → too soon
    try expect(spacedEnough(100_000 + spacing, 100_000, spacing)); // exactly → spaced
}

test "spacedEnough: tick-counter wraparound (-%) does not trap" {
    const last: u64 = std.math.maxInt(u64) - 10;
    try expect(spacedEnough(20_000, last, 12_500)); // wrapped delta ≈ 20010
}

test "warm start in blank goes immediately" {
    try expectEqual(Decision.go, decide(true, 12_345, 0, 12_500));
}

test "same-vblank re-entry does not double-flip" {
    // The ~78 presents/s over-present bug: a µs-fast iteration re-enters while the
    // beam is STILL in the vblank the previous flip is latching into. The fast
    // path must be refused; a full out-of-blank + edge wait is required.
    const flip_t: u64 = 100_000;
    try expectEqual(Decision.wait_active_then_edge, decide(true, flip_t + 50, flip_t, 12_500));
}

test "spaced but mid-active waits for the edge (never flips mid-scanout)" {
    try expectEqual(Decision.wait_edge, decide(false, 100_000 + 16_000, 100_000, 12_500));
    // Warm start mid-active too: spaced by definition, still must catch the edge.
    try expectEqual(Decision.wait_edge, decide(false, 5, 0, 12_500));
}

test "too soon and mid-active: phase-1 wait is selected (falls through instantly)" {
    // !spaced always selects wait_active_then_edge; when already in active the
    // caller's phase-1 loop exits immediately, so this equals wait_edge in effect.
    try expectEqual(Decision.wait_active_then_edge, decide(false, 100_000 + 100, 100_000, 12_500));
}

test "spacing boundary at exactly 3/4 frame: fast path opens" {
    const spacing = spacingUs(16_667);
    const flip_t: u64 = 200_000;
    try expectEqual(Decision.wait_active_then_edge, decide(true, flip_t + spacing - 1, flip_t, spacing));
    try expectEqual(Decision.go, decide(true, flip_t + spacing, flip_t, spacing));
}

test "exactly one go per refresh over a synthetic beam sequence" {
    const beam = Beam{ .period = 16_667, .active = 15_600 }; // ~60 Hz, ~1.07 ms vblank
    const spacing = spacingUs(beam.period);
    var flips_in_refresh = [_]u32{0} ** 64;
    var t: u64 = 3_000; // boot mid-active, mid-refresh 0
    var last_flip: u64 = 0;
    // µs-fast iterations (the over-present trigger) mixed with slow composites.
    const composite_costs = [_]u64{ 5, 5, 900, 5, 14_000, 5, 5, 2_300, 5, 60 };
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        simulateWait(beam, &t, last_flip, spacing);
        last_flip = t; // the flip arms at the go instant
        flips_in_refresh[@intCast(t / beam.period)] += 1;
        t += composite_costs[i % composite_costs.len]; // next iteration arrives after the composite
    }
    // Every refresh between the first and last flip got EXACTLY one flip: no
    // skipped refresh (the 30fps bug) and no double flip (the 78/s bug).
    const first = 3_000 / beam.period;
    const last = last_flip / beam.period;
    var r = first;
    while (r <= last) : (r += 1) try expectEqual(@as(u32, 1), flips_in_refresh[@intCast(r)]);
}

test "warm start goes immediately only if in blank; never double-arms within one vblank" {
    const beam = Beam{ .period = 16_667, .active = 15_600 };
    const spacing = spacingUs(beam.period);
    // Boot inside vblank: warm start takes the fast path at once.
    var t: u64 = beam.active + 10; // in blank of refresh 0
    simulateWait(beam, &t, 0, spacing);
    try expectEqual(@as(u64, beam.active + 10), t); // went immediately
    const flip1 = t;
    // Re-enter 5 µs later, same vblank: must NOT go — waits a full period for the
    // next edge (rising edge of refresh 1's vblank).
    t += 5;
    simulateWait(beam, &t, flip1, spacing);
    try expectEqual(beam.period + beam.active, t);
}
