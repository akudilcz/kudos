//! Bouncing-cube screensaver: the pure core (drift motion, spin phase, cube
//! mesh). A small lit cube drifts and reflects off the screen edges, drawn by
//! the GL desktop above the wallpaper and below all windows (the WM ticks its
//! Motion and marks its SIZE×SIZE damage box; ui/desktop renders the cube
//! confined to that box). Besides being a screensaver, its continuous motion
//! drives the damage→render→present path with no user input, so render
//! performance is observable on a headless passthrough run — and as a lit,
//! depth-tested draw it keeps the 3D pipeline exercised every frame too.
//!
//! This module imports NO freestanding code (no timer/tsc): the caller passes
//! the current animation phase and a direction seed in, so `square.zig`
//! compiles on the host and its motion, spin and mesh math is unit-tested in
//! test/ui/wm/square_test.zig.

const std = @import("std");

/// Edge length of the box the cube is drawn in, in pixels — also the damage
/// rect the WM marks each step.
pub const SIZE: i32 = 50;
/// Pixels moved per animation step — ONE pixel, for silky-smooth motion (no
/// visible jumps; the position advances a single pixel at a time).
pub const STEP: i32 = 1;
/// Animation cadence: step once per this many 100 Hz PIT ticks (same clock the
/// cursor blink uses). 1 tick = every 10 ms → 100 px/s, one pixel per step. The
/// caller derives the phase as `timer.now() / STEP_TICKS` and passes it to `tick`.
pub const STEP_TICKS: u64 = 1;
/// Body color (0xAARRGGBB, opaque) — a bright cyan that reads clearly through
/// the frosted glass above it.
pub const COLOR: u32 = 0xFF33DDEE;
/// COLOR as the lit material's ambient+diffuse reflectance (RGBA 0..1): the
/// cube keeps the cyan under the desktop's one lamp (material path, never a
/// per-vertex color array).
pub const MATERIAL: [4]f32 = .{
    @as(f32, @floatFromInt((COLOR >> 16) & 0xFF)) / 255.0,
    @as(f32, @floatFromInt((COLOR >> 8) & 0xFF)) / 255.0,
    @as(f32, @floatFromInt(COLOR & 0xFF)) / 255.0,
    1.0,
};

// ── the spin ────────────────────────────────────────────────────────────────

/// Spin rate, degrees per cadence step. The angle derives from the SAME phase
/// that drives the motion (no second clock): at the 100 Hz cadence this is
/// 90°/s, one revolution every 4 s.
pub const SPIN_DEG_PER_STEP: f64 = 0.9;
/// Fixed pitch applied before the spin, so the cube always presents an edge —
/// an unpitched spin would periodically collapse to a flat square silhouette.
pub const TILT_DEG: f32 = 20.0;

/// The spin angle in degrees, in [0, 360), at `phase` (the caller passes
/// Motion.step_phase). Computed and wrapped in f64 before narrowing, so the
/// per-step increment stays exact at any uptime (apps/spin.zig's wrap rule).
pub fn angleDeg(phase: u64) f32 {
    return @floatCast(@mod(@as(f64, @floatFromInt(phase)) * SPIN_DEG_PER_STEP, 360.0));
}

// ── the cube mesh ───────────────────────────────────────────────────────────

/// Triangle vertices in the mesh: 6 faces × 2 triangles × 3 corners.
pub const CUBE_VERTS = 36;

/// The cube [-1,1]³ fits inside a sphere of this radius (√3, the corner
/// half-diagonal), so an orthographic projection of this half-extent contains
/// EVERY rotation of the cube: the projected pixels can never leave the
/// SIZE×SIZE viewport that maps it.
pub const PROJ_HALF_EXTENT: f32 = @sqrt(3.0);

/// Corner `i` of face `i/6`: two counter-clockwise triangles per face,
/// outward winding, on the [-1,1]³ cube.
fn cubeVertex(i: u32) [3]f32 {
    const f = i / 6;
    const corners = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const corner = corners[i % 6];
    const u: f32 = if (corner == 1 or corner == 2) 1 else -1;
    const v: f32 = if (corner == 2 or corner == 3) 1 else -1;
    return switch (f) {
        0 => .{ u, v, 1 },
        1 => .{ -u, v, -1 },
        2 => .{ 1, v, -u },
        3 => .{ -1, v, u },
        4 => .{ u, 1, -v },
        else => .{ u, -1, v },
    };
}

/// The outward unit normal of vertex `i`'s face.
fn cubeNormal(i: u32) [3]f32 {
    return switch (i / 6) {
        0 => .{ 0, 0, 1 },
        1 => .{ 0, 0, -1 },
        2 => .{ 1, 0, 0 },
        3 => .{ -1, 0, 0 },
        4 => .{ 0, 1, 0 },
        else => .{ 0, -1, 0 },
    };
}

fn flat(comptime f: fn (u32) [3]f32) [CUBE_VERTS * 3]f32 {
    var out: [CUBE_VERTS * 3]f32 = undefined;
    for (0..CUBE_VERTS) |i| {
        const p = f(@intCast(i));
        out[i * 3 + 0] = p[0];
        out[i * 3 + 1] = p[1];
        out[i * 3 + 2] = p[2];
    }
    return out;
}

/// The mesh as flat x/y/z arrays, the layout `drawArrays` consumes directly.
pub const VERTS: [CUBE_VERTS * 3]f32 = flat(cubeVertex);
/// Per-face normals, one per vertex, matching VERTS index for index.
pub const NORMS: [CUBE_VERTS * 3]f32 = flat(cubeNormal);

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
