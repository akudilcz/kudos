//! Host tests of src/drivers/gl/es/matrix.zig.

const std = @import("std");
const matrix = @import("matrix");
const IDENTITY = matrix.IDENTITY;
const ModelviewStack = matrix.ModelviewStack;
const ProjectionStack = matrix.ProjectionStack;
const errors = matrix.errors;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const frustum = matrix.frustum;
const mulPoint = matrix.mulPoint;
const ortho = matrix.ortho;
const rotation = matrix.rotation;
const scaling = matrix.scaling;
const translation = matrix.translation;

fn expectVecApprox(want: [4]f32, got: [4]f32) !void {
    for (want, got) |w, g| try std.testing.expectApproxEqAbs(w, g, 1e-5);
}
fn expectMatApprox(want: matrix.Mat4, got: matrix.Mat4) !void {
    for (want, got) |w, g| try std.testing.expectApproxEqAbs(w, g, 1e-5);
}

test "identity leaves a point where it found it" {
    try expectVecApprox(.{ 3, -4, 5, 1 }, mulPoint(IDENTITY, .{ 3, -4, 5 }));
}

test "storage is column-major: translation lives in the last COLUMN" {
    const m = translation(7, 8, 9);
    // Column-major means m[12..15) is the translation column, not a bottom row.
    try expectEqual(@as(f32, 7), m[12]);
    try expectEqual(@as(f32, 8), m[13]);
    try expectEqual(@as(f32, 9), m[14]);
    try expectVecApprox(.{ 8, 10, 12, 1 }, mulPoint(m, .{ 1, 2, 3 }));
}

test "rotation is in degrees, and 90 about Z carries X to Y" {
    const m = rotation(90, 0, 0, 1);
    try expectVecApprox(.{ 0, 1, 0, 1 }, mulPoint(m, .{ 1, 0, 0 }));
    // And Y to -X.
    try expectVecApprox(.{ -1, 0, 0, 1 }, mulPoint(m, .{ 0, 1, 0 }));
    // Z is on the axis, so it is untouched.
    try expectVecApprox(.{ 0, 0, 1, 1 }, mulPoint(m, .{ 0, 0, 1 }));
}

test "rotation normalizes its axis — length must not change the result" {
    try expectMatApprox(rotation(37, 0, 0, 1), rotation(37, 0, 0, 9));
    try expectMatApprox(rotation(37, 1, 1, 0), rotation(37, 4, 4, 0));
}

test "a zero-length axis yields identity rather than NaNs" {
    const m = rotation(90, 0, 0, 0);
    try expectMatApprox(IDENTITY, m);
    // The point of the guard: no NaN reaches a vertex.
    for (m) |v| try expect(v == v);
}

test "post-multiplication order: the last command issued is applied first" {
    // glTranslate then glScale means a vertex is scaled, THEN translated.
    var s = ModelviewStack{};
    s.postMul(translation(10, 0, 0));
    s.postMul(scaling(2, 2, 2));
    try expectVecApprox(.{ 12, 0, 0, 1 }, mulPoint(s.top(), .{ 1, 0, 0 }));

    // The other order scales the translation too.
    var s2 = ModelviewStack{};
    s2.postMul(scaling(2, 2, 2));
    s2.postMul(translation(10, 0, 0));
    try expectVecApprox(.{ 22, 0, 0, 1 }, mulPoint(s2.top(), .{ 1, 0, 0 }));
}

test "push duplicates the top; pop restores it" {
    var s = ModelviewStack{};
    s.postMul(translation(1, 0, 0));
    try expectEqual(@as(?errors.Error, null), s.push());
    s.postMul(translation(10, 0, 0)); // only the copy moves
    try expectVecApprox(.{ 11, 0, 0, 1 }, mulPoint(s.top(), .{ 0, 0, 0 }));
    try expectEqual(@as(?errors.Error, null), s.pop());
    try expectVecApprox(.{ 1, 0, 0, 1 }, mulPoint(s.top(), .{ 0, 0, 0 })); // restored
}

test "the modelview stack is at least the 16 the standard demands" {
    try expect(ModelviewStack.CAPACITY >= 16);
    var s = ModelviewStack{};
    // 15 pushes fit on top of the bottom entry.
    for (0..ModelviewStack.CAPACITY - 1) |_| try expectEqual(@as(?errors.Error, null), s.push());
    try expectEqual(@as(u32, ModelviewStack.CAPACITY), s.liveDepth());
}

test "overflow and underflow are reported, and change nothing" {
    var s = ProjectionStack{};
    s.set(translation(5, 0, 0));
    while (s.push() == null) {}
    // Full: the next push overflows and leaves the current matrix alone.
    const before = s.top();
    try expectEqual(@as(?errors.Error, .stack_overflow), s.push());
    try expectMatApprox(before, s.top());

    var u = ProjectionStack{};
    u.set(translation(5, 0, 0));
    try expectEqual(@as(?errors.Error, .stack_underflow), u.pop()); // only the bottom entry
    try expectMatApprox(translation(5, 0, 0), u.top()); // unchanged
}

test "frustum matches the standard's matrix, and puts depth in GL's [-1, 1]" {
    const m = frustum(-1, 1, -1, 1, 1, 100).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[0], 1e-5); // 2n/(r-l)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), m[5], 1e-5); // 2n/(t-b)
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), m[11], 1e-5); // the perspective term

    // A point on the near plane maps to depth -1; on the far plane, to +1. This is the
    // convention the lowering must remap to the hardware's [0, 1].
    const near = mulPoint(m, .{ 0, 0, -1 });
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), near[2] / near[3], 1e-4);
    const far = mulPoint(m, .{ 0, 0, -100 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far[2] / far[3], 1e-4);
}

test "frustum is y-UP: a point above the axis stays above it" {
    const m = frustum(-1, 1, -1, 1, 1, 100).?;
    const p = mulPoint(m, .{ 0, 0.5, -1 });
    try expect(p[1] / p[3] > 0); // GL's convention; the hardware's is the opposite
}

test "frustum refuses arguments that cannot describe a frustum" {
    try expect(frustum(-1, 1, -1, 1, 0, 100) == null); // near = 0
    try expect(frustum(-1, 1, -1, 1, -1, 100) == null); // near < 0
    try expect(frustum(-1, 1, -1, 1, 1, 0) == null); // far = 0
    try expect(frustum(1, 1, -1, 1, 1, 100) == null); // l == r
    try expect(frustum(-1, 1, 2, 2, 1, 100) == null); // b == t
    try expect(frustum(-1, 1, -1, 1, 5, 5) == null); // n == f
}

test "ortho maps its box corners to the clip cube" {
    const m = ortho(-2, 2, -3, 3, 1, 101).?;
    try expectVecApprox(.{ 1, 1, -1, 1 }, mulPoint(m, .{ 2, 3, -1 })); // near corner
    try expectVecApprox(.{ -1, -1, 1, 1 }, mulPoint(m, .{ -2, -3, -101 })); // far corner
}

test "ortho accepts a negative near plane, which frustum cannot" {
    try expect(ortho(-1, 1, -1, 1, -1, 1) != null); // legal: a box may straddle the eye
    try expect(ortho(-1, 1, -1, 1, 5, 5) == null); // no volume
    try expect(ortho(0, 0, -1, 1, 1, 2) == null);
}
