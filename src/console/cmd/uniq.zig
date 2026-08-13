//! `uniq [-cdui] [FILE]` — collapse ADJACENT repeated lines, the way uniq(1)
//! does: it compares each line with the one before it, so a file that is not
//! sorted keeps repeats that are not neighbours. `sort | uniq` is the pairing
//! that answers "which lines are distinct".

const std = @import("std");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");

const USAGE = "usage: uniq [-cdui] [FILE]\n";
const SPEC = "cdui";

pub fn run(c: console.Console, args: []const u8) void {
    var count = false;
    var only_repeated = false;
    var only_unique = false;
    var ignore_case = false;
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'c' => count = true,
            'd' => only_repeated = true,
            'u' => only_unique = true,
            'i' => ignore_case = true,
            else => return opt.refuse(c, "uniq", o, USAGE),
        },
        else => return opt.refuse(c, "uniq", o, USAGE),
    };

    var in = filter.Inputs.init(c, "uniq", SPEC, args);
    const src = in.next() orelse return;
    const data = src.data;
    if (data.len == 0) return;

    var it = filter.lines(data);
    var group: ?[]const u8 = null;
    var n: usize = 0;
    while (it.next()) |line| {
        if (group) |g| {
            if (same(g, line, ignore_case)) {
                n += 1;
                continue;
            }
            flush(c, g, n, count, only_repeated, only_unique);
        }
        group = line;
        n = 1;
    }
    if (group) |g| flush(c, g, n, count, only_repeated, only_unique);
}

/// Print one group of equal adjacent lines, if the flags select it.
fn flush(c: console.Console, line: []const u8, n: usize, count: bool, only_repeated: bool, only_unique: bool) void {
    if (only_repeated and n < 2) return;
    if (only_unique and n > 1) return;
    if (count) {
        var buf: [16]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "{d: >7} ", .{n}) catch "");
    }
    filter.line(c, line);
}

fn same(a: []const u8, b: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}
