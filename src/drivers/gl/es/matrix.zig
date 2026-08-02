//! The matrix stacks — GL's transform state.
//!
//! OpenGL has no "set the transform" call. It has a *current matrix*, selected by
//! `glMatrixMode`, and every transform command multiplies into it: `glRotatef` does not
//! rotate anything, it post-multiplies a rotation onto whichever matrix is current. The
//! stack exists so that a program can save the current transform, draw a limb relative
//! to it, and restore — which is why the standard mandates a modelview stack at least
//! 16 deep.
//!
//! ## Conventions, stated once
//!
//! **Storage is column-major**: element (row, col) lives at `m[col * 4 + row]`. This is
//! what `glLoadMatrixf` expects, so an application's array is our array, with no
//! transpose anywhere.
//!
//! **Post-multiplication**: every command computes `C = C * M`. So the LAST transform
//! issued is the FIRST applied to a vertex, which reads backwards until you see it as
//! "each command changes the coordinate system the following ones speak in".
//!
//! **This is GL's clip convention, not the hardware's.** Projections here put depth in
//! [-1, 1] with y up, exactly as `glFrustum` is defined. The silicon rasterizes depth in
//! [0, 1] with y down. That remap belongs at the lowering (es/pipeline.zig) and happens
//! once, there — not here, where an application can read the matrix back with
//! `glGetFloatv(GL_PROJECTION_MATRIX)` and is entitled to get what the standard says it
//! set.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.10.2; the glFrustum, glOrtho and
//! glRotate reference pages.

const std = @import("std");
pub const errors = @import("errors.zig");
const limits = @import("limits.zig");

pub const Mat4 = [16]f32;

pub const IDENTITY = Mat4{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

/// Which stack `glMatrixMode` has selected.
pub const Mode = enum { modelview, projection, texture };

/// `C = A * B` — apply B first, then A.
pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var c: Mat4 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var s: f32 = 0;
            for (0..4) |k| s += a[k * 4 + row] * b[col * 4 + k];
            c[col * 4 + row] = s;
        }
    }
    return c;
}

/// `M * v` for v = (x, y, z, 1).
pub fn mulPoint(m: Mat4, v: [3]f32) [4]f32 {
    var r: [4]f32 = undefined;
    for (0..4) |row|
        r[row] = m[0 * 4 + row] * v[0] + m[1 * 4 + row] * v[1] + m[2 * 4 + row] * v[2] + m[3 * 4 + row];
    return r;
}

/// One matrix stack. `depth` is its capacity; the bottom entry always exists, so a
/// stack is never empty and `top()` never has to answer for nothing.
pub fn Stack(comptime depth: usize) type {
    return struct {
        const Self = @This();

        m: [depth]Mat4 = .{IDENTITY} ** depth,
        /// Index of the top entry. 0 means only the bottom entry is live.
        sp: usize = 0,

        pub fn top(self: *const Self) Mat4 {
            return self.m[self.sp];
        }

        pub fn set(self: *Self, v: Mat4) void {
            self.m[self.sp] = v;
        }

        /// Post-multiply the current matrix: C = C * v.
        pub fn postMul(self: *Self, v: Mat4) void {
            self.m[self.sp] = mul(self.m[self.sp], v);
        }

        /// glPushMatrix: duplicate the top. The standard records STACK_OVERFLOW when
        /// the stack is full and — importantly — does NOT push, so the current matrix
        /// is unchanged and the program's next draw is merely wrong rather than
        /// undefined.
        pub fn push(self: *Self) ?errors.Error {
            if (self.sp + 1 >= depth) return .stack_overflow;
            self.m[self.sp + 1] = self.m[self.sp];
            self.sp += 1;
            return null;
        }

        /// glPopMatrix: discard the top. STACK_UNDERFLOW when only the bottom entry is
        /// left; again, nothing changes.
        pub fn pop(self: *Self) ?errors.Error {
            if (self.sp == 0) return .stack_underflow;
            self.sp -= 1;
            return null;
        }

        /// How many entries are live — what glGet's *_STACK_DEPTH reports.
        pub fn liveDepth(self: *const Self) u32 {
            return @intCast(self.sp + 1);
        }

        pub const CAPACITY: u32 = depth;
    };
}

