//! `mem` — free / total physical RAM, and what the live sessions hold.

const std = @import("std");
const buildinfo = @import("buildinfo");
const pmm = @import("../../kernel/memory/pmm.zig");
const sessionspace = @import("../../kernel/memory/sessionspace.zig");
const console = @import("../console.zig");

/// `mem` — report free and total physical RAM (in MiB) from the PMM, and the
/// memory the live session address spaces account for (MEM-008). The second
/// line is what makes per-space accounting observable: a leaked session shows
/// as memory still held by a session count that no longer matches the windows
/// on screen, which free-RAM alone cannot distinguish from ordinary churn.
pub fn run(c: console.Console, _: []const u8) void {
    var buf: [80]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "free {d} MiB / {d} MiB total\n", .{ pmm.freeBytes() >> 20, pmm.totalBytes() >> 20 }) catch return;
    c.write(s);
    if (comptime !buildinfo.smp) return; // no session spaces on the single-core kernel
    const held = sessionspace.heldTotal();
    var buf2: [80]u8 = undefined;
    const s2 = std.fmt.bufPrint(&buf2, "sessions {d} holding {d} MiB\n", .{ held.sessions, held.bytes >> 20 }) catch return;
    c.write(s2);
}
