//! `stats [PREFIX]` — the diagnostics counters.

const std = @import("std");
const counter = @import("../../kernel/debug/counter.zig");
const console = @import("../console.zig");

/// `stats [PREFIX]` — print the diagnostics counters (kernel/debug/counter.zig):
/// every registered counter, or only those whose `<mod>.<name>` key starts with
/// PREFIX. The same registry the KMR1 OP_STATS op dumps over netdebug — this is
/// the view for a machine with no collector attached.
pub fn run(c: console.Console, args: []const u8) void {
    var any = false;
    for (counter.all()) |cnt| {
        var key: [64]u8 = undefined;
        const k = std.fmt.bufPrint(&key, "{s}.{s}", .{ @tagName(cnt.mod), cnt.name }) catch continue;
        if (args.len != 0 and !std.mem.startsWith(u8, k, args)) continue;
        any = true;
        var line: [96]u8 = undefined;
        c.write(std.fmt.bufPrint(&line, "{s} = {d}\n", .{ k, cnt.v }) catch continue);
    }
    if (!any) c.write("no matching counters\n");
}
