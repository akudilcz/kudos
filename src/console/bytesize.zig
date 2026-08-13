//! Human-readable byte sizes — the `-h` every Linux tool spells the same way.
//! PURE: one function, one buffer, no allocation. `ls -h` and `free -h` share
//! it so 456024 bytes reads "445K" in both.

const std = @import("std");

/// The longest text `human` produces ("1023.9G" fits with room).
pub const MAX_TEXT: usize = 8;

/// `bytes` in the binary-unit shape coreutils' -h prints: bare bytes below 1K,
/// then one decimal under 10 units ("1.4K", "9.9M"), whole units above ("445K",
/// "16G"). Powers of 1024, as ls/free/du mean by default.
pub fn human(bytes: usize, buf: *[MAX_TEXT]u8) []const u8 {
    const UNITS = "KMGT";
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d}", .{bytes}) catch unreachable;
    var v: usize = bytes;
    var u: usize = 0;
    while (v >= 1024 * 1024 and u + 1 < UNITS.len) : (u += 1) v /= 1024;
    // v is now in [1024, 1024*1024): one division from its final unit, kept
    // wide so the tenths below still see the remainder.
    const whole = v / 1024;
    if (whole < 10) {
        const tenths = (v % 1024) * 10 / 1024;
        return std.fmt.bufPrint(buf, "{d}.{d}{c}", .{ whole, tenths, UNITS[u] }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}{c}", .{ whole, UNITS[u] }) catch unreachable;
}
