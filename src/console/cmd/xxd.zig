//! `xxd [-l LEN] [-s SKIP] [-c COLS] [-p] [FILE]` — a hex dump in xxd(1)'s own
//! shape and with its own flag letters: offset, hex bytes in pairs, printable
//! characters on the right; `-p` gives the plain hex a paste is made of. What
//! answers "what is actually in this file" for a `.kudos` image, a downloaded
//! body, or a text file whose trouble is a byte you cannot see.

const std = @import("std");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");

/// xxd's own default width, so its output is recognisable.
const DEFAULT_COLUMNS: usize = 16;

/// The widest line this will lay out. xxd allows more; past this the row buffer
/// stops being a line anyone reads.
const MAX_COLUMNS: usize = 64;

/// How much one dump prints unless -l says otherwise. xxd itself prints the
/// whole file; here a multi-megabyte image would be tens of thousands of lines
/// nobody reads and a wedged terminal while they scroll past, so the default is
/// bounded and the tail is COUNTED rather than dropped in silence.
const DEFAULT_LEN: usize = 256;

const USAGE = "usage: xxd [-l LEN] [-s SKIP] [-c COLS] [-p] [FILE]\n";
const SPEC = "l:s:c:p";

pub fn run(c: console.Console, args: []const u8) void {
    var len: usize = DEFAULT_LEN;
    var skip: usize = 0;
    var columns: usize = DEFAULT_COLUMNS;
    var plain = false;
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            'l' => len = std.fmt.parseInt(usize, v.arg, 10) catch return c.write(USAGE),
            's' => skip = std.fmt.parseInt(usize, v.arg, 10) catch return c.write(USAGE),
            'c' => {
                columns = std.fmt.parseInt(usize, v.arg, 10) catch return c.write(USAGE);
                if (columns == 0 or columns > MAX_COLUMNS) {
                    var buf: [56]u8 = undefined;
                    return c.write(std.fmt.bufPrint(&buf, "xxd: -c takes 1 to {d}\n", .{MAX_COLUMNS}) catch USAGE);
                }
            },
            else => return opt.refuse(c, "xxd", o, USAGE),
        },
        .flag => |ch| switch (ch) {
            'p' => plain = true,
            else => return opt.refuse(c, "xxd", o, USAGE),
        },
        else => return opt.refuse(c, "xxd", o, USAGE),
    };

    var in = filter.Inputs.init(c, "xxd", SPEC, args);
    while (in.next()) |src| {
        const from = @min(skip, src.data.len);
        const to = @min(from +| len, src.data.len);
        const shown = src.data[from..to];
        if (plain) plainHex(c, shown, columns) else dump(c, shown, from, columns);
        if (to < src.data.len) {
            var buf: [72]u8 = undefined;
            c.write(std.fmt.bufPrint(&buf, "({d} more bytes — -l {d} shows them)\n", .{ src.data.len - to, src.data.len - from }) catch "");
        }
    }
}

/// The full dump: `OFFSET: hex pairs  characters`, `base` being the offset the
/// first byte sits at in the whole file.
fn dump(c: console.Console, data: []const u8, base: usize, columns: usize) void {
    var off: usize = 0;
    while (off < data.len) : (off += columns) {
        const row = data[off..@min(off + columns, data.len)];
        var buf: [16]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "{x:0>8}: ", .{base + off}) catch "");
        for (0..columns) |i| {
            if (i < row.len) {
                c.write(std.fmt.bufPrint(&buf, "{x:0>2}", .{row[i]}) catch "");
            } else {
                c.write("  ");
            }
            if (i % 2 == 1) c.put(' '); // xxd groups bytes in pairs
        }
        c.put(' ');
        for (row) |b| c.put(if (std.ascii.isPrint(b)) b else '.');
        c.put('\n');
    }
}

/// `-p`: hex and nothing else, `columns` bytes to a line.
fn plainHex(c: console.Console, data: []const u8, columns: usize) void {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        var buf: [4]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "{x:0>2}", .{data[i]}) catch "");
        if ((i + 1) % columns == 0) c.put('\n');
    }
    if (data.len % columns != 0) c.put('\n');
}
