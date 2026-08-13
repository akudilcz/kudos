//! Pure key translation: USB HID usage codes → ASCII. Host-testable
//! (`zig build test`) and the single source of truth the USB HID path
//! (xhci.zig) shares. No hardware import.

/// Control byte for the Up arrow (DLE, 0x10 — otherwise unused by the kernel):
/// flows through the normal ASCII ring so the line editor recalls history
/// without a separate routing path.
pub const KEY_UP: u8 = 0x10;
/// Control byte for the Down arrow (DC1, 0x11): same ring as KEY_UP — the line
/// editor walks history back toward the in-progress line.
pub const KEY_DOWN: u8 = 0x11;
/// Control byte for the Left arrow (DC2, 0x12): line-editor cursor left;
/// browser history back.
pub const KEY_LEFT: u8 = 0x12;
/// Control byte for the Right arrow (DC3, 0x13): line-editor cursor right;
/// browser history forward.
pub const KEY_RIGHT: u8 = 0x13;
/// Control byte for Home (DC4, 0x14): line-editor cursor to start of line.
pub const KEY_HOME: u8 = 0x14;
/// Control byte for End (NAK, 0x15): line-editor cursor to end of line.
pub const KEY_END: u8 = 0x15;
/// Control byte for Page Up (SYN, 0x16): unmodified — reserved for apps.
pub const KEY_PGUP: u8 = 0x16;
/// Control byte for Page Down (ETB, 0x17): unmodified — reserved for apps.
pub const KEY_PGDN: u8 = 0x17;
/// Control byte for Shift+Page Up (CAN, 0x18): terminal scrollback, older rows.
pub const KEY_SHIFT_PGUP: u8 = 0x18;
/// Control byte for Shift+Page Down (EM, 0x19): terminal scrollback, newer rows.
pub const KEY_SHIFT_PGDN: u8 = 0x19;
/// What Ctrl-C types (ASCII ETX, 0x03): the terminal's interrupt — cancels the
/// in-flight command, or abandons the line being edited.
pub const KEY_CTRL_C: u8 = 0x03;
/// Backspace (ASCII BS, 0x08): erases the character before the caret in every
/// line editor / text field.
pub const KEY_BACKSPACE: u8 = 0x08;

/// The Shift bits (left|right) of a HID report's modifier bitmap (byte 0 of a
/// boot keyboard report, HID Usage Table §8).
pub const MOD_SHIFT_MASK: u8 = 0x22;
/// The Control bits (left|right) of the same bitmap.
pub const MOD_CTRL_MASK: u8 = 0x11;

/// Translate a usage under the FULL modifier bitmap: shift picks the shifted
/// character (and the shifted named keys, e.g. Shift+PgUp), and Ctrl folds a
/// letter to its C0 control byte the way every terminal does (Ctrl-C → 0x03).
pub fn hidToAsciiMods(usage: u8, mods: u8) u8 {
    const ascii = hidToAscii(usage, (mods & MOD_SHIFT_MASK) != 0);
    if ((mods & MOD_CTRL_MASK) != 0 and ascii >= 0x40 and ascii < 0x80) return ascii & 0x1F;
    return ascii;
}

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
        0x52 => KEY_UP, // Up arrow → history older
        0x51 => KEY_DOWN, // Down arrow → history newer
        0x50 => KEY_LEFT, // Left arrow → cursor left / browser history back
        0x4F => KEY_RIGHT, // Right arrow → cursor right / browser history forward
        0x4A => KEY_HOME, // Home → start of line
        0x4D => KEY_END, // End → end of line
        0x4B => if (shift) KEY_SHIFT_PGUP else KEY_PGUP, // Page Up (+Shift: scrollback)
        0x4E => if (shift) KEY_SHIFT_PGDN else KEY_PGDN, // Page Down (+Shift: scrollback)
        else => 0,
    };
}

// ── HID usage → Linux evdev key code ────────────────────────────────────────

/// Linux key code for a USB HID keyboard usage, or 0 for a usage Linux does not
/// name. This is the second thing a key press means: `hidToAscii` says what
/// character it types, and this says which KEY the guest's evdev stack sees —
/// which is a different question, because a guest needs press AND release, the
/// modifiers themselves, and the keys that type nothing at all.
///
/// The table is the standard HID-to-keycode map (USB HID Usage Table §10 into
/// linux/input-event-codes.h), indexed by usage. It is not derivable: evdev
/// numbers keys in QWERTY row order while HID numbers them alphabetically.
pub fn hidToEvdev(usage: u8) u16 {
    if (usage >= MOD_USAGE_FIRST and usage <= MOD_USAGE_LAST)
        return MOD_KEYS[usage - MOD_USAGE_FIRST];
    if (usage >= KEYS.len) return 0;
    return KEYS[usage];
}

/// The first and last modifier usages (Left Control … Right GUI), which a HID
/// report carries as a bitmap rather than in its key array.
pub const MOD_USAGE_FIRST: u8 = 0xE0;
pub const MOD_USAGE_LAST: u8 = 0xE7;

/// Modifier usages in bitmap order: KEY_LEFTCTRL, LEFTSHIFT, LEFTALT, LEFTMETA,
/// RIGHTCTRL, RIGHTSHIFT, RIGHTALT, RIGHTMETA.
const MOD_KEYS = [8]u16{ 29, 42, 56, 125, 97, 54, 100, 126 };

/// Usages 0x00–0x67, the range a boot-protocol keyboard produces. Zeros are the
/// reserved and error codes, which name no key.
const KEYS = [_]u16{
    0,   0,   0,   0,   30,  48,  46,  32, // 0x00: reserved ×4, a, b, c, d
    18,  33,  34,  35,  23,  36,  37,  38, // 0x08: e … l
    50,  49,  24,  25,  16,  19,  31,  20, // 0x10: m … t
    22,  47,  17,  45,  21,  44,  2,   3, // 0x18: u … z, 1, 2
    4,   5,   6,   7,   8,   9,   10,  11, // 0x20: 3 … 0
    28,  1,   14,  15,  57,  12,  13,  26, // 0x28: enter, esc, bksp, tab, space, -, =, [
    27,  43,  43,  39,  40,  41,  51,  52, // 0x30: ], \, non-US #, ;, ', `, comma, .
    53,  58,  59,  60,  61,  62,  63,  64, // 0x38: /, capslock, F1 … F6
    65,  66,  67,  68,  87,  88,  99,  70, // 0x40: F7 … F12, printscreen, scrolllock
    119, 110, 102, 104, 111, 107, 109, 106, // 0x48: pause, insert, home, pgup, del, end, pgdn, right
    105, 108, 103, 69,  98,  55,  74,  78, // 0x50: left, down, up, numlock, KP/, KP*, KP-, KP+
    96,  79,  80,  81,  75,  76,  77,  71, // 0x58: KPenter, KP1 … KP7
    72,  73,  82,  83,  86,  127, 116, 117, // 0x60: KP8, KP9, KP0, KP., 102nd, compose, power, KP=
};
