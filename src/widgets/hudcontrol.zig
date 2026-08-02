//! The heads-up display's control state and counter-rate arithmetic — the
//! decisions the sampler makes, separated from the machine it samples.
//!
//! The display's own behaviour is a state machine over three bits (shown,
//! frozen, alarm latched) plus a sampling clock, and the rates it prints are a
//! difference between two readings. None of that needs a kernel; all of it is
//! the part that can be quietly wrong — an alarm that clears itself, a freeze
//! that keeps sampling, a rate that divides by the wrong interval — while the
//! display still looks entirely plausible.

const std = @import("std");

/// Sampling period. HUD-032 requires at least two refreshes a second while the
/// display is shown, and this is the figure that delivers it — the history
/// window's length is derived from it, never the other way round.
pub const SAMPLE_MS: u64 = 500;

/// The display's control state.
pub const Control = struct {
    shown: bool = false,
    frozen: bool = false,
    /// A fault seen since the last acknowledgement. LATCHED: a fault counter
    /// that ticks once between two samples must not vanish from the operator's
    /// view just because the next sample found the count unchanged.
    alarm: bool = false,
    last_sample_ms: u64 = 0,

    /// Show or hide (HUD-002). Showing samples immediately, so the display is
    /// never blank for a sampling period when it appears; it also clears any
    /// freeze, since a hidden-then-shown display that stayed frozen would
    /// present stale numbers as current ones.
    pub fn toggle(self: *Control, now_ms: u64) bool {
        self.shown = !self.shown;
        if (!self.shown) return false;
        self.frozen = false;
        self.last_sample_ms = now_ms;
        return true; // sample now
    }

    /// Stop or resume sampling (HUD-030) — only meaningful while shown.
    pub fn toggleFreeze(self: *Control) void {
        if (self.shown) self.frozen = !self.frozen;
    }

    /// Acknowledge the alarm (HUD-029). The next fault re-raises it.
    pub fn acknowledge(self: *Control) void {
        self.alarm = false;
    }

    /// Raise the alarm if this sample saw faults. Latching, not level: it stays
    /// raised until acknowledged.
    pub fn observeFaults(self: *Control, faults: u32) void {
        if (faults > 0) self.alarm = true;
    }

    /// Whether this tick should sample: shown, not frozen, and a full period
    /// since the last one. Wrap-safe (`-%`), so a clock that wraps cannot
    /// stall sampling for the age of the counter.
    pub fn due(self: *Control, now_ms: u64) bool {
        if (!self.shown or self.frozen) return false;
        if (now_ms -% self.last_sample_ms < SAMPLE_MS) return false;
        self.last_sample_ms = now_ms;
        return true;
    }
};

/// A counter's per-second rate from two readings `dt_ms` apart (HUD-020).
///
/// Zero for the first sample (nothing to difference against) and for a counter
/// that went BACKWARDS — a re-registered counter restarting at zero must read
/// as no activity, never as a vast negative wrapped into a huge positive.
pub fn ratePerSecond(prev: u64, now: u64, dt_ms: u64, have_prev: bool) f64 {
    if (!have_prev or dt_ms == 0 or now < prev) return 0;
    const dv = now - prev;
    return @as(f64, @floatFromInt(dv)) * 1000.0 / @as(f64, @floatFromInt(dt_ms));
}
