//! `head [-n LINES | -c BYTES] [FILE]` — the first part (default 10 lines) of a
//! file or the pipe.

const std = @import("std");
const console = @import("../console.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const DEFAULT_LINES: usize = 10;

const USAGE = "usage: head [-n LINES | -c BYTES] [FILE]\n";

pub fn run(c: console.Console, args: []const u8) void {
    var count: usize = DEFAULT_LINES;
    var bytes: ?usize = null;
    var sc = opt.Scan.init("n:c:", args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            'n' => count = std.fmt.parseInt(usize, v.arg, 10) catch return c.write(USAGE),
            'c' => bytes = std.fmt.parseInt(usize, v.arg, 10) catch return c.write(USAGE),
            else => return opt.refuse(c, "head", o, USAGE),
        },
        else => return opt.refuse(c, "head", o, USAGE),
    };

    var ops = opt.Operands.init("n:c:", args);
    const path = ops.next() orelse "";
    var data: []const u8 = undefined;
    if (path.len > 0) {
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse return;
        data = vfs.read(abs) orelse {
            c.write("head: ");
            c.write(path);
            c.write(": no such file\n");
            return;
        };
    } else {
        data = c.stdin orelse {
            c.write("head: no input (pipe something in or name a file)\n");
            return;
        };
    }
    if (bytes) |n| {
        const shown = data[0..@min(n, data.len)];
        c.write(shown);
        if (shown.len > 0 and shown[shown.len - 1] != '\n') c.put('\n');
        return;
    }
    var lines = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    while (n < count) : (n += 1) {
        const line = lines.next() orelse break;
        // The split yields a final empty slice for a trailing newline; printing
        // it would add a blank line the input does not have.
        if (line.len == 0 and lines.peek() == null) break;
        c.write(line);
        c.put('\n');
    }
}
