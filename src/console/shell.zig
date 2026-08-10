//! Shell command interpreter. Parses a line and dispatches to a built-in
//! command; each command's body lives in its own file under cmd/. The table
//! below is the single source of truth for the BUILT-IN commands on the
//! core-0 worker; cmd/help.zig prints the user-facing summary. A word the table does
//! not know is then offered to the runtime feature-command registry
//! (kernel/loader/features.zig) before it is reported unknown.

const std = @import("std");
const console = @import("console.zig");

/// One built-in command: its name and the handler that runs it (given the
/// console and the already-trimmed argument string).
const Command = struct {
    name: []const u8,
    run: *const fn (c: console.Console, args: []const u8) void,
};

const COMMANDS = [_]Command{
    .{ .name = "help", .run = @import("cmd/help.zig").run },
    .{ .name = "clear", .run = @import("cmd/clear.zig").run },
    .{ .name = "echo", .run = @import("cmd/echo.zig").run },
    .{ .name = "cd", .run = @import("cmd/cd.zig").run },
    .{ .name = "ls", .run = @import("cmd/ls.zig").run },
    .{ .name = "dir", .run = @import("cmd/ls.zig").run }, // alias: same runner, one implementation
    .{ .name = "cat", .run = @import("cmd/cat.zig").run },
    .{ .name = "lspci", .run = @import("cmd/lspci.zig").run },
    .{ .name = "net", .run = @import("cmd/net.zig").run },
    .{ .name = "mem", .run = @import("cmd/mem.zig").run },
    .{ .name = "vm", .run = @import("cmd/vm.zig").run },
    .{ .name = "ps", .run = @import("cmd/ps.zig").run },
    .{ .name = "term", .run = @import("cmd/term.zig").run },
    .{ .name = "system", .run = @import("cmd/system.zig").run },
    .{ .name = "clock", .run = @import("cmd/clock.zig").run },
    .{ .name = "calc", .run = @import("cmd/calc.zig").run },
    .{ .name = "background", .run = @import("cmd/background.zig").run },
    .{ .name = "ai", .run = @import("cmd/ai.zig").run },
    .{ .name = "compile", .run = @import("cmd/compile.zig").run },
    .{ .name = "feature", .run = @import("cmd/feature.zig").run },
    .{ .name = "show", .run = @import("cmd/show.zig").run },
    .{ .name = "flipstat", .run = @import("cmd/flipstat.zig").run },
    .{ .name = "stats", .run = @import("cmd/stats.zig").run },
    .{ .name = "exit", .run = @import("cmd/exit.zig").run },
    .{ .name = "reboot", .run = @import("cmd/reboot.zig").run },
};

/// The built-in command names, for completing the first word of a line —
/// derived from COMMANDS so the table above stays the one source of what
/// exists. The local per-core commands add their own (localcmd.NAMES).
pub const NAMES: [COMMANDS.len][]const u8 = blk: {
    var n: [COMMANDS.len][]const u8 = undefined;
    for (COMMANDS, 0..) |c, i| n[i] = c.name;
    break :blk n;
};

/// Split a command line into the command word and the trimmed argument string.
/// Shared shape with the per-core local dispatch (session.zig) so both parse
/// identically — and so neither uses prefix matching, which mis-fires (`primer`
/// is not `prime`).
pub fn splitCommand(line: []const u8) struct { cmd: []const u8, args: []const u8 } {
    const trimmed = std.mem.trim(u8, line, " \t");
    const sp = std.mem.indexOfScalar(u8, trimmed, ' ');
    return .{
        .cmd = if (sp) |i| trimmed[0..i] else trimmed,
        .args = if (sp) |i| std.mem.trim(u8, trimmed[i + 1 ..], " \t") else "",
    };
}

/// Parse a command line and run the matching built-in, writing its output to the
/// console. Empty lines are ignored; an unknown command name reports an error.
/// This is the core-0 command path (local commands are dispatched earlier by the
/// editor — see terminal.zig/session.zig).
pub fn execute(c: console.Console, line_in: []const u8) void {
    const parsed = splitCommand(line_in);
    if (parsed.cmd.len == 0) return;

    for (COMMANDS) |cmd| {
        if (std.mem.eql(u8, parsed.cmd, cmd.name)) {
            cmd.run(c, parsed.args);
            return;
        }
    }
    // Not a built-in: a loaded feature may have registered this word (AGT-010).
    if (@import("cmd/feature.zig").dispatch(c, parsed.cmd, parsed.args)) return;
    c.write("error: unknown command '");
    c.write(parsed.cmd);
    c.write("' (try 'help')\n");
}
