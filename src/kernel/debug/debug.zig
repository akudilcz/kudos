//! Debug interface — structured `key = value` diagnostics.
//!
//! The front-end any subsystem uses to report a bring-up fact. Each call emits
//! one `dbg: <key> = <value>` line through klog.puts, which fans out to every
//! capture channel at once: the in-memory diag ring and the registered sinks
//! (netdebug's UDP stream, the boot-log recorder) when they are running. No
//! storage of its own — the diag ring and the netdebug reader ARE the record.
//!
//! Keys are short dotted paths (`usb.dev0.vid_pid`, `usb.ports_connected`) so
//! a capture is grep-able per subsystem/device.

const std = @import("std");
const klog = @import("klog.zig");
const gate = @import("gate.zig");

/// Re-export so call sites name the module as `debug.Mod.usb` without a second
/// import (one module owns the tag set).
pub const Mod = gate.Mod;

/// Formatting caps: callers building a key or value with bufPrint size their
/// stack buffer with these (one place owns the numbers). Keys are short dotted
/// paths; values are short formatted strings.
pub const KEY_CAP = 40;
pub const VAL_CAP = 72;
/// One whole `dbg: <key> = <value>\n` line at the caps above — the assembly
/// buffer `set` uses so a record reaches the bus in a single atomic call.
pub const LINE_CAP = KEY_CAP + VAL_CAP + "dbg: ".len + " = ".len + "\n".len;

/// Emit `dbg: key = value`. ALWAYS recorded in the in-memory diag ring (the
/// flight recorder — history survives even for modules nobody enabled, and the
/// KMR1 ring-tail dump can recover it); streamed to the wire sinks only when
/// `mod`'s gate is on. Rates and hot paths belong to `counter.zig`, not here —
/// that rule is what keeps the always-record leg cheap.
///
/// The record reaches the bus in ONE klog call: klog's bus lock makes each
/// call atomic, so a whole line assembled here cannot be torn by a concurrent
/// emitter on another core or an interrupt-driven reschedule mid-record. A
/// key or value too long for the line buffer is truncated with a visible '~'
/// (never dropped, never torn).
pub fn set(mod: Mod, key: []const u8, value: []const u8) void {
    var line: [LINE_CAP]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "dbg: {s} = {s}\n", .{ key, value }) catch trunc: {
        line[line.len - 2] = '~';
        line[line.len - 1] = '\n';
        break :trunc &line;
    };
    if (gate.on(mod)) klog.puts(text) else klog.putsRecord(text);
}

/// Emit `key = <v as decimal>`.
pub fn setNum(mod: Mod, key: []const u8, v: u64) void {
    var buf: [VAL_CAP]u8 = undefined;
    set(mod, key, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?");
}

/// Emit `key = 0x<v as hex>`.
pub fn setHex(mod: Mod, key: []const u8, v: u64) void {
    var buf: [VAL_CAP]u8 = undefined;
    set(mod, key, std.fmt.bufPrint(&buf, "0x{x}", .{v}) catch "?");
}

/// Emit `key = <yes|no>`.
pub fn setBool(mod: Mod, key: []const u8, v: bool) void {
    set(mod, key, if (v) "yes" else "no");
}
