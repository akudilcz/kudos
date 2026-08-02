//! Host tests of src/kernel/debug/spinwait.zig.

const std = @import("std");
const spinwait = @import("testroot").kernel.spinwait;
const Budget = spinwait.Budget;
const expect = std.testing.expect;

test "budget expires at the deadline, not before" {
    var b = Budget{ .deadline = 1_000, .enabled = true };
    try expect(!b.expiredAt(999));
    try expect(b.expiredAt(1_000));
    try expect(b.expiredAt(2_000));
}

test "firstExpiry fires exactly once" {
    var b = Budget{ .deadline = 100, .enabled = true };
    try expect(!b.firstExpiry(99));
    try expect(b.firstExpiry(100)); // the one report
    try expect(!b.firstExpiry(101)); // still expired, already reported
    try expect(b.expiredAt(101)); // expiry itself keeps holding
}

test "a disabled budget (no clock) never expires and never reports" {
    var b = Budget{ .deadline = 0, .enabled = false };
    try expect(!b.expiredAt(std.math.maxInt(u64)));
    try expect(!b.firstExpiry(std.math.maxInt(u64)));
}
