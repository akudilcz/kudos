//! `more [FILE...]` / `less [FILE...]` — print files, or the pipe.
//!
//! NOT interactive, and it says so: a kudos terminal keeps its own scrollback
//! (Shift-PgUp/PgDn over the retained grid), so the paging a Linux pager exists
//! to provide is already in the window the output lands in. The commands are
//! here because they are how a person — or an agent used to a Linux shell —
//! reaches for a file, and answering "command not found" to `less notes.txt`
//! teaches nothing. What they add over `cat` is the line count and the reminder
//! of where the earlier lines went.

const std = @import("std");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");

const USAGE = "usage: more|less [FILE...]\n";

pub fn run(c: console.Console, args: []const u8) void {
    var sc = opt.Scan.init("", args);
    // -N, -S, +F and the rest all describe an interactive view this has no way
    // to give; naming that beats appearing to honour them.
    while (sc.next()) |o| return opt.refuse(c, "more", o, USAGE);

    var in = filter.Inputs.init(c, "more", "", args);
    while (in.next()) |src| {
        c.write(src.data);
        if (src.data.len > 0 and src.data[src.data.len - 1] != '\n') c.put('\n');
        var buf: [72]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "({d} lines — Shift-PgUp scrolls back)\n", .{filter.lineCount(src.data)}) catch "\n");
    }
}
