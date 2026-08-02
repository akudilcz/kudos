//! Host tests of src/drivers/gl/es/fixed.zig.

const std = @import("std");
const fixed = @import("fixed");
const GLfixed = fixed.GLfixed;
const GLfloat = fixed.GLfloat;
const GLint = fixed.GLint;
const ONE = fixed.ONE;
const clampToFloat = fixed.clampToFloat;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const fromFloat = fixed.fromFloat;
const fromInt = fixed.fromInt;
const toFloat = fixed.toFloat;
const toInt = fixed.toInt;

test "ONE is 1.0 and the scale is the specification's 2^16" {
    try expectEqual(@as(GLfixed, 65536), ONE);
    try expectEqual(@as(GLfloat, 1.0), toFloat(ONE));
    try expectEqual(ONE, fromFloat(1.0));
}

test "the fraction is 16 bits" {
    try expectEqual(@as(GLfloat, 0.5), toFloat(ONE >> 1));
    try expectEqual(@as(GLfloat, -0.5), toFloat(-(ONE >> 1)));
    try expectEqual(@as(GLfloat, 0.25), toFloat(ONE >> 2));
    // One step is 1/65536.
    try expectEqual(@as(GLfloat, 1.0 / 65536.0), toFloat(1));
}

test "negatives are two's complement, not sign-magnitude" {
    try expectEqual(@as(GLfloat, -1.0), toFloat(-ONE));
    try expectEqual(-ONE, fromFloat(-1.0));
    try expectEqual(@as(GLfloat, -2.5), toFloat(-(ONE * 5) >> 1));
}

test "round trips through float for every representable step of a sweep" {
    var x: GLfixed = -(1 << 20);
    while (x < (1 << 20)) : (x += 997) { // a prime stride: hits odd fractions
        try expectEqual(x, fromFloat(toFloat(x)));
    }
}

test "fromFloat rounds to nearest rather than truncating" {
    // 1.5 steps: must land on 2, not 1.
    try expectEqual(@as(GLfixed, 2), fromFloat(1.5 / 65536.0));
    try expectEqual(@as(GLfixed, 1), fromFloat(0.6 / 65536.0));
    try expectEqual(@as(GLfixed, 0), fromFloat(0.4 / 65536.0));
    try expectEqual(@as(GLfixed, -2), fromFloat(-1.5 / 65536.0));
}

test "fromFloat saturates instead of wrapping — a model must not turn inside out" {
    try expectEqual(@as(GLfixed, 0x7FFF_FFFF), fromFloat(40000.0));
    try expectEqual(@as(GLfixed, -0x8000_0000), fromFloat(-40000.0));
    try expectEqual(@as(GLfixed, 0x7FFF_FFFF), fromFloat(std.math.inf(f32)));
    try expectEqual(@as(GLfixed, -0x8000_0000), fromFloat(-std.math.inf(f32)));
}

test "a NaN becomes zero rather than undefined behaviour" {
    try expectEqual(@as(GLfixed, 0), fromFloat(std.math.nan(f32)));
}

test "clampToFloat holds [0, 1] — colors and the depth clear cannot leave it" {
    try expectEqual(@as(GLfloat, 1.0), clampToFloat(ONE * 3));
    try expectEqual(@as(GLfloat, 0.0), clampToFloat(-ONE));
    try expectEqual(@as(GLfloat, 0.5), clampToFloat(ONE >> 1));
}

test "fromInt multiplies by 2^16 and saturates at the ends" {
    try expectEqual(ONE, fromInt(1));
    try expectEqual(@as(GLfixed, -3 * ONE), fromInt(-3));
    try expectEqual(@as(GLfixed, 0x7FFF_FFFF), fromInt(32768));
    try expectEqual(@as(GLfixed, -0x8000_0000), fromInt(-32769));
    // The last value that fits exactly.
    try expectEqual(@as(GLfixed, 0x7FFF << 16), fromInt(32767));
}

test "toInt truncates toward zero, both signs" {
    try expectEqual(@as(GLint, 1), toInt(fromFloat(1.9)));
    try expectEqual(@as(GLint, -1), toInt(fromFloat(-1.9)));
    try expectEqual(@as(GLint, 0), toInt(fromFloat(0.9)));
}

test "the accuracy the specification demands: within 2^-15" {
    // §2.1.1: fixed-point computations must be accurate to within +/-2^-15.
    const tolerance: f32 = 1.0 / 32768.0;
    for ([_]f32{ 0.1, -0.1, 3.14159, -2.71828, 100.5, -0.0001 }) |f| {
        const err = @abs(toFloat(fromFloat(f)) - f);
        try expect(err <= tolerance);
    }
}
