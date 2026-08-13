//! `free [-h]` — physical RAM in free(1)'s shape (MiB by default), plus what
//! the live session address spaces hold (MEM-008): a leaked session shows as
//! memory held by a session count that no longer matches the windows on
//! screen, which free RAM alone cannot distinguish from ordinary churn. `-h`
//! prints the sizes human-readably (bytesize.zig, the same wording ls -h uses).

const std = @import("std");
const buildinfo = @import("buildinfo");
const bytesize = @import("../bytesize.zig");
const pmm = @import("../../kernel/memory/pmm.zig");
const sessionspace = @import("../../kernel/memory/sessionspace.zig");
const console = @import("../console.zig");
const opt = @import("../opt.zig");

const USAGE = "usage: free [-h]\n";

pub fn run(c: console.Console, args: []const u8) void {
    var human = false;
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'h' => human = true,
            'm' => human = false, // MiB is already the default shape
            else => return opt.refuse(c, "free", o, USAGE),
        },
        else => return opt.refuse(c, "free", o, USAGE),
    };

    const total = pmm.totalBytes();
    const fr = pmm.freeBytes();
    var buf: [96]u8 = undefined;
    c.write("              total        used        free\n");
    if (human) {
        var tb: [bytesize.MAX_TEXT]u8 = undefined;
        var ub: [bytesize.MAX_TEXT]u8 = undefined;
        var fb: [bytesize.MAX_TEXT]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "Mem:    {s: >11}{s: >12}{s: >12}\n", .{
            bytesize.human(total, &tb),
            bytesize.human(total - fr, &ub),
            bytesize.human(fr, &fb),
        }) catch return);
    } else {
        c.write(std.fmt.bufPrint(&buf, "Mem:    {d: >11}{d: >12}{d: >12}\n", .{ total >> 20, (total - fr) >> 20, fr >> 20 }) catch return);
    }
    if (comptime !buildinfo.smp) return; // no session spaces on the single-core kernel
    const held = sessionspace.heldTotal();
    c.write(std.fmt.bufPrint(&buf, "sessions {d} holding {d} MiB\n", .{ held.sessions, held.bytes >> 20 }) catch return);
}
