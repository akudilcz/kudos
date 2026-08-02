//! The trace ring's reservation algebra: how a writer claims a span of a
//! wrap-around byte ring without a lock, and how a reader derives the readable
//! window from the same counter.
//!
//! The failure this exists to avoid is not slowness, it is capture: a lock held
//! across the trace bus is a lock a faulting core can die holding, and then
//! every other core's next trace call spins forever — the diagnostics path
//! wedging exactly when something has gone wrong enough to need it. Under a
//! reservation there is nothing to hold: a writer claims its span with one
//! atomic add and copies into storage no other writer can claim. A writer that
//! dies mid-copy leaves a HOLE — garbage bytes in its own span — and blocks
//! nobody. A hole is honest; a wedge is not.
//!
//! Pure index algebra: no storage, no atomics beyond the single claim, so every
//! rule below is host-testable. `head` is monotonic — total bytes ever claimed,
//! never wrapped — and wrapping happens only when indexing storage, which is
//! what keeps "who owns which span" unambiguous across a wrap.

const std = @import("std");

/// One contiguous run of ring storage: `[off, off + len)` in the backing array.
pub const Span = struct { off: usize, len: usize };

/// A claimed region: where it starts in the monotonic stream and how long it
/// is. Storage offsets come from `spans`.
pub const Reservation = struct { pos: u64, len: usize };

/// Claim `n` bytes for this writer. The single atomic add is the whole of the
/// mutual exclusion: two cores adding concurrently get disjoint `pos` ranges,
/// in some order, and neither can wait on the other.
pub fn reserve(head: *u64, n: usize) Reservation {
    const pos = @atomicRmw(u64, head, .Add, @as(u64, n), .acq_rel);
    return .{ .pos = pos, .len = n };
}

/// Where a reservation lands in a `cap`-byte backing array: one span, or two
/// when it straddles the wrap. The second span has `len == 0` when it does not.
/// A reservation longer than `cap` keeps only its final `cap` bytes — the ring
/// cannot hold more, and the newest bytes are the ones worth keeping.
pub fn spans(cap: usize, r: Reservation) [2]Span {
    if (r.len == 0) return .{ .{ .off = 0, .len = 0 }, .{ .off = 0, .len = 0 } };
    if (r.len >= cap) return .{ .{ .off = 0, .len = cap }, .{ .off = 0, .len = 0 } };
    const off: usize = @intCast(r.pos % cap);
    const first = @min(r.len, cap - off);
    return .{
        .{ .off = off, .len = first },
        .{ .off = 0, .len = r.len - first },
    };
}

/// The bytes a reader may take from a ring whose writers have claimed `head`
/// total: the newest `min(head, cap)` of them, oldest first. `start` is the
/// storage offset of the oldest readable byte.
pub const Window = struct { start: usize, count: usize };

pub fn window(cap: usize, head: u64) Window {
    const count: usize = @intCast(@min(head, @as(u64, cap)));
    const oldest = head - @as(u64, count);
    return .{ .start = @intCast(oldest % cap), .count = count };
}

/// Whether the bytes a writer claimed at `pos` are still intact, given that
/// writers have since claimed up to `head`: a later writer wraps around and
/// reuses that storage once the stream has advanced a full `cap` past it.
///
/// This is the price of the reservation: a slow writer's span can be recycled
/// under it. It is the honest half of the trade — a reader can ASK, and a
/// caller that must not be overwritten (a crash record) has its own storage
/// rather than sharing this ring.
pub fn intact(cap: usize, head: u64, pos: u64) bool {
    return head -% pos <= @as(u64, cap);
}
