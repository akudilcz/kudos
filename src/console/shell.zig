//! Shell command interpreter. Parses a line and dispatches to a built-in
//! command; each command's body lives in its own file under cmd/. The table
//! below is the single source of truth for the BUILT-IN commands a terminal's
//! command worker runs; cmd/help.zig prints the user-facing summary. A word the
//! table does not know is then offered to the runtime feature-command registry
//! (kernel/loader/features.zig) before it is reported unknown.
//!
//! REENTRANT: every terminal runs its own commands, all at the same time (spec
//! APP-031), so this file holds no per-line state of its own. The buffers a line
//! needs while it runs belong to the terminal and arrive on the console
//! (`c.scratch`, scratch.zig).
//!
//! Output goes to the terminal unless the line redirects it to a file with `>` or
//! `>>` (APP-028, APP-029), which is handled HERE rather than in any command: one
//! home means every built-in redirects, and no command has to know that its
//! output is going somewhere unusual. redirect.zig owns the grammar and the
//! budget.

const std = @import("std");
const console = @import("console.zig");
const glob = @import("glob.zig");
const opt = @import("opt.zig");
const redirect = @import("redirect.zig");
const vfs = @import("vfs");

/// One built-in command: its name, the handler that runs it (given the console
/// and the already-trimmed argument string), and whether its arguments glob.
/// Globbing is opt-in for the FILE commands only: a bare `*` is multiplication
/// in a line of Zig being echoed into a file, and free text in a `kudos ai`
/// turn — expanding those to a file list would corrupt exactly what this shell
/// exists to type.
const Command = struct {
    name: []const u8,
    run: *const fn (c: console.Console, args: []const u8) void,
    globs: bool = false,
};

// The Linux-shaped surface: every top-level name is a command a Linux shell
// user already knows, spelled and shaped the way they know it. Everything
// kudos-specific lives under the ONE `kudos` word (cmd/kudos.zig) — its
// subcommands are that file's table, not rows here.
const COMMANDS = [_]Command{
    .{ .name = "help", .run = @import("cmd/help.zig").run },
    .{ .name = "clear", .run = @import("cmd/clear.zig").run },
    .{ .name = "echo", .run = @import("cmd/echo.zig").run },
    .{ .name = "cd", .run = @import("cmd/cd.zig").run },
    .{ .name = "pwd", .run = @import("cmd/pwd.zig").run },
    .{ .name = "ls", .run = @import("cmd/ls.zig").run, .globs = true },
    .{ .name = "cat", .run = @import("cmd/cat.zig").run, .globs = true },
    .{ .name = "rm", .run = @import("cmd/rm.zig").run, .globs = true },
    .{ .name = "mkdir", .run = @import("cmd/mkdir.zig").run },
    .{ .name = "rmdir", .run = @import("cmd/rmdir.zig").run },
    .{ .name = "touch", .run = @import("cmd/touch.zig").run },
    .{ .name = "cp", .run = @import("cmd/cp.zig").run, .globs = true },
    .{ .name = "mv", .run = @import("cmd/mv.zig").run, .globs = true },
    .{ .name = "grep", .run = @import("cmd/grep.zig").run, .globs = true },
    .{ .name = "wc", .run = @import("cmd/wc.zig").run, .globs = true },
    .{ .name = "head", .run = @import("cmd/head.zig").run, .globs = true },
    .{ .name = "tail", .run = @import("cmd/tail.zig").run, .globs = true },
    .{ .name = "more", .run = @import("cmd/pager.zig").run, .globs = true },
    .{ .name = "less", .run = @import("cmd/pager.zig").run, .globs = true },
    .{ .name = "nl", .run = @import("cmd/nl.zig").run, .globs = true },
    .{ .name = "sort", .run = @import("cmd/sort.zig").run, .globs = true },
    .{ .name = "uniq", .run = @import("cmd/uniq.zig").run, .globs = true },
    .{ .name = "cut", .run = @import("cmd/cut.zig").run, .globs = true },
    .{ .name = "tee", .run = @import("cmd/tee.zig").run },
    .{ .name = "diff", .run = @import("cmd/diff.zig").run, .globs = true },
    .{ .name = "xxd", .run = @import("cmd/xxd.zig").run, .globs = true },
    .{ .name = "find", .run = @import("cmd/find.zig").run },
    .{ .name = "stat", .run = @import("cmd/stat.zig").run, .globs = true },
    .{ .name = "du", .run = @import("cmd/du.zig").run, .globs = true },
    .{ .name = "df", .run = @import("cmd/df.zig").run },
    .{ .name = "basename", .run = @import("cmd/basename.zig").runBase },
    .{ .name = "dirname", .run = @import("cmd/basename.zig").runDir },
    .{ .name = "seq", .run = @import("cmd/seq.zig").run },
    .{ .name = "sleep", .run = @import("cmd/sleep.zig").run },
    .{ .name = "history", .run = @import("cmd/history.zig").run },
    .{ .name = "lspci", .run = @import("cmd/lspci.zig").run },
    .{ .name = "ip", .run = @import("cmd/ip.zig").run },
    .{ .name = "ping", .run = @import("cmd/ping.zig").run },
    .{ .name = "host", .run = @import("cmd/host.zig").run },
    .{ .name = "curl", .run = @import("cmd/curl.zig").run },
    .{ .name = "free", .run = @import("cmd/free.zig").run },
    .{ .name = "ps", .run = @import("cmd/ps.zig").run },
    .{ .name = "uname", .run = @import("cmd/uname.zig").run },
    .{ .name = "uptime", .run = @import("cmd/uptime.zig").run },
    .{ .name = "kudos", .run = @import("cmd/kudos.zig").run },
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

/// Parse a command line and run it: split the unquoted `;` list and run each
/// command left to right, as bash does. Empty lines are ignored. This is the
/// core-0 command path (local commands are dispatched earlier by the editor —
/// see terminal.zig/session.zig).
pub fn execute(c: console.Console, line_in: []const u8) void {
    var cmds: [redirect.MAX_LIST][]const u8 = undefined;
    const n = redirect.splitList(line_in, &cmds) orelse {
        var buf: [48]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "shell: at most {d} commands on a line\n", .{redirect.MAX_LIST}) catch "shell: too many commands\n");
        return;
    };
    for (cmds[0..n]) |cmd| executeOne(c, cmd);
}

