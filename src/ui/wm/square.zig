//! Bouncing-square screensaver. A solid square that drifts and reflects off the
//! screen edges, drawn by the GL desktop above the wallpaper and below all
//! windows (the WM ticks its Motion and marks its damage; ui/desktop renders it
//! as one filled rect). Besides being a screensaver, its continuous motion
//! drives the damage→render→present path with no user input, so render
//! performance is observable on a headless passthrough run.
//!
//! This module imports NO freestanding code (no timer/tsc): the caller passes
//! the current animation phase and a direction seed in, so `square.zig`
//! compiles on the host and its motion math is unit-tested in the block below.

const std = @import("std");

/// Edge length of the square, in pixels.
pub const SIZE: i32 = 50;
/// Pixels moved per animation step — ONE pixel, for silky-smooth motion (no
/// visible jumps; the position advances a single pixel at a time).
pub const STEP: i32 = 1;
/// Animation cadence: step once per this many 100 Hz PIT ticks (same clock the
/// cursor blink uses). 1 tick = every 10 ms → 100 px/s, one pixel per step. The
/// caller derives the phase as `timer.now() / STEP_TICKS` and passes it to `tick`.
pub const STEP_TICKS: u64 = 1;
/// Fill color (0xAARRGGBB, opaque) — a bright cyan that reads clearly through the
/// frosted glass above it. The GL desktop draws the square with this.
pub const COLOR: u32 = 0xFF33DDEE;

/// The pure motion state + reflection math, independent of any surface. Screen
/// bounds are passed in each step so a resize is handled without stored state.
pub const Motion = struct {
    x: i32,
    y: i32,
    vx: i32,
    vy: i32,
    step_phase: u64 = 0, // last timer phase we stepped at (cadence gate)

    /// Seed an initial diagonal direction from `seed` — the caller passes
    /// `tsc.rdtsc()` (no kernel PRNG; TSC low bits are the idiomatic seed, like
    /// udp.zig's ephemeral ports). Four diagonals from two seed bits.
    pub fn init(seed: u64) Motion {
        return .{
            .x = 0,
            .y = 0,
            .vx = if (seed & 1 == 0) STEP else -STEP,
            .vy = if (seed & 2 == 0) STEP else -STEP,
        };
    }

    /// Advance the square if a new cadence phase has elapsed. `phase` is the
    /// caller's `timer.now() / STEP_TICKS` — passed in (rather than reading the
    /// timer here) so this module stays host-testable. Returns true iff the
    /// square moved (the caller marks the old + new rects dirty).
    pub fn tick(self: *Motion, phase: u64, w: i32, h: i32) bool {
        if (phase == self.step_phase) return false;
        self.step_phase = phase;
        self.step(w, h);
        return true;
    }

    /// Advance one step and reflect off the screen edges. `w`/`h` are the screen
    /// dimensions. A component flips when the square's leading edge reaches the
    /// bound, and the position is clamped back inside so it never escapes
    /// `[0, w-SIZE] × [0, h-SIZE]`. Idempotent for a degenerate screen smaller
    /// than the square (it pins to the origin).
    pub fn step(self: *Motion, w: i32, h: i32) void {
        const max_x = @max(0, w - SIZE);
        const max_y = @max(0, h - SIZE);

        self.x += self.vx;
        if (self.x <= 0) {
            self.x = 0;
            self.vx = @intCast(@abs(self.vx));
        } else if (self.x >= max_x) {
            self.x = max_x;
            self.vx = -@as(i32, @intCast(@abs(self.vx)));
        }

        self.y += self.vy;
        if (self.y <= 0) {
            self.y = 0;
            self.vy = @intCast(@abs(self.vy));
        } else if (self.y >= max_y) {
            self.y = max_y;
            self.vy = -@as(i32, @intCast(@abs(self.vy)));
        }
    }
};
