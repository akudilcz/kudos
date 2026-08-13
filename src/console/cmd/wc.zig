//! `wc [FILE...]` — line, word and byte counts, wc(1)'s columns, from files or
//! the pipe.

const std = @import("std");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

pub fn run(c: console.Console, args: []const u8) void {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    var any_file = false;
    while (it.next()) |path| {
        any_file = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        const data = vfs.read(abs) orelse {
            c.write("wc: ");
            c.write(path);
            c.write(": no such file\n");
            continue;
        };
        report(c, data, path);
    }
    if (!any_file) {
        if (c.stdin.len == 0) {
            c.write("wc: no input (pipe something in or name a file)\n");
            return;
        }
        report(c, c.stdin, null);
    }
}

fn report(c: console.Console, data: []const u8, label: ?[]const u8) void {
    var nl: usize = 0;
    var words: usize = 0;
    var in_word = false;
    for (data) |ch| {
        if (ch == '\n') nl += 1;
        const space = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
        if (!space and !in_word) words += 1;
        in_word = !space;
    }
    var buf: [96]u8 = undefined;
    c.write(std.fmt.bufPrint(&buf, "{d: >7}{d: >8}{d: >8}", .{ nl, words, data.len }) catch return);
    if (label) |l| {
        c.put(' ');
        c.write(l);
    }
    c.put('\n');
}
