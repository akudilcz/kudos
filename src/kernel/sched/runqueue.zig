//! The scheduler's two intrusive lists: the per-core run queue and the per-core
//! deadline-sleeper list.
//!
//! Both are pure and generic over the task type — this module never dereferences
//! a kernel type, allocates, or touches hardware — so the ordering rules that the
//! scheduler's correctness rests on are host-testable on their own. sched.zig
//! instantiates them with its `Task` and supplies the locking; neither structure
//! takes a lock of its own, because the lock that protects a run queue also
//! protects the core's idle bit and the two must be updated together.
//!
//! `RunQueue` is FIFO: a task re-entering the queue goes behind everything already
//! waiting, which is what makes round-robin fair. `SleeperList` is sorted by wake
//! deadline ascending, so the earliest deadline — the one the core's timer must be
//! armed for — is always the head.

/// A node type for `RunQueue` must carry `next: ?*T`.
/// A node type for `SleeperList` must carry `sleep_next: ?*T` and
/// `sleep_deadline: u64`.
///
/// FIFO run queue, intrusive through `T.next`. Holds no lock: every method must
/// be called with the owning core's run lock held.
pub fn RunQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,
        tail: ?*T = null,
        /// Tasks currently waiting to run. Kept alongside the list rather than
        /// counted on demand because it is read every frame (the per-core
        /// "waiting to run" figure) and a walk would be O(n) under the lock.
        len: u32 = 0,

        /// Append `t` behind everything already waiting.
        pub fn push(self: *Self, t: *T) void {
            t.next = null;
            if (self.tail) |tl| tl.next = t else self.head = t;
            self.tail = t;
            self.len += 1;
        }

        /// Take the longest-waiting task, or null when nothing is runnable here.
        pub fn pop(self: *Self) ?*T {
            const h = self.head orelse return null;
            self.head = h.next;
            if (self.head == null) self.tail = null;
            h.next = null;
            self.len -= 1;
            return h;
        }

        /// Whether the queue holds no task. The scheduler asks this to decide
        /// whether a core is about to go idle.
        pub fn isEmpty(self: *const Self) bool {
            return self.head == null;
        }
    };
}

/// Tasks sleeping until an absolute deadline, earliest first, intrusive through
/// `T.sleep_next`. A core arms its timer for `earliest()` and pops what is due.
/// Unbounded by construction: any number of a core's tasks may sleep at once, so
/// there is no slot to overflow and no sleeper to strand.
pub fn SleeperList(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,

        /// Add `t`, to be woken once the clock reaches `deadline`. Insertion sort
        /// into the sorted list — a core has a handful of sleepers at most, and
        /// keeping the earliest at the head is what lets `earliest()` be O(1) on
        /// the reschedule path. Equal deadlines keep insertion order.
        pub fn insert(self: *Self, t: *T, deadline: u64) void {
            t.sleep_deadline = deadline;
            var prev: ?*T = null;
            var cur = self.head;
            while (cur) |c| {
                if (c.sleep_deadline > deadline) break;
                prev = c;
                cur = c.sleep_next;
            }
            t.sleep_next = cur;
            if (prev) |p| p.sleep_next = t else self.head = t;
        }

        /// Remove `t` if it is still waiting, reporting whether it was. A sleeper
        /// woken early (its terminal closed while it slept) removes itself this
        /// way; one whose deadline already fired was popped by the timer and this
        /// is a no-op. Both paths run, so the caller never has to know which
        /// happened.
        pub fn remove(self: *Self, t: *T) bool {
            var prev: ?*T = null;
            var cur = self.head;
            while (cur) |c| {
                if (c == t) {
                    if (prev) |p| p.sleep_next = c.sleep_next else self.head = c.sleep_next;
                    c.sleep_next = null;
                    return true;
                }
                prev = c;
                cur = c.sleep_next;
            }
            return false;
        }

        /// Take the earliest sleeper if its deadline has passed, else null. Called
        /// in a loop so one timer interrupt releases every sleeper that is due,
        /// not just the first.
        pub fn popDue(self: *Self, now: u64) ?*T {
            const h = self.head orelse return null;
            if (h.sleep_deadline > now) return null;
            self.head = h.sleep_next;
            h.sleep_next = null;
            return h;
        }

        /// The deadline the core's timer must be armed for, or null when nothing
        /// on this core is sleeping.
        pub fn earliest(self: *const Self) ?u64 {
            const h = self.head orelse return null;
            return h.sleep_deadline;
        }
    };
}
