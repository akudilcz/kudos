//! `free` — physical RAM in free(1)'s shape (MiB), plus what the live session
//! address spaces hold (MEM-008): a leaked session shows as memory held by a
//! session count that no longer matches the windows on screen, which free RAM
//! alone cannot distinguish from ordinary churn.

const std = @import("std");
const buildinfo = @import("buildinfo");
const pmm = @import("../../kernel/memory/pmm.zig");
const sessionspace = @import("../../kernel/memory/sessionspace.zig");
const console = @import("../console.zig");

pub fn run(c: console.Console, _: []const u8) void {
    const total = pmm.totalBytes() >> 20;
    const fr = pmm.freeBytes() >> 20;
    var buf: [96]u8 = undefined;
    c.write("              total        used        free\n");
    c.write(std.fmt.bufPrint(&buf, "Mem:    {d: >11}{d: >12}{d: >12}\n", .{ total, total - fr, fr }) catch return);
    if (comptime !buildinfo.smp) return; // no session spaces on the single-core kernel
    const held = sessionspace.heldTotal();
    c.write(std.fmt.bufPrint(&buf, "sessions {d} holding {d} MiB\n", .{ held.sessions, held.bytes >> 20 }) catch return);
}
