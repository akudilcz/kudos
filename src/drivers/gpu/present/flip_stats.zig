//! Steady-60Hz verdict over a FLIP_SAMPLE window (low-perturbation flip
//! sampling, the session update cycle).
//!
//! Pure math, no imports: present.zig hands it the recorded per-frame present
//! intervals (µs) plus the mode's refresh period, and it answers the ONE
//! question a passthrough performance run exists to answer — is the present
//! cadence locked to the panel? — as data (a Verdict), so the kernel can emit
//! a single greppable FLIPSTAT line and the pass criterion lives here, host-
//! tested, instead of in a human eyeballing 512 dump lines.
//!
//! Pass criteria (each named, so a FAIL says which one broke):
//!   locked    — mean interval within ±MEAN_TOL_PPM of the refresh period: the
//!               loop presents at panel rate, not faster (over-present: composites
//!               that never scan out) or slower (skipped refreshes).
//!   steady    — max interval ≤ refresh + JITTER_BUDGET_US: no frame ever missed
//!               its vblank by more than the budget (a p99-style bound made
//!               absolute: with n=512 a single miss is already 60Hz-visible).
//!   no_double — min interval ≥ refresh/2: no back-to-back double-present (two
//!               composites racing one scanout slot).
//! The thresholds are the field baselines from the 4090 bring-up: a locked run
//! measured iv never >17.5ms at 60Hz (refresh 16.67ms → budget ~0.9ms), and the
//! known-bad run (78 presents/s, stdev 4.2ms) fails `locked` by >20%.

/// Mean tolerance around the refresh period, in parts-per-million (±2% — wide
/// enough for panel-clock/TSC-calibration skew, far tighter than any real
/// pacing bug: the measured-bad cadence was 30% off).
pub const MEAN_TOL_PPM: u64 = 20_000;

/// How far past the refresh period a single interval may stretch before the window is
/// judged unsteady.
///
/// 2 ms is chosen to sit in a wide gap. The failure this must catch — a genuinely missed
/// vblank — is +16.7 ms at 60 Hz, eight times over budget and impossible to miss. The
/// noise it must tolerate is the ±1.5 ms tail a virtual machine sees from host CPU
/// scheduling, which no guest can control and which says nothing about the guest's own
/// pacing. Anything between those two numbers separates them cleanly.
///
/// Bare metal has no such tail, so a native run is the strict measurement regardless.
pub const JITTER_BUDGET_US: u64 = 2000;

pub const Verdict = struct {
    n: usize, // samples judged
    mean_us: u64,
    min_us: u64,
    max_us: u64,
    stdev_us: u64, // population standard deviation
    locked: bool,
    steady: bool,
    no_double: bool,

    pub fn pass(self: Verdict) bool {
        return self.locked and self.steady and self.no_double;
    }
};

/// Judge a window of present intervals (µs) against the panel refresh period
/// (µs). `intervals` must be non-empty and `refresh_us` non-zero — the caller
/// (present.zig) only invokes this once a full sample ring exists for a real
/// mode; violating that is a programming error, not a runtime condition.
pub fn judge(intervals: []const u64, refresh_us: u64) Verdict {
    var sum: u64 = 0;
    var min: u64 = intervals[0];
    var max: u64 = intervals[0];
    for (intervals) |iv| {
        sum += iv;
        if (iv < min) min = iv;
        if (iv > max) max = iv;
    }
    const n: u64 = intervals.len;
    const mean = sum / n;

    // Population variance in two passes; squared deviations in u64 are safe:
    // deviations are bounded by the max interval (u32-sourced, ≤ ~4.3e9 ns → µs
    // values ≪ 2^32), so dev*dev < 2^64.
    var var_sum: u64 = 0;
    for (intervals) |iv| {
        const dev = if (iv > mean) iv - mean else mean - iv;
        var_sum += dev * dev;
    }
    const stdev = isqrt(var_sum / n);

    const tol = refresh_us * MEAN_TOL_PPM / 1_000_000;
    const mean_dev = if (mean > refresh_us) mean - refresh_us else refresh_us - mean;

    return .{
        .n = intervals.len,
        .mean_us = mean,
        .min_us = min,
        .max_us = max,
        .stdev_us = stdev,
        .locked = mean_dev <= tol,
        .steady = !missedDeadline(max, refresh_us),
        .no_double = min >= refresh_us / 2,
    };
}

/// Whether one inter-present interval missed its deadline (DIAG-003): the
/// frame took longer than a refresh period plus the jitter budget, so a frame
/// the display should have shown was never presented.
///
/// One rule, one home: the windowed FLIPSTAT verdict's `steady` field and the
///permanent per-present drop counter both ask this question, and they must
/// never be able to answer it differently.
pub fn missedDeadline(interval_us: u64, refresh_us: u64) bool {
    return interval_us > refresh_us + JITTER_BUDGET_US;
}

/// Integer square root (Newton), for the stdev. Monotone and exact for perfect
/// squares; at most off-by-zero for our µs-scale magnitudes.
pub fn isqrt(v: u64) u64 {
    if (v == 0) return 0;
    var x: u64 = v;
    var y: u64 = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + v / x) / 2;
    }
    return x;
}
