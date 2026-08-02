//! Pure key translation: USB HID usage codes → ASCII. Host-testable
//! (`zig build test`) and the single source of truth the USB HID path
//! (xhci.zig) shares. No hardware import.

/// Control byte for the Up arrow (DLE, 0x10 — otherwise unused by the kernel):
/// flows through the normal ASCII ring so the line editor recalls the last command
/// without a separate routing path.
pub const KEY_UP: u8 = 0x10;
/// Control byte for the Down arrow (DC1, 0x11): same ring as KEY_UP, wired for the
/// planned scrollback; no consumer yet (ignored, < 0x20).
pub const KEY_DOWN: u8 = 0x11;
/// Control byte for the Left arrow (DC2, 0x12): browser history back.
pub const KEY_LEFT: u8 = 0x12;
/// Control byte for the Right arrow (DC3, 0x13): browser history forward.
pub const KEY_RIGHT: u8 = 0x13;
/// Backspace (ASCII BS, 0x08): erases the character before the caret in every
/// line editor / text field.
pub const KEY_BACKSPACE: u8 = 0x08;

/// Translate a USB HID keyboard usage code (HID Usage Table §10) to ASCII, given
/// whether shift is held. Single source of truth for "what character does this key
/// produce" Returns 0 for a usage with no character
/// (e.g. F-keys, which the caller handles as named keys). The single source of
/// truth for "what character does this key produce".
pub fn hidToAscii(usage: u8, shift: bool) u8 {
    if (usage >= 0x04 and usage <= 0x1D) { // a..z
        const base: u8 = 'a' + (usage - 0x04);
        return if (shift) base - 32 else base;
    }
    if (usage >= 0x1E and usage <= 0x26) { // 1..9
        if (shift) return "!@#$%^&*("[usage - 0x1E];
        return '1' + (usage - 0x1E);
    }
    return switch (usage) {
        0x27 => if (shift) ')' else '0',
        0x28 => '\r',
        0x2A => KEY_BACKSPACE,
        0x2B => '\t',
        0x2C => ' ',
        0x2D => if (shift) '_' else '-',
        0x2E => if (shift) '+' else '=',
        0x2F => if (shift) '{' else '[',
        0x30 => if (shift) '}' else ']',
        0x31 => if (shift) '|' else '\\',
        0x33 => if (shift) ':' else ';',
        0x34 => if (shift) '"' else '\'',
        0x35 => if (shift) '~' else '`',
        0x36 => if (shift) '<' else ',',
        0x37 => if (shift) '>' else '.',
        0x38 => if (shift) '?' else '/',
        0x52 => KEY_UP, // Up arrow → recall last command
        0x51 => KEY_DOWN, // Down arrow → scrollback (planned)
        0x50 => KEY_LEFT, // Left arrow → browser history back
        0x4F => KEY_RIGHT, // Right arrow → browser history forward
        else => 0,
    };
}

// ── tests (host: `zig build test`) ───────────────────────────────────────────
const std = @import("std");
