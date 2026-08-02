//! Host tests of src/kernel/sched/runqueue.zig — the run queue's FIFO order and
//! the sleeper list's deadline order.

const std = @import("std");
const runqueue = @import("runqueue");
const testing = std.testing;

/// A stand-in task carrying exactly the links the two lists reach through. The
/// lists never look at anything else, so a `tag` is enough to identify a node in
/// an assertion.
const Node = struct {
    tag: u32,
    next: ?*Node = null,
    sleep_next: ?*Node = null,
    sleep_deadline: u64 = 0,
};

const Queue = runqueue.RunQueue(Node);
const Sleepers = runqueue.SleeperList(Node);

/// The tags a queue yields, popped to exhaustion.
fn drain(q: *Queue, out: []u32) []u32 {
    var n: usize = 0;
    while (q.pop()) |t| : (n += 1) out[n] = t.tag;
    return out[0..n];
}

// --- RunQueue -------------------------------------------------------------

test "a fresh queue is empty and yields nothing" {
    var q = Queue{};
    try testing.expect(q.isEmpty());
    try testing.expectEqual(@as(u32, 0), q.len);
    try testing.expectEqual(@as(?*Node, null), q.pop());
}

test "tasks come back out in the order they went in" {
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var c = Node{ .tag = 3 };
    var q = Queue{};
    q.push(&a);
    q.push(&b);
    q.push(&c);
    try testing.expectEqual(@as(u32, 3), q.len);
    try testing.expect(!q.isEmpty());
    var buf: [3]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, drain(&q, &buf));
}

test "a re-queued task goes behind everything already waiting" {
    // This is what makes round-robin fair: a preempted task does not jump back to
    // the front of its core's queue.
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var q = Queue{};
    q.push(&a);
    q.push(&b);
    const first = q.pop().?;
    q.push(first);
    var buf: [2]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 2, 1 }, drain(&q, &buf));
}

test "the waiting count tracks pushes and pops" {
    // The per-core "waiting to run" figure the heads-up display reads: it must
    // stay exact across an emptied and refilled queue, not drift.
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var q = Queue{};
    try testing.expectEqual(@as(u32, 0), q.len);
    q.push(&a);
    try testing.expectEqual(@as(u32, 1), q.len);
    q.push(&b);
    try testing.expectEqual(@as(u32, 2), q.len);
    _ = q.pop();
    try testing.expectEqual(@as(u32, 1), q.len);
    _ = q.pop();
    try testing.expectEqual(@as(u32, 0), q.len);
    try testing.expect(q.isEmpty());
    q.push(&a);
    try testing.expectEqual(@as(u32, 1), q.len);
}

test "emptying the queue leaves it reusable" {
    // The tail must be dropped with the last task, or the next push would append
    // behind a task that is already running.
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var q = Queue{};
    q.push(&a);
    _ = q.pop();
    q.push(&b);
    try testing.expectEqual(@as(u32, 2), q.pop().?.tag);
    try testing.expectEqual(@as(?*Node, null), q.pop());
}

test "a popped task carries no stale link" {
    // A task about to be handed to another core must not still point at this
    // core's next task, or that core would inherit the whole chain.
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var q = Queue{};
    q.push(&a);
    q.push(&b);
    const first = q.pop().?;
    try testing.expectEqual(@as(?*Node, null), first.next);
}

// --- SleeperList ----------------------------------------------------------

test "a fresh sleeper list has no deadline and nothing due" {
    var s = Sleepers{};
    try testing.expectEqual(@as(?u64, null), s.earliest());
    try testing.expectEqual(@as(?*Node, null), s.popDue(0));
    try testing.expectEqual(@as(?*Node, null), s.popDue(~@as(u64, 0)));
}

test "the earliest deadline is always at the head" {
    // The core arms its timer for this value, so an out-of-order insert would
    // leave a sleeper overdue with the timer set for someone later.
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var c = Node{ .tag = 3 };
    var s = Sleepers{};
    s.insert(&a, 300);
    try testing.expectEqual(@as(?u64, 300), s.earliest());
    s.insert(&b, 100); // before the head
    try testing.expectEqual(@as(?u64, 100), s.earliest());
    s.insert(&c, 200); // into the middle
    try testing.expectEqual(@as(?u64, 100), s.earliest());
    try testing.expectEqual(@as(u32, 2), s.popDue(1000).?.tag);
    try testing.expectEqual(@as(u32, 3), s.popDue(1000).?.tag);
    try testing.expectEqual(@as(u32, 1), s.popDue(1000).?.tag);
}

