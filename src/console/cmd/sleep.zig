//! `sleep N[ms|s|m|h]` — wait, then return the prompt. The durations sleep(1)
//! takes (bare seconds, `s`, `m`, `h`, and fractions), plus `ms`, since a shell
//! here is often pacing something at millisecond scale.
//!
//! The wait YIELDS (timer.sleep goes through the scheduler), so the terminal it
//! runs in is the only one that waits: every other terminal keeps running its
//! own commands (APP-031), and the desktop keeps its frame rate. Ctrl-C ends it
//! early, which is what makes a mistyped `sleep 600` recoverable.

const std = @import("std");
const console = @import("../console.zig");
const opt = @import("../opt.zig");
const sched = @import("../../kernel/sched/sched.zig");
const timer = @import("../../kernel/timer/timer.zig");

/// The longest single wait. Longer is refused rather than served: a terminal
/// that will not answer for an hour reads as a hung machine.
const MAX_MS: u64 = 10 * std.time.ms_per_min;

/// How often the wait checks for a ^C. Short enough to feel immediate, long
/// enough that the check costs nothing.
const STEP_MS: u64 = 50;

const USAGE = "usage: sleep N[ms|s|m|h]\n";

pub fn run(c: console.Console, args: []const u8) void {
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| return opt.refuse(c, "sleep", o, USAGE);
    var ops = opt.Operands.init("", args);
    const word = ops.next() orelse return c.write(USAGE);

    const ms = parseMs(word) orelse {
        c.write("sleep: not a duration: ");
        c.write(word);
        c.put('\n');
        return c.write(USAGE);
    };
    if (ms > MAX_MS) {
        var buf: [64]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "sleep: longer than the {d} s this waits\n", .{MAX_MS / std.time.ms_per_s}) catch "sleep: too long\n");
        return;
    }

    var waited: u64 = 0;
    while (waited < ms) : (waited += STEP_MS) {
        if (sched.cancelled()) return; // ^C: the worker prints it and re-prompts
        timer.sleep(@min(STEP_MS, ms - waited));
    }
}

/// sleep(1)'s durations: a bare number or `s` is seconds, `m` minutes, `h`
/// hours, plus the `ms` a shell here often wants. A decimal fraction is taken
/// to millisecond resolution, so `sleep 0.5` waits what it says.
fn parseMs(word: []const u8) ?u64 {
    const unit_ms: u64, const digits: []const u8 = if (std.mem.endsWith(u8, word, "ms"))
        .{ 1, word[0 .. word.len - 2] }
    else if (std.mem.endsWith(u8, word, "s"))
        .{ std.time.ms_per_s, word[0 .. word.len - 1] }
    else if (std.mem.endsWith(u8, word, "m"))
        .{ std.time.ms_per_min, word[0 .. word.len - 1] }
    else if (std.mem.endsWith(u8, word, "h"))
        .{ std.time.ms_per_hour, word[0 .. word.len - 1] }
    else
        .{ std.time.ms_per_s, word };
    if (digits.len == 0) return null;

    const dot = std.mem.indexOfScalar(u8, digits, '.') orelse {
        const n = std.fmt.parseInt(u64, digits, 10) catch return null;
        return n *| unit_ms;
    };
    // A fraction, to the resolution the unit can carry: 0.5s is 500 ms, and
    // 0.0001s is below a millisecond and waits none.
    const whole = std.fmt.parseInt(u64, digits[0..dot], 10) catch return null;
    const frac_text = digits[dot + 1 ..];
    if (frac_text.len == 0) return whole *| unit_ms;
    var frac: u64 = 0;
    var scale: u64 = 1;
    for (frac_text) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        frac = frac *| 10 +| (ch - '0');
        scale *|= 10;
    }
    return whole *| unit_ms +| (frac *| unit_ms) / scale;
}
