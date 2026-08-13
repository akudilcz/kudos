//! Local terminal commands that run inline on the terminal's OWN core, loading it
//! (visible in `ps` CPU%) instead of being proxied to core 0. One implementation,
//! shared by both line editors: the SMP per-core editor (session.zig, output via
//! its req ring) and the single-core terminal (terminal.zig, output straight to
//! its grid). Each command body lives in its own file under cmd/; this module is
//! the dispatch table — the single source of truth for which commands run locally.

const std = @import("std");
const buildinfo = @import("buildinfo");
const redirect = @import("redirect.zig");

pub const Out = @import("out.zig").Out;

/// A local command: its name and the body that runs it on this core. `args` is the
/// trimmed argument string; `out` is where it writes and how it learns it should
/// stop. The dispatch table is shared by session.zig and terminal.zig.
pub const Command = struct {
    name: []const u8,
    run: *const fn (out: Out, args: []const u8) void,
};

// `shutdown` is a Linux word and stays top-level; the kudos-specific locals
// (`prime`, `rt`, `run`) are reached through the `kudos` group word like every
// other kudos command — resolveLine sees through it, so they still run on THIS
// core. `kudos run <name>` executes a compiled .kudos app here so a fault is
// contained to this session (spec AGT-008).
const BASE_COMMANDS = [_]Command{
    .{ .name = "shutdown", .run = @import("cmd/shutdown.zig").run },
};

/// The group word everything kudos-specific lives under (cmd/kudos.zig holds
/// the shell-side table; these are the LOCAL members).
pub const GROUP = "kudos";

const GROUP_COMMANDS = [_]Command{
    .{ .name = "prime", .run = @import("cmd/prime.zig").run },
    .{ .name = "rt", .run = @import("cmd/rt.zig").run },
    .{ .name = "run", .run = @import("cmd/run.zig").run },
};

// No local `vm`: a guest's vCPU is an ordinary scheduled task (VIRT-021), so
// there is nothing core-local about booting one — both builds use the shell
// `vm` (cmd/vm.zig), which posts a request and returns.
const SMP_COMMANDS = [_]Command{};

// `crash` and `memfault` exist only on instrumented builds: the panic- and
// memory-fault-containment regressions need triggers; a shipping image must
// not carry one.
pub const COMMANDS = if (buildinfo.test_hooks)
    BASE_COMMANDS ++ SMP_COMMANDS ++ [_]Command{
        .{ .name = "crash", .run = @import("cmd/crash.zig").run },
        .{ .name = "memfault", .run = @import("cmd/memfault.zig").run },
    }
else
    BASE_COMMANDS ++ SMP_COMMANDS;

/// The local command names, for completing the first word of a line — derived
/// from COMMANDS so the table above stays the one source of what exists.
pub const NAMES: [COMMANDS.len][]const u8 = blk: {
    var n: [COMMANDS.len][]const u8 = undefined;
    for (COMMANDS, 0..) |c, i| n[i] = c.name;
    break :blk n;
};

/// Look up a local command by exact name (no prefix matching). Returns null if the
/// word is not a local command, so the caller proxies it to core 0 instead.
pub fn lookup(cmd: []const u8) ?Command {
    for (COMMANDS) |c| {
        if (std.mem.eql(u8, cmd, c.name)) return c;
    }
    return null;
}

/// A resolved local command and the arguments that are its own.
pub const Resolved = struct { c: Command, args: []const u8 };

/// Resolve a parsed line to a local command, seeing through the `kudos` group
/// word: `kudos prime 9` is `prime 9` on THIS core, exactly as when prime was a
/// top-level word. A `kudos` subcommand that is not local returns null and
/// reaches cmd/kudos.zig through the shell.
pub fn resolveLine(cmd: []const u8, args: []const u8) ?Resolved {
    if (std.mem.eql(u8, cmd, GROUP)) {
        const sp = std.mem.indexOfScalar(u8, args, ' ');
        const sub = if (sp) |i| args[0..i] else args;
        const rest = if (sp) |i| std.mem.trim(u8, args[i + 1 ..], " \t") else "";
        for (GROUP_COMMANDS) |c| {
            if (std.mem.eql(u8, sub, c.name)) return .{ .c = c, .args = rest };
        }
        return null;
    }
    if (lookup(cmd)) |c| return .{ .c = c, .args = args };
    return null;
}

/// Whether `args` asks for a redirection (APP-028) or a pipe, which a local
/// command cannot serve: these run on the terminal's own core and write through
/// `Out`, which carries no working directory and no capture buffer — both are
/// the shell's facilities (shell.zig). Said plainly because the alternative is
/// worse than a refusal: `kudos run app > out.txt` would otherwise reach
/// cmd/run.zig as a request for a module named "app > out.txt".
pub fn refusesRedirect(args: []const u8) bool {
    if (redirect.parse(args) != null) return true;
    var stages: [redirect.MAX_STAGES][]const u8 = undefined;
    return redirect.splitPipes(args, &stages) != 1;
}
