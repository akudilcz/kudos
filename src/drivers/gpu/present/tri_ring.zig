//! Pure triple-buffer role rotation (the session update cycle).
//! `ring[i]` are the three scanout surfaces; `compose`/`pending`/`scanout` index
//! into it by ROLE. Per frame: the CE composites into ring[compose] (never
//! on-scanout, never pending → no wait, no tear), presentFlip arms it, then
//! `rotate()` advances the roles so compose→pending→scanout. Extracted from
//! present.zig's HeadState so the index bookkeeping — the invariant the whole
//! "composing the next frame is always safe" pump gate rests on — is host-testable
//! (present.zig keeps the VA/phys addressing beside it). Imports nothing → its
//! in-file tests run with `zig test` on the host.
//!
//! Scanout-handoff invariant (what presentFlip + the display engine rely on):
//! rotate() is called immediately AFTER arming ring[compose]'s flip, and the wait
//! before the NEXT frame's flip (waitFlipLatched) guarantees the previous pending
//! flip has latched by then. So at every compose step, ring[compose] is neither
//! the buffer on scanout nor the buffer whose flip is in flight — it is ALWAYS
//! safe to write, which is why present_real.flipReady can return true
//! unconditionally.

/// The three roles, each holding a distinct ring index in 0..2.
pub const TriRing = struct {
    compose: u2, // ring index the CE writes this frame
    pending: u2, // ring index whose flip is armed (latches next vblank)
    scanout: u2, // ring index currently displayed

    /// Advance the ring one step after arming this frame's flip of ring[compose]:
    /// the just-armed buffer becomes `pending`; the old `pending` (its flip has
    /// latched by the time we return to it) becomes `scanout`; the old `scanout`
    /// becomes the next frame's `compose`. Three roles, three buffers, one rotation.
    pub fn rotate(self: *TriRing) void {
        const new_scanout = self.pending;
        const new_pending = self.compose;
        const new_compose = self.scanout;
        self.scanout = new_scanout;
        self.pending = new_pending;
        self.compose = new_compose;
    }
};