/// Run ONE command of the list: split at the redirect (APP-028, APP-029) and
/// the pipes, glob-expand each stage's arguments, then run the stages left to
/// right — each stage's captured output is the next stage's `Console.stdin`, and
/// the last stage writes to the terminal or the redirect target.
fn executeOne(c: console.Console, line_in: []const u8) void {
    const r = redirect.parse(line_in);
    const body = if (r) |red| red.command else line_in;

    var stages: [redirect.MAX_STAGES][]const u8 = undefined;
    const n = redirect.splitPipes(body, &stages);
    if (n == 0) {
        var buf: [48]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "pipe: at most {d} stages\n", .{redirect.MAX_STAGES}) catch "pipe: too many stages\n");
        return;
    }
    if (n == 1 and stages[0].len == 0) return; // an empty line
    for (stages[0..n]) |s| {
        if (s.len == 0) {
            c.write("syntax error near '|'\n");
            return;
        }
    }

    // Head stages run captured; only the LAST stage's output reaches the
    // terminal or the redirect target. Two bounce buffers alternate, so a
    // stage's input stays intact while its output fills the other.
    var stdin: ?[]const u8 = null;
    for (stages[0 .. n - 1], 0..) |stage, i| {
        var inner = c;
        inner.stdin = stdin;
        var sink = redirect.Sink{ .buf = &c.scratch.pipe[i & 1] };
        var capture = Capture{ .inner = inner, .sink = &sink };
        dispatch(capture.asConsole(), stage);
        if (sink.overflowed()) {
            var buf: [64]u8 = undefined;
            c.write(std.fmt.bufPrint(&buf, "pipe: a stage wrote more than {d} bytes\n", .{redirect.MAX_BYTES}) catch "pipe: stage too large\n");
            return;
        }
        stdin = sink.bytes();
    }
    var last = c;
    last.stdin = stdin;
    if (r) |red| return toFile(last, red, stages[n - 1]);
    dispatch(last, stages[n - 1]);
}

/// Run one stage against the console it was given. A globbing command's
/// arguments are expanded first (bash semantics: a word with `*`/`?` becomes
/// the matching names; no match leaves the word as typed).
fn dispatch(c: console.Console, line_in: []const u8) void {
    const parsed = splitCommand(line_in);
    if (parsed.cmd.len == 0) return;

    for (COMMANDS) |cmd| {
        if (std.mem.eql(u8, parsed.cmd, cmd.name)) {
            const args = if (cmd.globs) expandGlobs(c, parsed.args) orelse return else parsed.args;
            cmd.run(c, args);
            return;
        }
    }
    // Not a built-in: a loaded feature may have registered this word (AGT-010).
    if (@import("cmd/feature.zig").dispatch(c, parsed.cmd, parsed.args)) return;
    c.write(parsed.cmd);
    c.write(": command not found\n");
}

/// Run one command line with its output captured into `buf` instead of the
/// terminal — the agent's `shell` tool and netdebug's remote shell. The same
/// dispatch a terminal uses: pipes, redirects and globs all work; a redirect
/// writes its file and captures only the refusals. Returns the sink (length +
/// loss count); the caller states truncation rather than hiding it.
pub fn executeCaptured(base: console.Console, line: []const u8, buf: []u8) redirect.Sink {
    var sink = redirect.Sink{ .buf = buf };
    var capture = Capture{ .inner = base, .sink = &sink };
    execute(capture.asConsole(), line);
    return sink;
}

