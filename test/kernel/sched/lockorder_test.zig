//! Host tests of src/kernel/sched/lockorder.zig — the pure policy of the
//! scheduler's lock lattice (timer_lock → Task.lock → run_lock). The kernel
//! glue (per-core held-set, panic) is exercised live by every scheduler
//! operation of a -Dtest-hooks boot; the DECISION is proven here.

const std = @import("std");
const lockorder = @import("testroot").kernel.lockorder;
const violates = lockorder.violates;
const expect = std.testing.expect;

fn mask(comptime ranks: []const lockorder.Rank) u8 {
    var m: u8 = 0;
    for (ranks) |r| m |= @as(u8, 1) << @intFromEnum(r);
    return m;
}

test "ascending acquisition through the lattice is legal" {
    try expect(!violates(0, .timer));
    try expect(!violates(0, .task));
    try expect(!violates(0, .run));
    try expect(!violates(mask(&.{.timer}), .task)); // sleeper release -> wake
    try expect(!violates(mask(&.{.task}), .run)); // wake -> enqueue
    try expect(!violates(mask(&.{ .timer, .task }), .run)); // the full chain
}

test "descending or recursive acquisition is a violation" {
    try expect(violates(mask(&.{.run}), .task)); // run held, task wanted
    try expect(violates(mask(&.{.run}), .timer));
    try expect(violates(mask(&.{.task}), .timer));
    try expect(violates(mask(&.{.timer}), .timer)); // recursion is never legal
    try expect(violates(mask(&.{.task}), .task));
    try expect(violates(mask(&.{.run}), .run));
    try expect(violates(mask(&.{ .timer, .run }), .task)); // any held higher rank convicts
}
