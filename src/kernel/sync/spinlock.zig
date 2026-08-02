//! IRQ-safe test-and-test-and-set spinlock.
//!
//! x86 gives acquire on a plain load and release on a plain store (x86-TSO), so
//! the lock body is a TTAS: spin reading with PAUSE until it looks free, then a
//! single `lock`-prefixed exchange (Zig `@atomicRmw`) to take it. A lock that is
//! also taken from an IRQ handler must disable interrupts while held, or the same
//! core can self-deadlock — `acquireIrqSave`/`releaseIrqRestore` do that.

const cpu = @import("../cpu/cpu.zig");

pub const SpinLock = struct {
    /// 0 = free, 1 = held.
    state: u32 = 0,

    /// Acquire (thread context only — does not touch interrupts). TTAS with a
    /// PAUSE spin so the waiting core does not hammer the cache line or trip a
    /// memory-order machine-clear.
    pub fn acquire(self: *SpinLock) void {
        while (true) {
            // Fast path: try to flip 0 -> 1 with an acquire-ordered swap.
            if (@atomicRmw(u32, &self.state, .Xchg, 1, .acquire) == 0) return;
            // Slow path: spin on a plain load until it looks free, then retry.
            while (@atomicLoad(u32, &self.state, .monotonic) != 0) {
                asm volatile ("pause");
            }
        }
    }

    /// Release: a plain store has release semantics on x86.
    pub fn release(self: *SpinLock) void {
        @atomicStore(u32, &self.state, 0, .release);
    }

    /// Acquire with interrupts disabled, returning the previous IF so the caller
    /// can restore it. Use for any lock also taken in IRQ context (e.g. a ring
    /// drained by the timer ISR) to avoid self-deadlock.
    pub fn acquireIrqSave(self: *SpinLock) bool {
        const if_was = cpu.irqSave();
        self.acquire();
        return if_was;
    }

    /// Release and restore the interrupt flag captured by acquireIrqSave.
    pub fn releaseIrqRestore(self: *SpinLock, if_was: bool) void {
        self.release();
        cpu.irqRestore(if_was);
    }
};
