//! 16.16 fixed-point — the other half of the Common profile's number system.
//!
//! OpenGL ES exists in two profiles. Common-Lite has no floating-point API at all: a
//! program written against it says `glRotatex`, not `glRotatef`, and passes a
//! `GLfixed`. The Common profile has both, so that a Common-Lite program runs on it
//! unchanged. That is why 40 of the 145 entry points are `x`/`xv` twins of an `f`/`fv`
//! command, and why they are not optional for us.
//!
//! A `GLfixed` is a 32-bit two's-complement integer holding a number scaled by 65536:
//! the top 16 bits are the integer part, the bottom 16 the fraction. So 65536 is 1.0,
//! -32768 is -0.5, and the representable range is about [-32768, +32768) in steps of
//! 1/65536 (~0.0000153).
//!
//! We compute in floating-point, which the specification explicitly allows a Common
//! profile implementation to do (§2.1.1: an implementation "will normally perform
//! computations in floating-point"). So the fixed-point entry points are not a second
//! implementation of anything — each converts its arguments here and calls the float
//! path. This module is the ONLY place that knows the scale factor; a `<< 16` anywhere
//! else is a bug.
//!
//! ## Why the conversions are not one-liners
//!
//! Converting a float to an integer whose range it may exceed is undefined behaviour
//! in Zig, and "undefined" on a kernel means a value nobody can predict gets written
//! into a matrix and the window goes black somewhere else entirely. Every conversion
//! below clamps to the representable range BEFORE it casts, and maps a NaN — which
//! compares false against everything, so a naive clamp lets it straight through — to
//! zero. The specification does not say what to do with a NaN because it does not
//! admit one exists; refusing to produce garbage is the only defensible reading.

const enums = @import("enums.zig");

pub const GLfixed = enums.GLfixed;
pub const GLclampx = enums.GLclampx;
pub const GLfloat = enums.GLfloat;
pub const GLint = enums.GLint;

/// The scale factor: 2^16. One whole unit of a 16.16 number.
pub const ONE: GLfixed = 1 << 16;

const SHIFT: u5 = 16;
const SCALE: f64 = @floatFromInt(@as(i32, ONE));

/// 16.16 -> float. Always exact: every GLfixed has an f32 that is equal to it, since
/// 32 significant bits of a value scaled by a power of two round-trip through f32's
/// 24-bit significand only when the value is small enough — and where it is not, the
/// result is the correctly-rounded nearest float, which is what the specification's
/// ±2^-15 accuracy requirement asks for.
pub fn toFloat(x: GLfixed) GLfloat {
    return @floatCast(@as(f64, @floatFromInt(x)) / SCALE);
}

/// float -> 16.16, rounded to nearest and saturating at the ends of the range.
///
/// Saturation rather than wrapping: a coordinate that overflows is already wrong, and
/// a wrapped one is wrong in the least debuggable way available — a vertex at +40000
/// would land at -25536 and the model would turn inside out.
pub fn fromFloat(f: GLfloat) GLfixed {
    if (f != f) return 0; // NaN: nothing to represent
    const scaled = @round(@as(f64, f) * SCALE);
    if (scaled >= @as(f64, @floatFromInt(maxInt()))) return maxInt();
    if (scaled <= @as(f64, @floatFromInt(minInt()))) return minInt();
    return @intFromFloat(scaled);
}

/// A GLclampx is a GLfixed the specification also clamps to [0, 1] — colors, the alpha
/// reference, the depth clear value. Clamping is the caller's contract, not a
/// conversion detail, so it is spelled here rather than left to each entry point.
pub fn clampToFloat(x: GLclampx) GLfloat {
    const f = toFloat(x);
    return if (f < 0.0) 0.0 else if (f > 1.0) 1.0 else f;
}

/// int -> 16.16. The specification is explicit (§2.3): "integer types are converted to
/// fixed-point by multiplying by 2^16". Saturates rather than overflowing.
pub fn fromInt(i: GLint) GLfixed {
    if (i >= (maxInt() >> SHIFT) + 1) return maxInt();
    if (i <= (minInt() >> SHIFT)) return minInt();
    return i << SHIFT;
}

/// 16.16 -> int, truncating toward zero.
pub fn toInt(x: GLfixed) GLint {
    return @divTrunc(x, ONE);
}

inline fn maxInt() GLfixed {
    return 0x7FFF_FFFF;
}
inline fn minInt() GLfixed {
    return -0x8000_0000;
}

// ── tests ────────────────────────────────────────────────────────────────────
