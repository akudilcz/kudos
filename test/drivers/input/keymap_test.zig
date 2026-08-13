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

test "hidToAscii: the navigation keys, and shift picks the scrollback pair" {
    try expectEqual(keymap.KEY_HOME, hidToAscii(0x4A, false));
    try expectEqual(keymap.KEY_END, hidToAscii(0x4D, false));
    try expectEqual(keymap.KEY_PGUP, hidToAscii(0x4B, false));
    try expectEqual(keymap.KEY_PGDN, hidToAscii(0x4E, false));
    try expectEqual(keymap.KEY_SHIFT_PGUP, hidToAscii(0x4B, true));
    try expectEqual(keymap.KEY_SHIFT_PGDN, hidToAscii(0x4E, true));
}

test "hidToAsciiMods: Ctrl folds a letter to its control byte, shift still shifts" {
    // Ctrl-C (usage 0x06) is the terminal's interrupt.
    try expectEqual(keymap.KEY_CTRL_C, keymap.hidToAsciiMods(0x06, keymap.MOD_CTRL_MASK));
    try expectEqual(@as(u8, 'c'), keymap.hidToAsciiMods(0x06, 0));
    try expectEqual(@as(u8, 'C'), keymap.hidToAsciiMods(0x06, keymap.MOD_SHIFT_MASK));
    // Ctrl leaves the keys that are already control bytes alone (Enter stays Enter).
    try expectEqual(@as(u8, '\r'), keymap.hidToAsciiMods(0x28, keymap.MOD_CTRL_MASK));
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

// ── HID usage → evdev key code ─────────────────────────────────────────────
//
// The table in keymap.zig is transcribed from two external standards, so these
// spell the expected codes independently (linux/input-event-codes.h) rather
// than reading them back out of the table they are checking.

const hidToEvdev = keymap.hidToEvdev;

test "hidToEvdev: letters land on their QWERTY-order key codes" {
    // evdev numbers keys by keyboard row, HID numbers them alphabetically —
    // the whole reason this cannot be arithmetic on the usage.
    try expectEqual(@as(u16, 30), hidToEvdev(0x04)); // KEY_A
    try expectEqual(@as(u16, 48), hidToEvdev(0x05)); // KEY_B
    try expectEqual(@as(u16, 16), hidToEvdev(0x14)); // KEY_Q
    try expectEqual(@as(u16, 44), hidToEvdev(0x1D)); // KEY_Z
}

test "hidToEvdev: digits, and the keys a shell needs" {
    try expectEqual(@as(u16, 2), hidToEvdev(0x1E)); // KEY_1
    try expectEqual(@as(u16, 11), hidToEvdev(0x27)); // KEY_0
    try expectEqual(@as(u16, 28), hidToEvdev(0x28)); // KEY_ENTER
    try expectEqual(@as(u16, 1), hidToEvdev(0x29)); // KEY_ESC
    try expectEqual(@as(u16, 14), hidToEvdev(0x2A)); // KEY_BACKSPACE
    try expectEqual(@as(u16, 15), hidToEvdev(0x2B)); // KEY_TAB
    try expectEqual(@as(u16, 57), hidToEvdev(0x2C)); // KEY_SPACE
}

test "hidToEvdev: the keys that type nothing at all" {
    // A browser needs these and hidToAscii cannot express them: it answers 0 for
    // every one, which is precisely why the evdev map exists.
    try expectEqual(@as(u16, 103), hidToEvdev(0x52)); // KEY_UP
    try expectEqual(@as(u16, 108), hidToEvdev(0x51)); // KEY_DOWN
    try expectEqual(@as(u16, 105), hidToEvdev(0x50)); // KEY_LEFT
    try expectEqual(@as(u16, 106), hidToEvdev(0x4F)); // KEY_RIGHT
    try expectEqual(@as(u16, 59), hidToEvdev(0x3A)); // KEY_F1
    try expectEqual(@as(u16, 88), hidToEvdev(0x45)); // KEY_F12
    try expectEqual(@as(u16, 102), hidToEvdev(0x4A)); // KEY_HOME
    try expectEqual(@as(u16, 111), hidToEvdev(0x4C)); // KEY_DELETE
}

test "hidToEvdev: modifiers, which a report carries as a bitmap not a usage" {
    try expectEqual(@as(u16, 29), hidToEvdev(0xE0)); // KEY_LEFTCTRL
    try expectEqual(@as(u16, 42), hidToEvdev(0xE1)); // KEY_LEFTSHIFT
    try expectEqual(@as(u16, 56), hidToEvdev(0xE2)); // KEY_LEFTALT
    try expectEqual(@as(u16, 125), hidToEvdev(0xE3)); // KEY_LEFTMETA
    try expectEqual(@as(u16, 54), hidToEvdev(0xE5)); // KEY_RIGHTSHIFT
    try expectEqual(@as(u16, 126), hidToEvdev(0xE7)); // KEY_RIGHTMETA
}

test "hidToEvdev: a usage that names no key answers 0, at both ends" {
    try expectEqual(@as(u16, 0), hidToEvdev(0x00)); // reserved
    try expectEqual(@as(u16, 0), hidToEvdev(0x01)); // ErrorRollOver
    try expectEqual(@as(u16, 0), hidToEvdev(0xFF)); // past everything named
    try expectEqual(@as(u16, 0), hidToEvdev(0xDF)); // just below the modifiers
}

test "no two named usages share one key code" {
    // A collision would make two physical keys indistinguishable to the guest.
    // The one legitimate duplicate is KEY_BACKSLASH, which HID reaches by two
    // usages (0x31 and the non-US 0x32) exactly as Linux's own table does.
    var seen = [_]u8{0} ** 256;
    var usage: u16 = 0;
    while (usage <= 0xFF) : (usage += 1) {
        const code = hidToEvdev(@intCast(usage));
        if (code == 0 or code >= seen.len) continue;
        seen[code] += 1;
    }
    for (seen, 0..) |n, code| {
        const allowed: u8 = if (code == 43) 2 else 1; // KEY_BACKSLASH
        if (n > allowed) {
            std.debug.print("key code {d} claimed by {d} usages\n", .{ code, n });
            return error.DuplicateKeyCode;
        }
    }
}
