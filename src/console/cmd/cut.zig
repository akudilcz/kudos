//! `cut -f LIST [-d DELIM] [-s] | -c LIST [FILE]` — the named fields or
//! characters of each line. The LIST grammar (`1`, `1,3`, `2-`, `-4`) is
//! ranges.zig, shared with anything else that takes one.

const std = @import("std");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");
const ranges = @import("../ranges.zig");

const USAGE = "usage: cut -f LIST [-d DELIM] [-s] | -c LIST | -b LIST [FILE]\n";
// -b (bytes) and -c (characters) are the same selection here: the terminal and
// the store are byte-oriented, so cut(1)'s distinction has nothing to separate.
const SPEC = "f:c:b:d:s";

pub fn run(c: console.Console, args: []const u8) void {
    var fields: ?ranges.List = null;
    var chars: ?ranges.List = null;
    var delim: u8 = '\t';
    var only_delimited = false;
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            'f', 'c', 'b' => {
                if (!ranges.valid(v.arg)) {
                    c.write("cut: invalid list: ");
                    c.write(v.arg);
                    c.put('\n');
                    return c.write(USAGE);
                }
                if (v.letter == 'f') fields = .{ .spec = v.arg } else chars = .{ .spec = v.arg };
            },
            'd' => {
                if (v.arg.len != 1) return c.write("cut: the delimiter must be one character\n");
                delim = v.arg[0];
            },
            else => return opt.refuse(c, "cut", o, USAGE),
        },
        .flag => |ch| switch (ch) {
            's' => only_delimited = true,
            else => return opt.refuse(c, "cut", o, USAGE),
        },
        else => return opt.refuse(c, "cut", o, USAGE),
    };
    if (fields == null and chars == null) return c.write(USAGE);
    if (fields != null and chars != null) return c.write("cut: -f and -c name different things; use one\n");

    var in = filter.Inputs.init(c, "cut", SPEC, args);
    while (in.next()) |src| cutText(c, src.data, fields, chars, delim, only_delimited);
}

/// Cut every line of one input.
fn cutText(c: console.Console, data: []const u8, fields: ?ranges.List, chars: ?ranges.List, delim: u8, only_delimited: bool) void {
    if (data.len == 0) return;
    var it = filter.lines(data);
    while (it.next()) |line| {
        if (chars) |list| {
            for (line, 1..) |ch, pos| {
                if (list.selects(pos)) c.put(ch);
            }
            c.put('\n');
            continue;
        }
        const list = fields.?;
        if (std.mem.indexOfScalar(u8, line, delim) == null) {
            // A line with no delimiter is one whole field: printed as it is, or
            // dropped under -s — cut(1)'s two answers.
            if (!only_delimited) filter.line(c, line);
            continue;
        }
        var parts = std.mem.splitScalar(u8, line, delim);
        var pos: usize = 0;
        var wrote = false;
        while (parts.next()) |field| {
            pos += 1;
            if (!list.selects(pos)) continue;
            if (wrote) c.put(delim);
            c.write(field);
            wrote = true;
        }
        c.put('\n');
    }
}
