//! `grep PATTERN [FILE...]` — print lines containing PATTERN, from the named
//! files or from what a pipe fed in. Fixed-string matching (grep -F): this
//! shell has no regex engine, and a substring that quietly behaved as one would
//! surprise in both directions.

const std = @import("std");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

pub fn run(c: console.Console, args: []const u8) void {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    const pat = it.next() orelse {
        c.write("usage: grep PATTERN [FILE...]\n");
        return;
    };
    var any_file = false;
    // More than one file prints `name:` prefixes, as grep does.
    var nfiles: usize = 0;
    var counting = it;
    while (counting.next()) |_| nfiles += 1;
    while (it.next()) |path| {
        any_file = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        const data = vfs.read(abs) orelse {
            c.write("grep: ");
            c.write(path);
            c.write(": no such file\n");
            continue;
        };
        filter(c, pat, data, if (nfiles > 1) path else null);
    }
    if (!any_file) {
        const data = c.stdin orelse {
            c.write("grep: no input (pipe something in or name a file)\n");
            return;
        };
        filter(c, pat, data, null);
    }
}

fn filter(c: console.Console, pat: []const u8, data: []const u8, label: ?[]const u8) void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, pat) == null) continue;
        if (label) |l| {
            c.write(l);
            c.put(':');
        }
        c.write(line);
        c.put('\n');
    }
}
