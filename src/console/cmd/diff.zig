//! `diff [-q] FILE1 FILE2` — the lines that differ, in diff(1)'s `<` / `>`
//! shape; `-q` answers only whether they differ at all. The comparison itself is
//! linediff.zig, so what "differ" means is one testable definition rather than
//! this command's opinion.

const std = @import("std");
const console = @import("../console.zig");
const linediff = @import("../linediff.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: diff [-q] FILE1 FILE2\n";
const SPEC = "q";

pub fn run(c: console.Console, args: []const u8) void {
    var quiet = false;
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'q' => quiet = true,
            else => return opt.refuse(c, "diff", o, USAGE),
        },
        else => return opt.refuse(c, "diff", o, USAGE),
    };

    var ops = opt.Operands.init(SPEC, args);
    const first = ops.next() orelse return c.write(USAGE);
    const second = ops.next() orelse return c.write(USAGE);
    const a = read(c, first) orelse return;
    const b = read(c, second) orelse return;

    if (quiet) {
        if (linediff.same(a, b)) return;
        c.write("files ");
        c.write(first);
        c.write(" and ");
        c.write(second);
        c.write(" differ\n");
        return;
    }

    var w = linediff.Walk{ .a = a, .b = b };
    var differences: usize = 0;
    while (w.next()) |step| switch (step) {
        .same => {},
        .removed => |r| {
            differences += 1;
            c.write("< ");
            c.write(r.text);
            c.put('\n');
        },
        .added => |ad| {
            differences += 1;
            c.write("> ");
            c.write(ad.text);
            c.put('\n');
        },
    };
    if (!w.resynced) {
        var buf: [88]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "(the texts stopped lining up within {d} lines — the rest is shown whole)\n", .{linediff.LOOKAHEAD}) catch "");
    }
}

/// One file's text, or null with the refusal named.
fn read(c: console.Console, path: []const u8) ?[]const u8 {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, path, &buf) orelse return null;
    return vfs.read(abs) orelse {
        c.write("diff: ");
        c.write(path);
        c.write(": no such file\n");
        return null;
    };
}
