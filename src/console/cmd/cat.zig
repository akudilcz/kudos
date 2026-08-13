//! `cat [-n] FILE...` — print files, concatenated in argument order (which is
//! what the name means), or the pipe when no file is named. `-n` numbers the
//! lines, cat(1)'s six-wide column. Errors name the resolved absolute path.

const std = @import("std");
const vfs = @import("vfs");
const console = @import("../console.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");

const USAGE = "usage: cat [-n] FILE...\n";

pub fn run(c: console.Console, args: []const u8) void {
    var number = false;
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'n' => number = true,
            else => return opt.refuse(c, "cat", o, USAGE),
        },
        else => return opt.refuse(c, "cat", o, USAGE),
    };

    var ops = opt.Operands.init("", args);
    var any_file = false;
    var lineno: usize = 1; // -n numbers run across the files, as cat's do
    while (ops.next()) |path| {
        any_file = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        if (vfs.read(abs)) |data| {
            emit(c, data, number, &lineno);
        } else {
            c.write("cat: no such file '");
            c.write(abs);
            c.write("'\n");
        }
    }
    if (!any_file) {
        const data = c.stdin orelse {
            c.write(USAGE);
            return;
        };
        emit(c, data, number, &lineno);
    }
}

fn emit(c: console.Console, data: []const u8, number: bool, lineno: *usize) void {
    if (!number) {
        c.write(data);
        if (data.len > 0 and data[data.len - 1] != '\n') c.put('\n');
        return;
    }
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        // The split yields a final empty slice after a trailing newline;
        // numbering it would print a line the input does not have.
        if (line.len == 0 and lines.peek() == null) break;
        // Two spaces where cat(1) tabs: the terminal grid has no tab stops,
        // and an unrendered '\t' would print as an unknown glyph.
        var nb: [16]u8 = undefined;
        c.write(std.fmt.bufPrint(&nb, "{d: >6}  ", .{lineno.*}) catch "     ?  ");
        lineno.* += 1;
        c.write(line);
        c.put('\n');
    }
}
