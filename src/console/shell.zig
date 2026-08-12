//! Shell command interpreter. Parses a line and dispatches to a built-in
//! command; each command's body lives in its own file under cmd/. The table
//! below is the single source of truth for the BUILT-IN commands on the
//! core-0 worker; cmd/help.zig prints the user-facing summary. A word the table does
//! not know is then offered to the runtime feature-command registry
//! (kernel/loader/features.zig) before it is reported unknown.
//!
//! Output goes to the terminal unless the line redirects it to a file with `>` or
//! `>>` (APP-028, APP-029), which is handled HERE rather than in any command: one
//! home means every built-in redirects, and no command has to know that its
//! output is going somewhere unusual. redirect.zig owns the grammar and the
//! budget.

const std = @import("std");
const console = @import("console.zig");
const redirect = @import("redirect.zig");
const vfs = @import("vfs");

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
    .{ .name = "rm", .run = @import("cmd/rm.zig").run },
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
    .{ .name = "caps", .run = @import("cmd/caps.zig").run },
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
/// console — or to a file, when the line redirects (APP-028, APP-029). Empty lines
/// are ignored; an unknown command name reports an error. This is the core-0
/// command path (local commands are dispatched earlier by the editor — see
/// terminal.zig/session.zig).
pub fn execute(c: console.Console, line_in: []const u8) void {
    if (redirect.parse(line_in)) |r| return toFile(c, r);
    dispatch(c, line_in);
}

/// Run one line against the console it was given.
fn dispatch(c: console.Console, line_in: []const u8) void {
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

// Static for LIFETIME, not allocation: a command can outlive its invocation
// (`net fetch` keeps the Console by value and completes on a later core-0 pass),
// so a stack buffer would be a dangling write once the fetch retired. A late
// write lands here and is dropped. One buffer suffices — this is the
// single-threaded core-0 worker.
var capture_buf: [redirect.MAX_BYTES]u8 = undefined;

/// Run `r.command` with its output going to `r.path` instead of the terminal.
/// Nothing is printed on success — the file IS the output — so every message here
/// is a refusal, and each names the path it could not write.
fn toFile(c: console.Console, r: redirect.Parsed) void {
    if (r.command.len == 0) {
        c.write("error: nothing to redirect (a command comes before '>')\n");
        return;
    }
    if (r.path.len == 0) {
        c.write("error: '>' needs a file to write to\n");
        return;
    }
    // The path is already trimmed, so an interior space means several words were
    // named where one file belongs.
    if (std.mem.indexOfAny(u8, r.path, " \t") != null) {
        c.write("error: '>' takes one file, not several\n");
        return;
    }

    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const abs = vfs.normalize(c.cwd(), r.path, &pathbuf) orelse {
        c.write("error: path too long: ");
        c.write(r.path);
        c.write("\n");
        return;
    };

    var sink = redirect.Sink{ .buf = &capture_buf };
    // `>>` prefills the existing content, so the append needs no second buffer
    // and the budget covers the whole file, not just the new part.
    if (r.mode == .append) {
        if (vfs.read(abs)) |existing| {
            if (!sink.prefill(existing)) {
                writeBudget(c, abs, "already holds more than");
                return;
            }
        }
    }

    var capture = Capture{ .inner = c, .sink = &sink };
    dispatch(capture.asConsole(), r.command);

    if (sink.overflowed()) {
        writeBudget(c, abs, "would take more than");
        return;
    }
    vfs.write(abs, sink.bytes()) catch |e| {
        c.write("error: cannot write ");
        c.write(abs);
        c.write(": ");
        c.write(@errorName(e));
        c.write("\n");
        return;
    };
}

/// The one wording for "this redirection does not fit its budget", which is a
/// refusal to write a partial file rather than a warning about one.
fn writeBudget(c: console.Console, abs: []const u8, what: []const u8) void {
    var buf: [24]u8 = undefined;
    c.write("error: ");
    c.write(abs);
    c.write(" ");
    c.write(what);
    c.write(" ");
    c.write(std.fmt.bufPrint(&buf, "{d}", .{redirect.MAX_BYTES}) catch "its budget of");
    c.write(" bytes — nothing written\n");
}

/// A console whose OUTPUT goes to a Sink; every other service stays the real
/// terminal's. Each forwarder exists because `ctx` is swapped along with `putFn`:
/// a field left pointing at the terminal's function would be called with THIS ctx
/// and read a Capture as a terminal. The set below is therefore the complete list
/// of what console.Console reaches through ctx — a new field needs one.
const Capture = struct {
    inner: console.Console,
    sink: *redirect.Sink,

    fn of(ctx: *anyopaque) *Capture {
        return @ptrCast(@alignCast(ctx));
    }
    fn put(ctx: *anyopaque, ch: u8) void {
        of(ctx).sink.put(ch);
    }
    fn clear(ctx: *anyopaque) void {
        of(ctx).inner.clear();
    }
    fn cwd(ctx: *anyopaque) []const u8 {
        return of(ctx).inner.cwd();
    }
    fn setCwd(ctx: *anyopaque, path: []const u8) void {
        of(ctx).inner.setCwd(path);
    }
    fn prompt(ctx: *anyopaque) void {
        of(ctx).inner.prompt();
    }
    fn setAiMode(ctx: *anyopaque, on: bool) void {
        of(ctx).inner.setAiMode(on);
    }

    /// The console to run the redirected command against: this capture's output,
    /// the original console's everything else (window, desktop, allocator, cwd).
    fn asConsole(self: *Capture) console.Console {
        var out = self.inner;
        out.ctx = self;
        out.putFn = put;
        out.clearFn = clear;
        out.cwdFn = cwd;
        out.setCwdFn = setCwd;
        out.promptFn = prompt;
        out.setAiModeFn = setAiMode;
        return out;
    }
};
