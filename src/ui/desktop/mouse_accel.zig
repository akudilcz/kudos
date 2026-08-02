//! Pointer acceleration. Port of libinput's adaptive profile: a three-segment
//! velocity->factor curve — damped below 0.07 units/ms, flat 1:1 up to a
//! 0.4 units/ms threshold, then a linear ramp capped at 2.0x.
//!
//! Pure math over dx/dy/t_tsc — no HW import — so it is host-tested directly
//! (CLAUDE.md: pure logic is tested directly, not wrapped in an interface).
//! Callers pass the TSC frequency in (from kernel/cpu/tsc.zig hz()) rather than
//! this module reading it, keeping it hardware-free.

const std = @import("std");

// Curve constants, unchanged from libinput's defaults (units: normalized
// units/ms unless noted).
const DECEL_THRESHOLD_MS: f64 = 0.07; // below this, factor < 1 (damped)
const DECEL_MIN_FACTOR: f64 = 0.3; // factor at speed == 0
const DECEL_SLOPE: f64 = 10.0; // (1.0 - 0.3) / 0.07
const ACCEL_THRESHOLD_MS: f64 = 0.4; // at/above this, factor > 1 (ramps up)
const ACCEL_INCLINE: f64 = 1.1; // slope of the ramp
const MAX_ACCEL_FACTOR: f64 = 2.0; // cap

/// Unitless acceleration factor for a given speed (normalized units/ms).
/// A three-segment curve, with all segments continuous at their boundaries.
pub fn accelFactor(speed_units_per_ms: f64) f64 {
    var factor: f64 = undefined;
    if (speed_units_per_ms < DECEL_THRESHOLD_MS) {
        factor = DECEL_SLOPE * speed_units_per_ms + DECEL_MIN_FACTOR;
    } else if (speed_units_per_ms < ACCEL_THRESHOLD_MS) {
        factor = 1.0;
    } else {
        factor = ACCEL_INCLINE * (speed_units_per_ms - ACCEL_THRESHOLD_MS) + 1.0;
    }
    return @min(MAX_ACCEL_FACTOR, factor);
}

/// Per-pointer accelerator state: the previous sample's TSC timestamp (for
/// velocity) and a fractional carry per axis (since `factor` can be < 1 or
/// non-integer, and the cursor position is integer pixels — fractional carry).
pub const Accelerator = struct {
    have_prev: bool = false,
    prev_t_tsc: u64 = 0,
    carry_x: f64 = 0,
    carry_y: f64 = 0,

    /// Reset velocity history (e.g. after a long idle gap) without disturbing
    /// the fractional carry, which is still valid motion owed to the cursor.
    pub fn resetVelocity(self: *Accelerator) void {
        self.have_prev = false;
    }

    /// Apply the acceleration curve to one relative sample. `dx`/`dy` are the
    /// raw (already-coalesced) deltas, `t_tsc` is the sample's timestamp, and
    /// `hz_ticks_per_sec` is the TSC frequency (kernel/cpu/tsc.zig hz()).
    /// Returns the accelerated, integer-pixel delta to integrate into the
    /// cursor position; any fractional remainder is carried to the next call.
    pub fn apply(
        self: *Accelerator,
        dx: i32,
        dy: i32,
        t_tsc: u64,
        hz_ticks_per_sec: u64,
    ) struct { dx: i32, dy: i32 } {
        // First sample (or after a velocity reset): no prior timestamp to
        // derive a dt from, so pass the motion through un-accelerated (factor
        // 1) rather than guessing a speed. Still establishes prev_t_tsc for
        // the next call.
        var factor: f64 = 1.0;
        if (self.have_prev and hz_ticks_per_sec != 0) {
            const dt_ticks = t_tsc -% self.prev_t_tsc;
            const dt_ms = @as(f64, @floatFromInt(dt_ticks)) * 1000.0 /
                @as(f64, @floatFromInt(hz_ticks_per_sec));
            if (dt_ms > 0) {
                const mag = @sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy)));
                const speed = mag / dt_ms; // units/ms
                factor = accelFactor(speed);
            }
        }
        self.have_prev = true;
        self.prev_t_tsc = t_tsc;

        const fx = @as(f64, @floatFromInt(dx)) * factor + self.carry_x;
        const fy = @as(f64, @floatFromInt(dy)) * factor + self.carry_y;
        const ix = std.math.round(std.math.clamp(fx, -std.math.floatMax(f64), std.math.floatMax(f64)));
        const iy = std.math.round(fy);
        self.carry_x = fx - ix;
        self.carry_y = fy - iy;

        return .{ .dx = @intFromFloat(ix), .dy = @intFromFloat(iy) };
    }
};

// ── tests (host: `zig build test`) ────────────────────────────────────────

pub const HZ: u64 = 1_000_000_000; // 1GHz, ticks == ns, for readable test math
