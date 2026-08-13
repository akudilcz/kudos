//! `kudos SUBCOMMAND` — the one front door to everything kudos-specific, so the
//! top-level command set stays the Linux one. The LOCAL members (`prime`, `rt`,
//! `run`) are not rows here: the editors resolve them through
//! localcmd.resolveLine before the shell sees the line, so they run on the
//! session's own core exactly as when they were top-level words.

const std = @import("std");
const console = @import("../console.zig");

const Sub = struct {
    name: []const u8,
    run: *const fn (c: console.Console, args: []const u8) void,
    what: []const u8,
};

const SUBS = [_]Sub{
    .{ .name = "ai", .run = @import("ai.zig").run, .what = "talk to the AI agent (or /help inside)" },
    .{ .name = "compile", .run = @import("compile.zig").run, .what = "compile a .zig file into a .kudos app" },
    .{ .name = "vm", .run = @import("vm.zig").run, .what = "guest VMs: N | list | status | stop ID" },
    .{ .name = "caps", .run = @import("caps.zig").run, .what = "the capabilities a .kudos module may bind" },
    .{ .name = "feature", .run = @import("feature.zig").run, .what = "manage loaded .kudos feature modules" },
    .{ .name = "show", .run = @import("show.zig").run, .what = "open a spinning 3D model window (.glb)" },
    .{ .name = "background", .run = @import("background.zig").run, .what = "change the desktop background (.png)" },
    .{ .name = "term", .run = @import("term.zig").run, .what = "open a new terminal" },
    .{ .name = "system", .run = @import("system.zig").run, .what = "open the system monitor" },
    .{ .name = "clock", .run = @import("clock.zig").run, .what = "open the analog clock" },
    .{ .name = "calc", .run = @import("calc.zig").run, .what = "open the graphing calculator" },
    .{ .name = "stats", .run = @import("stats.zig").run, .what = "diagnostics counters ([PREFIX] filters)" },
    .{ .name = "flipstat", .run = @import("flipstat.zig").run, .what = "re-arm the present-cadence sample" },
};

pub fn run(c: console.Console, args: []const u8) void {
    const sp = std.mem.indexOfScalar(u8, args, ' ');
    const sub = if (sp) |i| args[0..i] else args;
    const rest = if (sp) |i| std.mem.trim(u8, args[i + 1 ..], " \t") else "";

    if (sub.len == 0) return usage(c);
    for (SUBS) |s| {
        if (std.mem.eql(u8, sub, s.name)) return s.run(c, rest);
    }
    c.write("kudos: '");
    c.write(sub);
    c.write("' is not a kudos command\n");
    usage(c);
}

fn usage(c: console.Console) void {
    c.write("usage: kudos SUBCOMMAND\n");
    for (SUBS) |s| {
        c.write("  kudos ");
        c.write(s.name);
        var pad = 11 -| s.name.len;
        while (pad > 0) : (pad -= 1) c.put(' ');
        c.write(s.what);
        c.put('\n');
    }
    c.write("  kudos run NAME    run a compiled .kudos app on this core\n");
    c.write("  kudos prime N     load THIS core: find primes until one >= N\n");
    c.write("  kudos rt N        real-time task on THIS core: N periods at 10 Hz\n");
}
