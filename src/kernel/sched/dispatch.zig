//! Where a runnable task runs: the core-placement policy (KRN-009, KRN-010,
//! KRN-011).
//!
//! Every online core is eligible to run every task, and no core is reserved for a
//! role — so placement is decided from two bitmasks and nothing else: which cores
//! are online, and which of them are idle. Pure, so the policy is host-testable
//! without a scheduler; sched.zig supplies the masks and performs the enqueue.
//!
//! The rule is one sentence: **a task that needs the CPU goes to an idle core when
//! there is one.** `pickCore` finds that core; `handoff` is the same question asked
//! from the other side, when a core is switching away from a task it could give to
//! an idle neighbour instead of queueing behind its own work.
//!
//! Both searches scan UPWARD FROM A CALLER-CHOSEN CORE AND WRAP, rather than
//! always starting at zero. Scanning from zero would make the low-numbered cores
//! absorb every placement and leave the high-numbered ones cold — the "core 0 is
//! special" shape in a new form. Starting the scan where the work already is keeps
//! a task on its own core when that core is free (the warm cache) and otherwise
//! spreads placements evenly around the machine.

const std = @import("std");

/// Cores addressable by the masks. One `u64` bit per core — the same width the
/// fault-containment mask uses, and at or above `acpi.MAX_CPUS`, the hard cap on
/// cores the topology may report.
pub const MASK_BITS: u32 = 64;

/// The mask bit for core `core`.
pub fn bit(core: u32) u64 {
    return @as(u64, 1) << @intCast(core % MASK_BITS);
}

/// An idle online core to run a newly-runnable task on, or null when every online
/// core is busy. The scan starts at `prefer` and wraps, so passing the task's own
/// last core keeps it there when that core is free and hands it to the nearest
/// free neighbour otherwise.
///
/// Null does NOT mean "nowhere to run": it means no core is idle, and the caller
/// queues the task on a busy core instead. Only the idle case is a placement
/// decision; queueing behind existing work is not.
pub fn pickCore(prefer: u32, online: u64, idle: u64) ?u32 {
    return scanFrom(prefer, idle & online);
}

/// The idle core a busy core should hand its outgoing task to, or null to keep the
/// task local. A core hands work away ONLY when it has other runnable work of its
/// own (`others_waiting`) — otherwise the two cores would simply swap which one is
/// idle, costing a migration and buying nothing.
///
/// The scan starts one past `self_core`, and `self_core` is excluded outright: a
/// core cannot hand a task to itself, and it is not idle anyway while it is
/// running one.
pub fn handoff(self_core: u32, others_waiting: bool, online: u64, idle: u64) ?u32 {
    if (!others_waiting) return null;
    return scanFrom(self_core + 1, idle & online & ~bit(self_core));
}

/// The lowest set bit of `mask` at or after `from`, wrapping around the top —
/// null when `mask` is empty. Rotating the mask so `from` sits at bit 0 turns the
/// wrapped search into a single count-trailing-zeros, so placement costs the same
/// whether the machine has two cores or sixty-four.
fn scanFrom(from: u32, mask: u64) ?u32 {
    if (mask == 0) return null;
    const start: u6 = @intCast(from % MASK_BITS);
    const offset: u32 = @ctz(std.math.rotr(u64, mask, start));
    return (from + offset) % MASK_BITS;
}
