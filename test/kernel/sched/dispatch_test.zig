//! Host tests of src/kernel/sched/dispatch.zig — the core-placement policy.
//!
//! The requirements under test:
//!   KRN-009 — every online core is eligible; no core is reserved for a role.
//!   KRN-010 — a task that becomes runnable goes to an idle core whenever one is
//!             idle, so no core stays idle while a task waits to run.
//!   KRN-011 — a task is not confined to one core over its lifetime.

const std = @import("std");
const dispatch = @import("dispatch");
const testing = std.testing;

/// A mask with bits set for cores `0..n`.
fn cores(n: u32) u64 {
    var m: u64 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) m |= dispatch.bit(i);
    return m;
}

/// A mask with exactly the listed cores set.
fn only(list: []const u32) u64 {
    var m: u64 = 0;
    for (list) |c| m |= dispatch.bit(c);
    return m;
}

// --- bit ------------------------------------------------------------------

test "bit names one core per mask position" {
    try testing.expectEqual(@as(u64, 1), dispatch.bit(0));
    try testing.expectEqual(@as(u64, 2), dispatch.bit(1));
    try testing.expectEqual(@as(u64, 1) << 63, dispatch.bit(63));
    // The mask is exactly MASK_BITS wide, so a core index at the width wraps to
    // bit 0 rather than shifting out of range.
    try testing.expectEqual(dispatch.bit(0), dispatch.bit(dispatch.MASK_BITS));
}

// --- pickCore: the KRN-010 rule -------------------------------------------

test "an idle core is chosen whenever one is idle" {
    const online = cores(4);
    // Core 2 is the only idle core: it is chosen no matter where the scan starts.
    var start: u32 = 0;
    while (start < 4) : (start += 1) {
        try testing.expectEqual(@as(?u32, 2), dispatch.pickCore(start, online, only(&.{2})));
    }
}

test "no idle core means no placement decision" {
    // Every online core is busy: the caller queues behind existing work instead.
    try testing.expectEqual(@as(?u32, null), dispatch.pickCore(0, cores(4), 0));
}

test "a task returns to its own core when that core is idle" {
    // Locality (KRN-011 permits migration; it does not demand it): scanning from
    // the task's last core keeps it there when the core is free.
    const online = cores(4);
    const idle = only(&.{ 1, 3 });
    try testing.expectEqual(@as(?u32, 1), dispatch.pickCore(1, online, idle));
    try testing.expectEqual(@as(?u32, 3), dispatch.pickCore(3, online, idle));
}

test "a task moves to the nearest idle core when its own is busy" {
    // KRN-011: the same task is not confined to the core it last ran on.
    const online = cores(4);
    try testing.expectEqual(@as(?u32, 3), dispatch.pickCore(2, online, only(&.{3})));
    // …and the search wraps rather than giving up at the top of the machine.
    try testing.expectEqual(@as(?u32, 0), dispatch.pickCore(2, online, only(&.{0})));
    // "Nearest" is upward-with-wrap, so the scan passes the higher cores first
    // and only then comes back around to the low ones.
    try testing.expectEqual(@as(?u32, 3), dispatch.pickCore(1, online, only(&.{ 0, 3 })));
    try testing.expectEqual(@as(?u32, 0), dispatch.pickCore(3, online, only(&.{ 0, 1 })));
}

test "no core is preferred over another (KRN-009, ARCH-016)" {
    // The whole machine idle: starting the scan at each core in turn must place a
    // task on each core in turn. A policy that favoured core 0 — the shape kudos
    // used to have — would return 0 every time and fail here.
    const online = cores(8);
    const idle = online;
    var c: u32 = 0;
    while (c < 8) : (c += 1) {
        try testing.expectEqual(@as(?u32, c), dispatch.pickCore(c, online, idle));
    }
}

test "an idle core that is not online is never chosen" {
    // Cores past the online count have no scheduler and no idle task; a stale bit
    // must not place work on one. Only cores 0..1 are up.
    const online = cores(2);
    try testing.expectEqual(@as(?u32, null), dispatch.pickCore(0, online, only(&.{ 5, 9 })));
    try testing.expectEqual(@as(?u32, 1), dispatch.pickCore(0, online, only(&.{ 1, 5 })));
}

test "a single-core machine places everything on its one core" {
    try testing.expectEqual(@as(?u32, 0), dispatch.pickCore(0, cores(1), cores(1)));
    try testing.expectEqual(@as(?u32, null), dispatch.pickCore(0, cores(1), 0));
}

test "an empty machine places nothing" {
    try testing.expectEqual(@as(?u32, null), dispatch.pickCore(0, 0, 0));
    // …not even when the idle mask claims cores the online mask does not.
    try testing.expectEqual(@as(?u32, null), dispatch.pickCore(0, 0, ~@as(u64, 0)));
}

test "the top core is reachable" {
    const online = ~@as(u64, 0);
    try testing.expectEqual(@as(?u32, 63), dispatch.pickCore(0, online, only(&.{63})));
    // Scanning from the top core wraps to the bottom.
    try testing.expectEqual(@as(?u32, 0), dispatch.pickCore(63, online, only(&.{0})));
    try testing.expectEqual(@as(?u32, 63), dispatch.pickCore(63, online, only(&.{63})));
}

// --- handoff: shedding the outgoing task ----------------------------------

test "a core with no other work keeps its outgoing task" {
    // Handing the task away would just swap which core is idle: a migration that
    // buys nothing. `others_waiting == false` is the whole condition.
    try testing.expectEqual(@as(?u32, null), dispatch.handoff(0, false, cores(4), cores(4)));
}

test "a core with other work sheds to an idle neighbour" {
    // This is KRN-010 seen from the busy side: core 0 has more runnable tasks than
    // it can run, core 2 is idle, so the outgoing task goes to core 2 instead of
    // queueing behind core 0's own work.
    try testing.expectEqual(@as(?u32, 2), dispatch.handoff(0, true, cores(4), only(&.{2})));
}

test "a core never hands a task to itself" {
    // A core's own idle bit can still be set when it reaches this decision (it is
    // cleared as the core takes work). Excluding self is what stops a task being
    // "migrated" to the core it is already on.
    try testing.expectEqual(@as(?u32, null), dispatch.handoff(1, true, cores(4), only(&.{1})));
    try testing.expectEqual(@as(?u32, 3), dispatch.handoff(1, true, cores(4), only(&.{ 1, 3 })));
}

test "a busy machine keeps every task where it is" {
    try testing.expectEqual(@as(?u32, null), dispatch.handoff(0, true, cores(4), 0));
}

test "handoff spreads around the machine rather than piling onto core 0" {
    // KRN-001: work spreads across all available cores — the live half is boot-3's
    // placement phase (N pegged tasks must land on N distinct cores).
    // Every core but the caller is idle: each caller sheds to its own neighbour,
    // so N busy cores shedding at once fill N distinct cores instead of all
    // stacking on the lowest-numbered one.
    const online = cores(4);
    try testing.expectEqual(@as(?u32, 1), dispatch.handoff(0, true, online, online));
    try testing.expectEqual(@as(?u32, 2), dispatch.handoff(1, true, online, online));
    try testing.expectEqual(@as(?u32, 3), dispatch.handoff(2, true, online, online));
    try testing.expectEqual(@as(?u32, 0), dispatch.handoff(3, true, online, online)); // wraps
}

test "handoff ignores idle cores that are not online" {
    try testing.expectEqual(@as(?u32, null), dispatch.handoff(0, true, cores(2), only(&.{7})));
}
