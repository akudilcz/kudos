//! Host tests of src/drivers/usb/debounce.zig.

const std = @import("std");
const debounce = @import("debounce");
const Debounce = debounce.Debounce;
const STABLE_MS = debounce.STABLE_MS;
const STEP_MS = debounce.STEP_MS;
const TIMEOUT_MS = debounce.TIMEOUT_MS;
const Verdict = debounce.Verdict;
const expectEqual = std.testing.expectEqual;

test "steady connect passes after exactly STABLE_MS of unchanged samples" {
    var d = Debounce{};
    // First sample latches; then STABLE_MS/STEP_MS unchanged samples accumulate.
    try expectEqual(Verdict.pending, d.feed(true, false));
    var i: u32 = 0;
    while (i < STABLE_MS / STEP_MS - 1) : (i += 1) {
        try expectEqual(Verdict.pending, d.feed(true, false));
    }
    try expectEqual(Verdict.stable_connected, d.feed(true, false));
}

test "steady empty port resolves stable_empty (fast no-device verdict)" {
    var d = Debounce{};
    var v = d.feed(false, false);
    while (v == .pending) v = d.feed(false, false);
    try expectEqual(Verdict.stable_empty, v);
}

test "a connect flip restarts the stability window" {
    var d = Debounce{};
    _ = d.feed(true, false);
    _ = d.feed(true, false);
    _ = d.feed(false, false); // bounce — window restarts on `false`
    // Now connected again: needs a full window from scratch.
    try expectEqual(Verdict.pending, d.feed(true, false)); // re-latch
    var i: u32 = 0;
    while (i < STABLE_MS / STEP_MS - 1) : (i += 1) {
        try expectEqual(Verdict.pending, d.feed(true, false));
    }
    try expectEqual(Verdict.stable_connected, d.feed(true, false));
}

test "a latched change bit restarts the window even with connect unchanged" {
    var d = Debounce{};
    _ = d.feed(true, false);
    _ = d.feed(true, false);
    _ = d.feed(true, true); // change bit seen — not stable
    var i: u32 = 0;
    while (i < STABLE_MS / STEP_MS - 1) : (i += 1) {
        try expectEqual(Verdict.pending, d.feed(true, false));
    }
    try expectEqual(Verdict.stable_connected, d.feed(true, false));
}

test "endless bouncing times out at TIMEOUT_MS" {
    var d = Debounce{};
    var flip = false;
    var verdict = Verdict.pending;
    var feeds: u32 = 0;
    while (verdict == .pending) {
        flip = !flip;
        verdict = d.feed(flip, false);
        feeds += 1;
    }
    try expectEqual(Verdict.timeout, verdict);
    try expectEqual(TIMEOUT_MS / STEP_MS, feeds);
}

test "stability reached exactly on the budget edge still passes" {
    // A bounce late in the budget: the window that completes on the final
    // in-budget sample must return stable, not timeout (stable is checked
    // before the budget).
    var d = Debounce{};
    var i: u32 = 0;
    const bounce_at = (TIMEOUT_MS - STABLE_MS) / STEP_MS - 1;
    while (i < bounce_at) : (i += 1) _ = d.feed(false, false);
    _ = d.feed(true, false); // late connect — restart window
    i = 0;
    var v = Verdict.pending;
    while (i < STABLE_MS / STEP_MS) : (i += 1) v = d.feed(true, false);
    try expectEqual(Verdict.stable_connected, v);
}
