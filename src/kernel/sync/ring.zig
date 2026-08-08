//! Lock-free single-producer / single-consumer ring.
//!
//! The per-core mailbox between an AP terminal and core 0: one producer, one
//! consumer, no lock. The producer writes the slot THEN publishes `head` with a
//! release store; the consumer loads `head` with acquire, reads the slot, then
//! publishes `tail` with release. On x86 these are plain loads/stores, but the
//! atomic ordering still pins the data write before the index publish so a
//! ReleaseFast reorder can't expose a half-written slot.
//!
//! kudos uses N of these (one per core) with core 0 the single consumer, rather
//! than one shared MPSC ring — simpler and faster.

/// SPSC ring of `cap` elements of `T`. `cap` must be a power of two.
pub fn Ring(comptime T: type, comptime cap: usize) type {
    comptime {
        if (cap == 0 or (cap & (cap - 1)) != 0) @compileError("Ring cap must be a power of two");
    }
    return struct {
        const Self = @This();
        const MASK: usize = cap - 1;

        buf: [cap]T = undefined,
        head: usize = 0, // next slot to write (producer owns)
        tail: usize = 0, // next slot to read  (consumer owns)

        /// Producer: push one element. Returns false if the ring is full (the
        /// caller decides whether to drop or retry — no silent overwrite).
        pub fn push(self: *Self, val: T) bool {
            const head = @atomicLoad(usize, &self.head, .monotonic);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            if (head -% tail >= cap) return false; // full
            self.buf[head & MASK] = val;
            // Publish the write: release ensures the slot store is visible before
            // the consumer can observe the advanced head.
            @atomicStore(usize, &self.head, head +% 1, .release);
            return true;
        }

        /// Consumer: pop one element, or null if empty.
        pub fn pop(self: *Self) ?T {
            const tail = @atomicLoad(usize, &self.tail, .monotonic);
            const head = @atomicLoad(usize, &self.head, .acquire);
            if (head == tail) return null; // empty
            const val = self.buf[tail & MASK];
            @atomicStore(usize, &self.tail, tail +% 1, .release);
            return val;
        }

        /// Consumer: a pointer to the front element without consuming it, or
        /// null if empty. For a consumer that can only commit to an element
        /// after its destination has accepted it — `pop` would destroy the one
        /// it could not place. The pointer stays valid until the consumer's own
        /// `drop`: the producer writes at `head` and refuses to write a full
        /// ring, so it can never touch the front slot while it is unconsumed.
        pub fn peek(self: *Self) ?*const T {
            const tail = @atomicLoad(usize, &self.tail, .monotonic);
            const head = @atomicLoad(usize, &self.head, .acquire);
            if (head == tail) return null; // empty
            return &self.buf[tail & MASK];
        }

        /// Consumer: discard the front element, retiring what `peek` returned.
        /// A no-op on an empty ring, so a `drop` without a live `peek` cannot
        /// hand the producer a slot the consumer never read.
        pub fn drop(self: *Self) void {
            const tail = @atomicLoad(usize, &self.tail, .monotonic);
            if (@atomicLoad(usize, &self.head, .acquire) == tail) return; // empty
            @atomicStore(usize, &self.tail, tail +% 1, .release);
        }

        /// Consumer: whether at least one element is available.
        pub fn isEmpty(self: *Self) bool {
            return @atomicLoad(usize, &self.head, .acquire) ==
                @atomicLoad(usize, &self.tail, .monotonic);
        }

        /// Producer: a mutable pointer to the newest queued element (head-1), or
        /// null if the ring is empty. Lets the producer coalesce an incoming
        /// value into the last one it pushed (e.g. sum relative mouse deltas)
        /// instead of enqueuing a fresh slot. ONLY sound when the producer and
        /// consumer are serialized on one thread — a concurrent `pop` could
        /// advance `tail` past head-1 while the producer holds the pointer. The
        /// `head == tail` guard ensures head-1 is a live, not-yet-consumed slot.
        pub fn lastMut(self: *Self) ?*T {
            const head = @atomicLoad(usize, &self.head, .monotonic);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            if (head == tail) return null; // empty — nothing to merge into
            return &self.buf[(head -% 1) & MASK];
        }
    };
}

// ── tests (host: `zig build test`) ───────────────────────────────────────────
const std = @import("std");
