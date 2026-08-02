//! Pure CPU-utilization math, factored out of the scheduler so it can be
//! host-tested without the freestanding deps (percpu GS asm, heap, klog).

const std = @import("std");

/// Whole-percent busy fraction from a busy/idle TSC-delta pair:
/// `Δbusy / (Δbusy + Δidle)`. The TSC frequency cancels in the ratio, so the
/// inputs are raw TSC ticks (no calibration to real time). Returns 0 when no
/// time has elapsed since the previous sample (e.g. the first `ps` window).
pub fn busyPercent(dbusy: u64, didle: u64) u32 {
    const total = dbusy + didle;
    if (total == 0) return 0;
    return @intCast((dbusy * 100) / total);
}

/// Milliseconds represented by `ticks` TSC ticks at `tsc_hz` ticks per second
/// (per-task CPU time for `ps`, KRN-005). The product is widened to 128 bits so
/// `ticks × 1000` cannot overflow at any uptime. Returns 0 while the TSC
/// frequency is uncalibrated (`tsc_hz == 0`) instead of dividing by zero —
/// per-task times simply read 0 until calibration, which completes at boot long
/// before `ps` can run.
pub fn tscToMs(ticks: u64, tsc_hz: u64) u64 {
    if (tsc_hz == 0) return 0;
    return @intCast(@as(u128, ticks) * std.time.ms_per_s / tsc_hz);
}
