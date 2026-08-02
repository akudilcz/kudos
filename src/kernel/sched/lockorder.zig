//! Lock-order gate for the scheduler's lock lattice (test-hooks builds).
//!
//! The lattice, outermost first: `timer_lock` → `Task.lock` → `run_lock`.
//! Every acquire of those locks (sched.zig, sleep.zig, taskstat.zig) notes its
//! rank here after taking the lock; acquiring a rank at or below one this core
//! already holds is a LATENT DEADLOCK — two cores interleaving opposite orders
//! deadlock even when this particular run got away with it — and panics
//! immediately, turning a probabilistic wedge into a deterministic red run.
//!
//! The per-core held-set is consistent by construction: every lock in the
//! lattice is held only with interrupts masked, so nothing can interleave with
//! the note on the same core. Product builds compile the notes to nothing.

const buildinfo = @import("buildinfo");
const acpi = @import("../acpi/acpi.zig");
const percpu = @import("percpu.zig");

pub const Rank = enum(u3) { timer = 0, task = 1, run = 2 };

const enabled = buildinfo.test_hooks;

var held: [acpi.MAX_CPUS]u8 = @splat(0);

fn bit(r: Rank) u8 {
    return @as(u8, 1) << @intFromEnum(r);
}

/// Pure policy: acquiring `r` while `mask` is held is a violation unless every
/// held rank is strictly lower — the lattice is acquired in ascending rank
/// order only, and never recursively.
pub fn violates(mask: u8, r: Rank) bool {
    return (mask >> @intFromEnum(r)) != 0;
}

/// Note a lattice lock as taken (call with the lock held, interrupts masked).
pub inline fn acquired(r: Rank) void {
    if (comptime !enabled) return;
    const i = percpu.indexOrZero();
    if (violates(held[i], r)) @panic("lock-order violation: the scheduler lattice is timer_lock -> Task.lock -> run_lock, ascending only");
    held[i] |= bit(r);
}

/// Note a lattice lock as released (call before the release restores IRQs).
pub inline fn released(r: Rank) void {
    if (comptime !enabled) return;
    held[percpu.indexOrZero()] &= ~bit(r);
}
