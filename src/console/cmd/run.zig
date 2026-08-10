//! `run <name>` — load and execute a compiled `.kudos` app.
//!
//! Runs inline on THIS session's own task, inside the session's address space
//! (MOD-006): a fault kills only this session — the task dies, the window
//! closes, the core and every other session keep running (MEM-006, AGT-009,
//! KRN-006). Refused on the single-core build, which has no session spaces.
//!
//! The image itself, and the `Api` it reaches the system through, are
//! console/apprun.zig — the agent runs the same images through the same
//! surface, with no terminal behind them.

const std = @import("std");
const Out = @import("../out.zig").Out;
const apprun = @import("../apprun.zig");
const vfs = @import("vfs");
const buildinfo = @import("buildinfo");
const sessionspace = @import("../../kernel/memory/sessionspace.zig");

pub fn run(out: Out, args: []const u8) void {
    const name = std.mem.trim(u8, args, " \t");
    if (name.len == 0) {
        out.str("usage: run <name>\n");
        return;
    }

    // Fault containment needs a session address space (see file header).
    if (!buildinfo.smp) {
        out.str("run: needs the SMP build so a crash is contained to this session\n");
        return;
    }
    const sid = sessionspace.currentSessionId() orelse {
        out.str("run: not on a session task (no address space to contain a crash)\n");
        return;
    };

    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "/ramdisk/{s}.kudos", .{name}) catch {
        out.str("run: name too long\n");
        return;
    };
    const blob = vfs.read(path) orelse {
        out.str("run: no such app: ");
        out.str(name);
        out.str("\n");
        return;
    };

    // A terminal is watching, so this run MAY open its own window (Interface.draw).
    const rc = apprun.execute(out, blob, sessionspace.moduleRegion(sid), .{ .windowed = true }) catch |e| {
        out.str("run: ");
        out.str(apprun.reason(e));
        out.str("\n");
        return;
    };
    var buf: [32]u8 = undefined;
    out.str(std.fmt.bufPrint(&buf, "\n[exit {d}]\n", .{rc}) catch "\n");
}