pub const ModelviewStack = Stack(limits.MAX_MODELVIEW_STACK_DEPTH);
pub const ProjectionStack = Stack(limits.MAX_PROJECTION_STACK_DEPTH);
pub const TextureStack = Stack(limits.MAX_TEXTURE_STACK_DEPTH);

// ── the transform builders, exactly as the standard defines them ─────────────

/// glTranslate.
pub fn translation(x: f32, y: f32, z: f32) Mat4 {
    var m = IDENTITY;
    m[12] = x;
    m[13] = y;
    m[14] = z;
    return m;
}

/// glScale.
pub fn scaling(x: f32, y: f32, z: f32) Mat4 {
    var m = std.mem.zeroes(Mat4);
    m[0] = x;
    m[5] = y;
    m[10] = z;
    m[15] = 1;
    return m;
}

/// glRotate: `angle` in DEGREES — the one place GL is not in radians — about the axis
/// (x, y, z), which is normalized first. A zero-length axis leaves the matrix alone
/// rather than producing NaNs; the standard does not say, and NaNs in a modelview
/// matrix poison every vertex that follows.
pub fn rotation(angle_deg: f32, x: f32, y: f32, z: f32) Mat4 {
    const len = @sqrt(x * x + y * y + z * z);
    if (len == 0 or len != len) return IDENTITY;
    const ax = x / len;
    const ay = y / len;
    const az = z / len;

    const rad = angle_deg * (std.math.pi / 180.0);
    const c = @cos(rad);
    const s = @sin(rad);
    const t = 1 - c;

    var m: Mat4 = undefined;
    // Column 0
    m[0] = ax * ax * t + c;
    m[1] = ay * ax * t + az * s;
    m[2] = ax * az * t - ay * s;
    m[3] = 0;
    // Column 1
    m[4] = ax * ay * t - az * s;
    m[5] = ay * ay * t + c;
    m[6] = ay * az * t + ax * s;
    m[7] = 0;
    // Column 2
    m[8] = ax * az * t + ay * s;
    m[9] = ay * az * t - ax * s;
    m[10] = az * az * t + c;
    m[11] = 0;
    // Column 3
    m[12] = 0;
    m[13] = 0;
    m[14] = 0;
    m[15] = 1;
    return m;
}

/// glFrustum: a perspective projection from the near plane's window. Depth lands in
/// [-1, 1] — GL's convention, remapped at the lowering.
///
/// Null when the arguments cannot describe a frustum — a zero-width window, or a
/// non-positive near or far plane. The caller records GL_INVALID_VALUE and, as the
/// standard requires, changes nothing.
pub fn frustum(l: f32, r: f32, b: f32, t: f32, n: f32, f: f32) ?Mat4 {
    if (n <= 0 or f <= 0 or l == r or b == t or n == f) return null;
    var m = std.mem.zeroes(Mat4);
    m[0] = (2 * n) / (r - l);
    m[5] = (2 * n) / (t - b);
    m[8] = (r + l) / (r - l);
    m[9] = (t + b) / (t - b);
    m[10] = -(f + n) / (f - n);
    m[11] = -1;
    m[14] = -(2 * f * n) / (f - n);
    return m;
}

/// glOrtho: a parallel projection. Unlike frustum, near and far may be any values —
/// including negative — so long as the box has volume. Null (GL_INVALID_VALUE) when it
/// does not.
pub fn ortho(l: f32, r: f32, b: f32, t: f32, n: f32, f: f32) ?Mat4 {
    if (l == r or b == t or n == f) return null;
    var m = std.mem.zeroes(Mat4);
    m[0] = 2 / (r - l);
    m[5] = 2 / (t - b);
    m[10] = -2 / (f - n);
    m[12] = -(r + l) / (r - l);
    m[13] = -(t + b) / (t - b);
    m[14] = -(f + n) / (f - n);
    m[15] = 1;
    return m;
}
