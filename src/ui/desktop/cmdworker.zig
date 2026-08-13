//! The command-worker tasks: one per terminal session slot, each running the
//! committed command lines of whatever terminal holds its slot.
//!
//! WHY ONE PER SLOT. A shell command runs to completion on the task that claims
//! it, and some commands are long — an agent turn streams a reply and calls
//! tools for minutes. A single worker serving every terminal therefore made a
//! long command in ONE window stop every other window's shell dead, with no
//! sign of why: the other terminals took the keystrokes, echoed the line, and
//! then sat on a committed line nobody would run until the first command
//! finished. A worker per slot is what makes the shells independent
//! (spec APP-031) — the cost of a long command is paid by the terminal that
//! asked for it and by nobody else.
//!
//! The tasks SLEEP. A worker blocks until its own slot has a command posted
//! (session.commandPending) and is woken by the post itself, so idle terminals
//! cost no scheduling at all — where one scanning worker had to keep polling
//! every terminal in turn to notice any of them.
//!
//! A worker is PERMANENT: started the first time a terminal takes its slot and
//! never exited, so it serves every later terminal that takes the same slot.
//! That is what lets a waker hold a raw task pointer (session.zig) and what lets
//! `cancelCommand` name the task a ^C should fell without racing its reaping.

const std = @import("std");
const buildinfo = @import("buildinfo");
const debug = @import("../../kernel/debug/debug.zig");
const klog = @import("../../kernel/debug/klog.zig");
const lifecycle = @import("lifecycle.zig");
const sched = @import("../../kernel/sched/sched.zig");
const sessionmod = @import("../../console/session.zig");
const Desktop = @import("desktop.zig").Desktop;

/// The desktop the workers run commands against. One machine, one desktop —
/// every terminal lives in it — so this is that desktop, published by `ensure`
/// rather than threaded through a task entry point, which takes no arguments.
var g_desktop: ?*Desktop = null;

/// Start slot `id`'s command worker if it has none yet. Called when a terminal
/// takes the slot; a no-op on every later terminal in the same slot, because
/// the worker is permanent.
///
/// A failure to spawn is reported and left: the terminal opens and edits
/// normally, and its committed lines go unrun — the alternative, refusing the
/// window, would trade a working terminal for none at all. The trace names the
/// slot so a shell that answers nothing is diagnosable.
pub fn ensure(d: *Desktop, id: u32) void {
    if (!buildinfo.smp) return; // single-core runs its commands inline (terminal.zig)
    g_desktop = d;
    if (sessionmod.commandWorker(id) != null) return;
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "cmd-{d}", .{id}) catch "cmd";
    const t = sched.spawn(name, entry) catch {
        var m: [64]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&m, "cmdworker: slot {d} has no worker (spawn failed)\n", .{id}) catch "cmdworker: spawn failed\n");
        return;
    };
    // The slot rides on the task itself, the way a session task carries its id
    // (console/session.zig): `exit_ctx` doubles as the START context, so two
    // concurrent opens cannot race a shared one-slot mailbox.
    t.exit_ctx = id;
    // Published BEFORE dispatch so the first command posted to this terminal
    // already has a task to wake. A wake that arrives before the worker has
    // blocked is not lost — the scheduler latches it (sched.block re-tests the
    // predicate rather than sleeping on a pending wake).
    sessionmod.setCommandWorker(id, t);
    sched.dispatch(t);
}

/// `sched.block` predicate: sleep until this slot's terminal has committed a
/// line nobody has claimed yet.
fn pending(id: u32) bool {
    return sessionmod.commandPending(id);
}

/// Commands the workers have completed, across every terminal — the liveness
/// signal a sleeping worker cannot give by burning CPU. A shell that answers
/// nothing is then one question: is this number still moving? The task list
/// (`ps`) says which worker it is stuck in.
var g_commands: u64 = 0;

/// A worker's body: sleep, run one command for this slot's terminal, repeat.
/// Never returns — see the module doc on permanence.
fn entry() void {
    const id: u32 = @intCast(sched.currentTask().?.exit_ctx);
    while (true) {
        sched.block(id, pending);
        const d = g_desktop orelse continue;
        if (lifecycle.runPendingCommandFor(d, id)) {
            debug.setNum(.ui, "worker.cmds", @atomicRmw(u64, &g_commands, .Add, 1, .monotonic) + 1);
        }
    }
}
