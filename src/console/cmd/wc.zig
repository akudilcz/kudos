//! `wc [-lwc] [FILE...]` — line, word and byte counts, wc(1)'s columns, from
//! files or the pipe. Flags select columns (in wc's fixed l,w,c order); none
//! selects all three.

const std = @import("std");
const console = @import("../console.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: wc [-lwc] [FILE...]\n";

const Cols = struct {
    lines: bool = false,
    words: bool = false,
    bytes: bool = false,

    fn all() Cols {
        return .{ .lines = true, .words = true, .bytes = true };
    }
    fn none(self: Cols) bool {
        return !self.lines and !self.words and !self.bytes;
    }
};

pub fn run(c: console.Console, args: []const u8) void {
    var cols = Cols{};
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'l' => cols.lines = true,
            'w' => cols.words = true,
            'c' => cols.bytes = true,
            else => return opt.refuse(c, "wc", o, USAGE),
        },
        else => return opt.refuse(c, "wc", o, USAGE),
    };
    if (cols.none()) cols = Cols.all();

    var ops = opt.Operands.init("", args);
    var any_file = false;
    while (ops.next()) |path| {
        any_file = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        const data = vfs.read(abs) orelse {
            c.write("wc: ");
            c.write(path);
            c.write(": no such file\n");
            continue;
        };
        report(c, cols, data, path);
    }
    if (!any_file) {
        const data = c.stdin orelse {
            c.write("wc: no input (pipe something in or name a file)\n");
            return;
        };
        report(c, cols, data, null);
    }
}

fn report(c: console.Console, cols: Cols, data: []const u8, label: ?[]const u8) void {
    var nl: usize = 0;
    var words: usize = 0;
    var in_word = false;
    for (data) |ch| {
        if (ch == '\n') nl += 1;
        const space = ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
        if (!space and !in_word) words += 1;
        in_word = !space;
    }
    var buf: [32]u8 = undefined;
    if (cols.lines) c.write(std.fmt.bufPrint(&buf, "{d: >7}", .{nl}) catch return);
    if (cols.words) c.write(std.fmt.bufPrint(&buf, "{d: >8}", .{words}) catch return);
    if (cols.bytes) c.write(std.fmt.bufPrint(&buf, "{d: >8}", .{data.len}) catch return);
    if (label) |l| {
        c.put(' ');
        c.write(l);
    }
    c.put('\n');
}
