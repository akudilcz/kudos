//! Model-viewer spin and pose: the angle a shown model has rotated to at a
//! given instant (a pure function of a microsecond timestamp), plus the
//! viewer's fixed camera pose and lamp. Pure, so the render oracle
//! (test/ui/assets/render_oracle_test.zig) frames and lights its frames from the SAME
//! facts the viewer (modelview.zig) draws with — the golden images stay honest
//! about what the desktop shows.
//!
//! Microseconds, not milliseconds: the desktop presents at 60 Hz (16.67 ms
//! frames), so a millisecond-or-coarser clock hands consecutive frames
//! unevenly sized time steps (at the PIT's 10 ms grain, a 1-vs-2-tick
//! alternation) and the rotation judders on screen even though the frame
//! cadence itself is perfect. The angle is computed and wrapped to one
//! revolution in f64 before narrowing to f32, so the per-frame step stays
//! accurate at any uptime — an unwrapped f32 angle grows past its own
//! precision within hours.

const std = @import("std");

/// Spin rate, radians per second.
pub const SPIN_RATE: f32 = 1.1;

/// The spin angle in radians, in [0, tau), after `t_us` microseconds.
pub fn angleRad(t_us: u64) f32 {
    const t_s: f64 = @as(f64, @floatFromInt(t_us)) / std.time.us_per_s;
    return @floatCast(@mod(t_s * SPIN_RATE, std.math.tau));
}

// ── the viewer's pose ────────────────────────────────────────────────────────

/// Where the camera sits: back along -Z, pitched down slightly to look at the
/// model from a little above.
pub const CAM_DIST: f32 = 4.4;
pub const CAM_PITCH_DEG: f32 = -16.0;
/// The model's own tilt, so a teapot shows its spout rather than its silhouette.
pub const MODEL_TILT_DEG: f32 = 17.0;

// ── the viewer's lamp ────────────────────────────────────────────────────────

/// One directional light (GL_POSITION with w = 0), unit length, from over the
/// viewer's right shoulder.
pub const LAMP_DIR = [4]f32{ 0.446, 0.743, 0.498, 0 };
/// The lamp's colour, used for both diffuse and specular.
pub const LAMP_COLOR = [4]f32{ 0.9, 0.9, 0.9, 1 };
/// Cool ambient, so unlit faces keep a hint of shape.
pub const LAMP_AMBIENT = [4]f32{ 0.16, 0.16, 0.20, 1 };
/// Material shininess exponent for the specular highlight.
pub const LAMP_SHININESS: f32 = 32.0;