/// Glob-expand `args` into this terminal's expansion buffer, or return `args`
/// untouched when no word globs. Null (with the complaint printed) when the
/// expansion does not fit — running a command on a silently truncated file list
/// is how a glob deletes the wrong files.
///
/// The buffer is the CONSOLE's, not this file's: terminals run their commands at
/// the same time (APP-031), and it outlives the command for the reason
/// scratch.zig states.
fn expandGlobs(c: console.Console, args: []const u8) ?[]const u8 {
    if (!glob.hasGlob(args)) return args;
    const buf: []u8 = &c.scratch.expand;
    var used: usize = 0;
    var overflowed = false;
    var it = opt.Words{ .s = args };
    while (it.next()) |word| {
        const before = used;
        if (word[0] == '\'' or word[0] == '"') {
            // A quoted word never globs (bash: quoting suppresses expansion) —
            // the quotes stay on for the command's own operand pass to strip.
            appendWord(buf, word, &used, &overflowed);
        } else if (glob.hasGlob(word)) {
            // The pattern is the last path component; what precedes it names
            // the directory, kept verbatim on every expanded name.
            const cut = if (std.mem.lastIndexOfScalar(u8, word, '/')) |i| i + 1 else 0;
            var pathbuf: [vfs.MAX_PATH]u8 = undefined;
            const dir = vfs.normalize(c.cwd(), if (cut == 0) "." else word[0..cut], &pathbuf);
            var m = GlobMatches{ .buf = buf, .prefix = word[0..cut], .pat = word[cut..], .used = &used, .overflowed = &overflowed };
            if (dir) |d| vfs.list(d, GlobMatches.cb, &m) catch {};
            if (used == before) appendWord(buf, word, &used, &overflowed); // no match: the word as typed
        } else {
            appendWord(buf, word, &used, &overflowed);
        }
        if (overflowed) {
            var msg: [56]u8 = undefined;
            c.write(std.fmt.bufPrint(&msg, "glob: expansion exceeds {d} bytes — not run\n", .{buf.len}) catch "glob: expansion too long\n");
            return null;
        }
    }
    return std.mem.trimEnd(u8, buf[0..used], " ");
}

/// One glob expansion in progress: the directory prefix to restore, the
/// pattern, and where matches accumulate.
const GlobMatches = struct {
    buf: []u8,
    prefix: []const u8,
    pat: []const u8,
    used: *usize,
    overflowed: *bool,

    fn cb(ctx: ?*anyopaque, e: vfs.ifilesys.Entry) void {
        const m: *GlobMatches = @ptrCast(@alignCast(ctx.?));
        if (!glob.match(m.pat, e.name)) return;
        appendParts(m.buf, m.prefix, e.name, m.used, m.overflowed);
    }
};

fn appendWord(buf: []u8, word: []const u8, used: *usize, overflowed: *bool) void {
    appendParts(buf, "", word, used, overflowed);
}

/// Append `prefix ++ name ++ ' '` to the expansion buffer, latching the overflow.
fn appendParts(buf: []u8, prefix: []const u8, name: []const u8, used: *usize, overflowed: *bool) void {
    const need = prefix.len + name.len + 1;
    if (used.* + need > buf.len) {
        overflowed.* = true;
        return;
    }
    @memcpy(buf[used.*..][0..prefix.len], prefix);
    @memcpy(buf[used.* + prefix.len ..][0..name.len], name);
    buf[used.* + prefix.len + name.len] = ' ';
    used.* += need;
}

/// Run the pipeline's LAST stage with its output going to `r.path` instead of
/// the terminal. Nothing is printed on success — the file IS the output — so
/// every message here is a refusal, and each names the path it could not write.
fn toFile(c: console.Console, r: redirect.Parsed, stage: []const u8) void {
    if (stage.len == 0) {
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

    var sink = redirect.Sink{ .buf = &c.scratch.capture };
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
    dispatch(capture.asConsole(), stage);

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
    fn holdPrompt(ctx: *anyopaque) void {
        of(ctx).inner.holdPrompt();
    }
    fn setInputMask(ctx: *anyopaque, on: bool) void {
        of(ctx).inner.setInputMask(on);
    }
    /// A no-op, not a forward: the sink's bytes go to a file or the next pipe
    /// stage, and color is grid presentation, not content (console.setColorFn).
    fn setColor(ctx: *anyopaque, argb: u32) void {
        _ = ctx;
        _ = argb;
    }
    fn readHistory(ctx: *anyopaque, i: usize) ?[]const u8 {
        return of(ctx).inner.history(i);
    }
    fn clearHistory(ctx: *anyopaque) void {
        of(ctx).inner.clearHistory();
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
        out.holdPromptFn = holdPrompt;
        out.setInputMaskFn = setInputMask;
        out.setColorFn = setColor;
        out.readHistoryFn = readHistory;
        out.clearHistoryFn = clearHistory;
        return out;
    }
};
