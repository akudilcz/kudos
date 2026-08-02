//! Host tests of src/drivers/input/keymap.zig.

const std = @import("std");
const keymap = @import("keymap");
const KEY_DOWN = keymap.KEY_DOWN;
const KEY_UP = keymap.KEY_UP;
const expectEqual = std.testing.expectEqual;
const hidToAscii = keymap.hidToAscii;

test "hidToAscii: letters honor shift" {
    try expectEqual(@as(u8, 'a'), hidToAscii(0x04, false));
    try expectEqual(@as(u8, 'A'), hidToAscii(0x04, true));
    try expectEqual(@as(u8, 'z'), hidToAscii(0x1D, false));
    try expectEqual(@as(u8, 'Z'), hidToAscii(0x1D, true));
}

test "hidToAscii: digits + their shifted symbols" {
    try expectEqual(@as(u8, '1'), hidToAscii(0x1E, false));
    try expectEqual(@as(u8, '!'), hidToAscii(0x1E, true));
    try expectEqual(@as(u8, '9'), hidToAscii(0x26, false));
    try expectEqual(@as(u8, '('), hidToAscii(0x26, true));
    try expectEqual(@as(u8, '0'), hidToAscii(0x27, false));
    try expectEqual(@as(u8, ')'), hidToAscii(0x27, true));
}

test "hidToAscii: whitespace, punctuation, arrows, no-char" {
    try expectEqual(@as(u8, '\r'), hidToAscii(0x28, false));
    try expectEqual(@as(u8, 8), hidToAscii(0x2A, false)); // backspace
    try expectEqual(@as(u8, '\t'), hidToAscii(0x2B, false));
    try expectEqual(@as(u8, ' '), hidToAscii(0x2C, false));
    try expectEqual(@as(u8, '-'), hidToAscii(0x2D, false));
    try expectEqual(@as(u8, '_'), hidToAscii(0x2D, true));
    try expectEqual(@as(u8, '/'), hidToAscii(0x38, false));
    try expectEqual(@as(u8, '?'), hidToAscii(0x38, true));
    try expectEqual(KEY_UP, hidToAscii(0x52, false));
    try expectEqual(KEY_DOWN, hidToAscii(0x51, false));
    try expectEqual(@as(u8, 0), hidToAscii(0x3A, false)); // F1 → no char
    try expectEqual(@as(u8, 0), hidToAscii(0x00, false));
}

test "hidToAscii: every punctuation usage in both shift states" {
    // 0x2D..0x38: the full shifted/unshifted symbol pairs.
    const pairs = [_]struct { u: u8, lo: u8, hi: u8 }{
        .{ .u = 0x2D, .lo = '-', .hi = '_' },
        .{ .u = 0x2E, .lo = '=', .hi = '+' },
        .{ .u = 0x2F, .lo = '[', .hi = '{' },
        .{ .u = 0x30, .lo = ']', .hi = '}' },
        .{ .u = 0x31, .lo = '\\', .hi = '|' },
        .{ .u = 0x33, .lo = ';', .hi = ':' },
        .{ .u = 0x34, .lo = '\'', .hi = '"' },
        .{ .u = 0x35, .lo = '`', .hi = '~' },
        .{ .u = 0x36, .lo = ',', .hi = '<' },
        .{ .u = 0x37, .lo = '.', .hi = '>' },
        .{ .u = 0x38, .lo = '/', .hi = '?' },
    };
    for (pairs) |p| {
        try expectEqual(p.lo, hidToAscii(p.u, false));
        try expectEqual(p.hi, hidToAscii(p.u, true));
    }
}
