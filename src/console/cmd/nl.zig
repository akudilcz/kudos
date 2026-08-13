//! `nl [-b a|t] [FILE...]` — number the lines of a file or the pipe. `-bt`,
//! nl(1)'s default, numbers only the non-empty lines (an empty line is printed
//! bare); `-ba` numbers every line, which is what you want when the number is
//! there to point at a line.

const std = @import("std");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");

const USAGE = "usage: nl [-b a|t] [FILE...]\n";
const SPEC = "b:";

pub fn run(c: console.Console, args: []const u8) void {
    var number_empty = false; // -bt, as nl(1) starts
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            'b' => {
                if (v.arg.len != 1 or (v.arg[0] != 'a' and v.arg[0] != 't')) return c.write(USAGE);
                number_empty = v.arg[0] == 'a';
            },
            else => return opt.refuse(c, "nl", o, USAGE),
        },
        else => return opt.refuse(c, "nl", o, USAGE),
    };

    var in = filter.Inputs.init(c, "nl", SPEC, args);
    while (in.next()) |src| {
        var it = filter.lines(src.data);
        var n: usize = 0;
        while (it.next()) |line| {
            if (line.len == 0 and !number_empty) {
                c.put('\n');
                continue;
            }
            n += 1;
            var buf: [16]u8 = undefined;
            c.write(std.fmt.bufPrint(&buf, "{d: >6}\t", .{n}) catch "");
            filter.line(c, line);
        }
    }
}
