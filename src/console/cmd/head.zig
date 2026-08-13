//! `head [-n N] [FILE]` — the first N lines (default 10) of a file or the pipe.

const std = @import("std");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const DEFAULT_LINES: usize = 10;

pub fn run(c: console.Console, args: []const u8) void {
    var count: usize = DEFAULT_LINES;
    var path: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, "-n")) {
            const num = it.next() orelse "";
            count = std.fmt.parseInt(usize, num, 10) catch {
                c.write("usage: head [-n N] [FILE]\n");
                return;
            };
        } else {
            path = word;
        }
    }
    var data: []const u8 = c.stdin;
    if (path.len > 0) {
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse return;
        data = vfs.read(abs) orelse {
            c.write("head: ");
            c.write(path);
            c.write(": no such file\n");
            return;
        };
    } else if (data.len == 0) {
        c.write("head: no input (pipe something in or name a file)\n");
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
