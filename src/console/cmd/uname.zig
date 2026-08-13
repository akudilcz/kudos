//! `uname [-asnrvm]` — what this machine is running, in uname(1)'s fields:
//! `-s` the system name, `-n` the hostname, `-r` the release (the build
//! number), `-v` the version (commit and build time), `-m` the machine.
//! Bare prints the system name; `-a` prints them all, and that one line is the
//! shape this shell has always printed.

const std = @import("std");
const buildinfo = @import("buildinfo");
const console = @import("../console.zig");
const opt = @import("../opt.zig");

const USAGE = "usage: uname [-asnrvm]\n";

pub fn run(c: console.Console, args: []const u8) void {
    var s = false;
    var n = false;
    var r = false;
    var v = false;
    var m = false;
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'a' => {
                s = true;
                n = true;
                r = true;
                v = true;
                m = true;
            },
            's' => s = true,
            'n' => n = true,
            'r' => r = true,
            'v' => v = true,
            'm' => m = true,
            else => return opt.refuse(c, "uname", o, USAGE),
        },
        else => return opt.refuse(c, "uname", o, USAGE),
    };
    var ops = opt.Operands.init("", args);
    if (ops.next() != null) return c.write(USAGE);
    if (!s and !n and !r and !v and !m) s = true;

    var buf: [128]u8 = undefined;
    var first = true;
    if (s) field(c, &first, "kudos");
    if (n) field(c, &first, "kudos");
    if (r) field(c, &first, std.fmt.bufPrint(&buf, "#{d}", .{buildinfo.build_number}) catch "#?");
    if (v) {
        var vb: [96]u8 = undefined;
        field(c, &first, std.fmt.bufPrint(&vb, "{s} {s}", .{ buildinfo.git_hash, buildinfo.build_time }) catch "?");
    }
    if (m) field(c, &first, "x86_64");
    c.put('\n');
}

fn field(c: console.Console, first: *bool, text: []const u8) void {
    if (!first.*) c.put(' ');
    first.* = false;
    c.write(text);
}
