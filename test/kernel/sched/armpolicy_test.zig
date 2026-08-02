//! Host tests of src/kernel/sched/armpolicy.zig — the tickless arming policy.
//! These hold the two invariants that keep idle cheap and sleepers alive:
//! an idle core with nothing due arms NOTHING (KRN-007 — the halt is TRUE idle,
//! zero periodic wakeups), and an idle core with any sleeper — due or not —
//! stays armed, because the disarm-on-past-deadline variant was a shipped
//! forever-halt over a due sleeper.

const std = @import("std");
const armpolicy = @import("armpolicy");

const QUANTUM: u64 = 1000;

test "an idle core with no sleepers disarms the timer entirely (KRN-007)" {
    try std.testing.expectEqual(armpolicy.Decision.disarm, armpolicy.choose(true, 5000, 0, QUANTUM));
}

test "an idle core with a future sleeper arms for exactly that sleeper" {
    const d = armpolicy.choose(true, 5000, 7000, QUANTUM);
    try std.testing.expectEqual(@as(u64, 7000), d.arm);
}

test "an idle core with an already-due sleeper still arms — never a silent halt over it" {
    // The shipped hang: deadline slipped past mid-reschedule, interrupt already
    // consumed, core halted forever. A past TSC deadline fires immediately, so
    // arming it is the release path.
    const d = armpolicy.choose(true, 5000, 4000, QUANTUM);
    try std.testing.expectEqual(@as(u64, 4000), d.arm);
}

test "a runnable task is preempted at the quantum when no sleeper is nearer (KRN-008)" {
    const d = armpolicy.choose(false, 5000, 0, QUANTUM);
    try std.testing.expectEqual(@as(u64, 6000), d.arm);
}

test "a nearer future sleeper deadline beats the fairness quantum (KRN-008)" {
    const d = armpolicy.choose(false, 5000, 5500, QUANTUM);
    try std.testing.expectEqual(@as(u64, 5500), d.arm);
}

test "a stale (past) sleeper deadline never re-arms the past — the quantum wins" {
    const d = armpolicy.choose(false, 5000, 4999, QUANTUM);
    try std.testing.expectEqual(@as(u64, 6000), d.arm);
}
