//! `tail [-n LINES | -c BYTES] [FILE...]` — the last part (default 10 lines) of
//! a file or the pipe. `-f` is refused rather than faked: nothing appends to a
//! file behind a reader's back in this system, so a follow would be a prompt
//! that never returns.

const std = @import("std");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");

const DEFAULT_LINES: usize = 10;

const USAGE = "usage: tail [-n LINES | -c BYTES] [FILE...]\n";
const SPEC = "n:c:";

pub fn run(c: console.Console, args: []const u8) void {
    var count: usize = DEFAULT_LINES;
    var bytes: ?usize = null;
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            'n' => count = std.fmt.parseInt(usize, v.arg, 10) catch return c.write(USAGE),
            'c' => bytes = std.fmt.parseInt(usize, v.arg, 10) catch return c.write(USAGE),
            else => return opt.refuse(c, "tail", o, USAGE),
        },
        .flag => |ch| switch (ch) {
            'f' => return c.write("tail: -f has nothing to follow: a file here changes only when something writes it\n"),
            else => return opt.refuse(c, "tail", o, USAGE),
        },
        else => return opt.refuse(c, "tail", o, USAGE),
    };

    var in = filter.Inputs.init(c, "tail", SPEC, args);
    const headers = in.many();
    var first = true;
    while (in.next()) |src| {
        // Several files get coreutils' `==> name <==` headers, one file none.
        if (headers) {
            if (!first) c.put('\n');
            c.write("==> ");
            c.write(src.path);
            c.write(" <==\n");
        }
        first = false;
        emit(c, src.data, count, bytes);
    }
}

/// The last `bytes` bytes, or the last `count` lines, of `data`.
fn emit(c: console.Console, data: []const u8, count: usize, bytes: ?usize) void {
    if (bytes) |n| {
        const shown = data[data.len - @min(n, data.len) ..];
        c.write(shown);
        if (shown.len > 0 and shown[shown.len - 1] != '\n') c.put('\n');
        return;
    }
    const total = filter.lineCount(data);
    const skip = total - @min(count, total);
    var it = filter.lines(data);
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) {
        if (i < skip) continue;
        filter.line(c, l);
    }
}
