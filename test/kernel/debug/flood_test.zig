//! Host tests of src/kernel/debug/flood.zig.

const std = @import("std");
const flood = @import("flood");
const Action = flood.Action;
const CMP_CAP = flood.CMP_CAP;
const PASS_REPEATS = flood.PASS_REPEATS;
const SUMMARY_EVERY = flood.SUMMARY_EVERY;
const Suppressor = flood.Suppressor;
const expectEqual = std.testing.expectEqual;

test "a distinct line always passes straight through" {
    var s = Suppressor{};
    try expectEqual(Action.emit, s.feed("one\n").action);
    try expectEqual(Action.emit, s.feed("two\n").action);
    try expectEqual(Action.emit, s.feed("three\n").action);
    try expectEqual(@as(u32, 0), s.outstanding());
}

test "regression: a thousand identical lines cost ~19 wire lines, not a thousand" {
    // The drain is METERED, so an unbounded repeat does not merely add noise: at the
    // drain rate a thousand lines is tens of seconds of backlog in which nothing else
    // about the machine is visible.
    var s = Suppressor{};
    const line = "wait timeout: xhci: event ring\n";

    var emitted: u32 = 0; // lines that reach the wire
    var markers: u32 = 0;
    var suppressed: u32 = 0;
    try expectEqual(Action.emit, s.feed(line).action); // the FIRST one always shows
    emitted += 1;

    var i: u32 = 1;
    while (i < 1044) : (i += 1) {
        const v = s.feed(line);
        switch (v.action) {
            .emit => emitted += 1, // the PASS_REPEATS grace: reads better verbatim
            .suppress => suppressed += 1,
            .summary => {
                markers += 1;
                suppressed += 1;
                try expectEqual(SUMMARY_EVERY, v.count); // each marker reports 64
            },
            else => unreachable,
        }
    }

    try expectEqual(@as(u32, 1 + PASS_REPEATS), emitted); // 3 verbatim
    try expectEqual(@as(u32, 1043 - PASS_REPEATS), suppressed); // 1041 collapsed
    try expectEqual(@as(u32, 1041 / SUMMARY_EVERY), markers); // 16 markers
    // 1044 lines -> 3 verbatim + 16 markers = 19 on the wire, and the flood is still
    // VISIBLE: you can see it happening, and how fast.
    try expectEqual(@as(u32, 19), emitted + markers);
    try expectEqual(@as(u32, 1041 - 16 * SUMMARY_EVERY), s.outstanding()); // 17 owed
}

test "a line appearing two or three times is NOT a flood — it prints verbatim" {
    // Replacing a single duplicate with `repeated 1 more time` trades a line you can
    // read for a line about a line. Suppression must only engage on a real flood.
    var s = Suppressor{};
    try expectEqual(Action.emit, s.feed("dup\n").action);
    try expectEqual(Action.emit, s.feed("dup\n").action);
    try expectEqual(Action.emit, s.feed("dup\n").action);
    try expectEqual(@as(u32, 0), s.outstanding()); // nothing owed, nothing collapsed

    // The FOURTH is where it starts collapsing.
    try expectEqual(Action.suppress, s.feed("dup\n").action);
    try expectEqual(@as(u32, 1), s.outstanding());
}

test "when the flood ends, the outstanding repeats are reported — never lost" {
    var s = Suppressor{};
    _ = s.feed("spam\n");
    var i: u32 = 0;
    while (i < 5) : (i += 1) _ = s.feed("spam\n"); // 5 repeats; PASS_REPEATS of them print

    const v = s.feed("something else\n");
    try expectEqual(Action.summary_then_emit, v.action);
    try expectEqual(@as(u32, 5 - PASS_REPEATS), v.count); // the count survives the transition
    try expectEqual(@as(u32, 0), s.outstanding());

    // …and the new line is now the one being tracked (its own grace applies).
    try expectEqual(Action.emit, s.feed("something else\n").action);
}

test "the repeat counter resets across a marker, so counts do not double-report" {
    var s = Suppressor{};
    _ = s.feed("x\n");

    // Feed PASS_REPEATS (which print) + SUMMARY_EVERY (which collapse): exactly one
    // marker, reporting exactly SUMMARY_EVERY, and nothing carried over.
    var markers: u32 = 0;
    var i: u32 = 0;
    while (i < PASS_REPEATS + SUMMARY_EVERY) : (i += 1) {
        const v = s.feed("x\n");
        if (v.action == .summary) {
            markers += 1;
            try expectEqual(SUMMARY_EVERY, v.count);
        }
    }
    try expectEqual(@as(u32, 1), markers);
    try expectEqual(@as(u32, 0), s.outstanding()); // reset, not carried
}

test "alternating lines are never suppressed" {
    // A/B/A/B is not a flood — suppression must only collapse CONSECUTIVE repeats,
    // or a busy two-line loop would vanish from the trace entirely.
    var s = Suppressor{};
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try expectEqual(Action.emit, s.feed("A\n").action);
        try expectEqual(Action.emit, s.feed("B\n").action);
    }
}

test "lines longer than CMP_CAP compare on their PREFIX, not their tail" {
    // Two DIFFERENT lines that agree for CMP_CAP bytes are the same line for our purposes
    // — feeding the identical line twice would prove nothing about prefix comparison.
    var s = Suppressor{};
    const a = ("x" ** CMP_CAP) ++ "AAAA";
    const b = ("x" ** CMP_CAP) ++ "BBBB"; // differs only PAST the compare window
    try expectEqual(Action.emit, s.feed(a).action);
    var i: u32 = 0;
    while (i < PASS_REPEATS) : (i += 1) _ = s.feed(b); // the verbatim grace
    try expectEqual(Action.suppress, s.feed(b).action); // treated as a repeat of `a`

    // …and a line differing WITHIN the window is a different line.
    var t = Suppressor{};
    try expectEqual(Action.emit, t.feed("aaa\n").action);
    try expectEqual(Action.emit, t.feed("aab\n").action);
}

test "takeOutstanding drains the count for a final flush" {
    var s = Suppressor{};
    _ = s.feed("y\n");
    var i: u32 = 0;
    while (i < PASS_REPEATS + 2) : (i += 1) _ = s.feed("y\n");
    try expectEqual(@as(u32, 2), s.outstanding()); // 2 beyond the verbatim grace
    try expectEqual(@as(u32, 2), s.takeOutstanding());
    try expectEqual(@as(u32, 0), s.outstanding()); // drained
}
