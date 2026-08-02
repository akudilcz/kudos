//! Host tests of src/kernel/debug/deadman.zig.

const std = @import("std");
const deadman = @import("testroot").kernel.deadman;
const Policy = deadman.Policy;
const REPORT_EVERY_MS = deadman.REPORT_EVERY_MS;
const WEDGE_AFTER_MS = deadman.WEDGE_AFTER_MS;
const expect = std.testing.expect;

test "unarmed policy never reports (boot, idle APs)" {
    var p = Policy{};
    try expect(!p.due(10_000));
    try expect(!p.due(1_000_000));
}

test "a live loop never trips the fuse" {
    var p = Policy{};
    var now: u64 = 0;
    while (now < 100_000) : (now += 100) {
        p.alive(now);
        try expect(!p.due(now + 50));
    }
}

test "silence past the fuse reports, then paces at REPORT_EVERY_MS (DIAG-012)" {
    var p = Policy{};
    p.alive(1_000);
    try expect(!p.due(1_000 + WEDGE_AFTER_MS - 1)); // not yet
    try expect(p.due(1_000 + WEDGE_AFTER_MS)); // fuse blown: report
    try expect(!p.due(1_000 + WEDGE_AFTER_MS + REPORT_EVERY_MS - 1)); // paced
    try expect(p.due(1_000 + WEDGE_AFTER_MS + REPORT_EVERY_MS)); // next report
}

test "recovering (alive again) closes the report window" {
    var p = Policy{};
    p.alive(0);
    try expect(p.due(WEDGE_AFTER_MS));
    p.alive(WEDGE_AFTER_MS + 10); // the loop came back
    try expect(!p.due(WEDGE_AFTER_MS + 20));
    try expect(!p.due(WEDGE_AFTER_MS + REPORT_EVERY_MS + 20));
}