test "insertion after every existing sleeper still links in" {
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var s = Sleepers{};
    s.insert(&a, 100);
    s.insert(&b, 200); // past the tail
    try testing.expectEqual(@as(?u64, 100), s.earliest());
    try testing.expectEqual(@as(u32, 1), s.popDue(1000).?.tag);
    try testing.expectEqual(@as(u32, 2), s.popDue(1000).?.tag);
}

test "equal deadlines keep insertion order" {
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var s = Sleepers{};
    s.insert(&a, 500);
    s.insert(&b, 500);
    try testing.expectEqual(@as(u32, 1), s.popDue(500).?.tag);
    try testing.expectEqual(@as(u32, 2), s.popDue(500).?.tag);
}

test "nothing is released before its deadline" {
    var a = Node{ .tag = 1 };
    var s = Sleepers{};
    s.insert(&a, 100);
    try testing.expectEqual(@as(?*Node, null), s.popDue(99));
    try testing.expectEqual(@as(u32, 1), s.popDue(100).?.tag); // exactly due
}

test "one timer interrupt releases every sleeper that is due" {
    // Several tasks can come due between two interrupts; popDue is called in a
    // loop, so the second and third must not be left asleep until the next one.
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var c = Node{ .tag = 3 };
    var s = Sleepers{};
    s.insert(&a, 100);
    s.insert(&b, 150);
    s.insert(&c, 900);
    var woken: [3]u32 = undefined;
    var n: usize = 0;
    while (s.popDue(200)) |t| : (n += 1) woken[n] = t.tag;
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, woken[0..n]);
    try testing.expectEqual(@as(?u64, 900), s.earliest()); // c still sleeping
}

test "a sleeper woken early removes itself" {
    // The cancel path: a task whose terminal closed while it slept must leave the
    // list, or the timer would later dereference a task that has been freed.
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var c = Node{ .tag = 3 };
    var s = Sleepers{};
    s.insert(&a, 100);
    s.insert(&b, 200);
    s.insert(&c, 300);
    try testing.expect(s.remove(&b)); // from the middle
    try testing.expect(s.remove(&a)); // the head
    try testing.expectEqual(@as(?u64, 300), s.earliest());
    try testing.expect(s.remove(&c)); // the last one
    try testing.expectEqual(@as(?u64, null), s.earliest());
}

test "removing a sleeper that already fired is a harmless no-op" {
    // The teardown runs unconditionally, because the sleeper cannot tell whether
    // its deadline or an early wake resumed it.
    var a = Node{ .tag = 1 };
    var s = Sleepers{};
    s.insert(&a, 100);
    _ = s.popDue(100);
    try testing.expect(!s.remove(&a));
    try testing.expect(!s.remove(&a)); // and again
}

test "removing from an empty list reports nothing removed" {
    var a = Node{ .tag = 1 };
    var s = Sleepers{};
    try testing.expect(!s.remove(&a));
}

test "a removed sleeper carries no stale link" {
    var a = Node{ .tag = 1 };
    var b = Node{ .tag = 2 };
    var s = Sleepers{};
    s.insert(&a, 100);
    s.insert(&b, 200);
    try testing.expect(s.remove(&a));
    try testing.expectEqual(@as(?*Node, null), a.sleep_next);
    try testing.expectEqual(@as(u32, 2), s.popDue(1000).?.tag);
}

test "a sleeper re-sleeps after waking" {
    // Exactly what a drift-free periodic task does every period: wake, work,
    // insert again with the next absolute deadline.
    var a = Node{ .tag = 1 };
    var s = Sleepers{};
    var deadline: u64 = 100;
    var period: u32 = 0;
    while (period < 4) : (period += 1) {
        s.insert(&a, deadline);
        try testing.expectEqual(@as(?u64, deadline), s.earliest());
        try testing.expectEqual(@as(u32, 1), s.popDue(deadline).?.tag);
        try testing.expectEqual(@as(?u64, null), s.earliest());
        deadline += 100;
    }
}

test "any number of a core's tasks may sleep at once" {
    // The old scheduler held ONE deadline slot per core and panicked on the
    // second sleeper — an invariant that only held while a core hosted a single
    // terminal. With tasks free to run on any core, several sleepers can share
    // one core, and all of them must wake in deadline order.
    var nodes: [16]Node = undefined;
    var s = Sleepers{};
    for (&nodes, 0..) |*n, i| {
        n.* = .{ .tag = @intCast(i) };
        // Insert in reverse deadline order, so every insert lands at the head.
        s.insert(n, @as(u64, 16 - i) * 10);
    }
    var expected: u32 = 15;
    while (s.popDue(1000)) |t| {
        try testing.expectEqual(expected, t.tag);
        if (expected == 0) break;
        expected -= 1;
    }
    try testing.expectEqual(@as(u32, 0), expected);
    try testing.expectEqual(@as(?u64, null), s.earliest());
}
