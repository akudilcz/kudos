//! `history [-c]` — the committed-command recall ring, numbered oldest first,
//! the way bash prints it; `-c` forgets it, the way bash's does. The lines come
//! through the console's one window into the line editor (Console.history);
//! the ring's depth is the editor's (editline.HISTORY), so what this prints IS
//! what Up-arrow can reach.

const std = @import("std");
const console = @import("../console.zig");
const opt = @import("../opt.zig");

const USAGE = "usage: history [-c]\n";

pub fn run(c: console.Console, args: []const u8) void {
    var clear = false;
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'c' => clear = true,
            else => return opt.refuse(c, "history", o, USAGE),
        },
        else => return opt.refuse(c, "history", o, USAGE),
    };
    if (clear) {
        c.clearHistory();
        return;
    }
    var i: usize = 0;
    while (c.history(i)) |line| : (i += 1) {
        var buf: [8]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "{d: >5}  ", .{i + 1}) catch "    ?  ");
        c.write(line);
        c.put('\n');
    }
}
