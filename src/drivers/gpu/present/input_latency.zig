//! Input-receipt → on-screen latency (spec PERF-008).
//!
//! PERF-008 requires every mouse/keyboard input to be reflected on screen within
//! one frame of receipt. The architecture provides it — the session loop samples
//! input every pump and the next present carries the effect — but a requirement
//! that is never measured is a hope, not a property. This module is the pure core
//! of that measurement, mirroring flip_stats/flip_pacing: present.zig keeps the
//! TSC reads and the counters, the arithmetic and the pass criterion live here,
//! where `zig build test` can reach them.
//!
//! How the measurement works (no queue, no allocation — hot-path safe):
//!
//! 1. Every input event is stamped with a receipt TSC at injection time (the
//!    event rings already carry `t_tsc`).
//! 2. When the compositor's input-sampling pass consumes an event whose effect
//!    the next present will show, it calls `Latch.consumed(receipt_tsc)`. The
//!    latch keeps the OLDEST receipt of the frame being built — the event that
//!    has waited longest bounds the frame's worst latency.
//! 3. When that frame's flip is armed, the present path calls
//!    `Latch.presented(now)` and judges the delta against the one-frame budget.
//!
//! Pure math, no imports: TSC values and budgets are passed in.

/// The one-frame latency latch. Single-writer/single-reader by construction:
/// the compositor's sampling pass and the present path both run on core 0's
/// session loop, serialized, so no lock is needed (the same contract the
/// keyboard/mouse SPSC rings rely on).
pub const Latch = struct {
    /// Oldest receipt TSC among the input events consumed since the last
    /// present (0 = none pending). Oldest-wins: a burst of events sampled into
    /// one frame is judged by the one that waited longest.
    sampled_tsc: u64 = 0,

    /// The sampling pass consumed an input event carrying this receipt stamp.
    /// A zero stamp (an unstamped producer) is skipped rather than judged as an
    /// impossibly old receipt.
    pub fn consumed(self: *Latch, receipt_tsc: u64) void {
        if (receipt_tsc == 0) return;
        if (self.sampled_tsc == 0 or receipt_tsc < self.sampled_tsc)
            self.sampled_tsc = receipt_tsc;
    }

    /// A present just put the sampled input on screen: return the receipt →
    /// present delta in TSC ticks and re-arm, or null when no input was pending.
    /// A non-monotonic reading (now behind the receipt) reports 0 rather than
    /// wrapping into an astronomical latency.
    pub fn presented(self: *Latch, now_tsc: u64) ?u64 {
        if (self.sampled_tsc == 0) return null;
        const delta = if (now_tsc < self.sampled_tsc) 0 else now_tsc - self.sampled_tsc;
        self.sampled_tsc = 0;
        return delta;
    }
};

/// TSC-tick delta → microseconds. Returns 0 when `tsc_hz` is not yet
/// calibrated (below 1 MHz it cannot be a real TSC) — an uncalibrated boot
/// must not fabricate latencies.
pub fn deltaUs(delta_tsc: u64, tsc_hz: u64) u64 {
    const ticks_per_us = tsc_hz / 1_000_000;
    if (ticks_per_us == 0) return 0;
    return delta_tsc / ticks_per_us;
}

/// The PERF-008 judgement: did this input miss its one-frame window? The
/// budget is the panel's refresh period plus the shared jitter budget — the
/// same tolerance the frame-drop judgement uses (flip_stats.JITTER_BUDGET_US),
/// passed in by the caller so the refresh period keeps its one runtime home.
pub fn overBudget(delta_us: u64, budget_us: u64) bool {
    return delta_us > budget_us;
}
