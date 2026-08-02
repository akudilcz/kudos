//! One terminal session: the line editor task behind a terminal window.
//!
//! The task owns NO rendering and no kernel state. It only:
//!   - pops keystrokes from its own key ring (filled by the system task),
//!   - edits its line buffer,
//!   - and pushes requests (echo / backspace / run_line) to its own req ring,
//!     which the system task drains and applies to the grid (and executes).
//!
//! Both rings belong to the SESSION, not to a core. The session task may be
//! scheduled on any processor and may move between processors while it runs
//! (KRN-009/011), so addressing its mailbox through "the core I am on" would send
//! a keystroke to whichever terminal happened to be running there. The rings stay
//! single-producer/single-consumer regardless: one system task fills `keys` and
//! one session task drains it, and vice versa for `req`.
//!
//! The Session lives in shared RAM so the system task can reach the line
//! buffer. Only the session's own task edits `ed` while it runs; the system
//! task touches it only while the editor task is parked on `busy` — reading
//! the committed line between a run_line request and its handling, reading and
//! GROWING it between a complete request and its handling (Tab completion
//! needs the terminal's cwd and the live VFS, which live on the system task's
//! side) — a natural handoff, no lock needed.

const std = @import("std");
const percpu = @import("../kernel/sched/percpu.zig");
const sched = @import("../kernel/sched/sched.zig");
const taskstat = @import("../kernel/sched/taskstat.zig");
const klog = @import("../kernel/debug/klog.zig");
const shell = @import("shell.zig");
const editline = @import("editline.zig");
const Ring = @import("ring").Ring;
const SpinLock = @import("../kernel/sync/spinlock.zig").SpinLock;
const counter = @import("../kernel/debug/counter.zig");
const sessionspace = @import("../kernel/memory/sessionspace.zig");
const timer = @import("../kernel/timer/timer.zig");
const cmdtoken = @import("cmdtoken.zig");

// Editor-event counters (per the diagnostics rails): a "the editor ignored my
// key" report becomes a one-run query — did the event reach the editor at all?
var cnt_recalls = counter.Counter{ .mod = .ui, .name = "sess.recalls" };
var cnt_commits = counter.Counter{ .mod = .ui, .name = "sess.commits" };
/// Recall arrived but there was nothing to recall (nothing committed yet) — a no-op
/// that must not be silent: "Up did nothing" has two very different causes.
var cnt_recall_empty = counter.Counter{ .mod = .ui, .name = "sess.recall_empty" };
const localcmd = @import("localcmd.zig");

/// A request from a session's line editor to the system task, which owns the
/// grid. The editor never touches the grid itself; every mutation is a message.
/// `complete` additionally asks the system task to Tab-complete the line
/// (against the terminal's cwd and the live VFS) while the editor is parked.
pub const ReqKind = enum(u8) { echo, backspace, run_line, complete };
pub const Request = struct {
    kind: ReqKind,
    /// For .echo: the typed character. For .run_line/.complete: unused (the
    /// line lives in the session's own editor, in shared RAM).
    ch: u8 = 0,
};

/// A keystroke delivered from the system task (which owns the keyboard) to the
/// focused terminal's session.
pub const Key = struct { ascii: u8 };

pub const REQ_RING_CAP = 256;
pub const KEY_RING_CAP = 256;

pub const Session = struct {
    /// Which session this is — the terminal's identity, shown in its title and
    /// prompt. NOT a core number: the task may run on any processor.
    id: u32,
    /// This session's mailbox. SPSC in both directions (see the module doc).
    req: Ring(Request, REQ_RING_CAP) = .{},
    keys: Ring(Key, KEY_RING_CAP) = .{},
    /// The line editor's pure core (line buffer + Up-arrow recall). Edited by
    /// this session's own task; the system task reaches it only during the
    /// parked run_line/complete handoffs (see the module doc).
    ed: editline.Editor = .{},
    /// busy: the editor sets it when it commits a line (run_line) or asks for
    /// completion, and parks until the request is served; the server clears it.
    /// This both blocks the editor from overwriting the line mid-handoff and
    /// gates the next prompt.
    busy: bool = false,
    /// The single-flight command hand-off (console/cmdtoken.zig): the system
    /// task posts a committed line (applyRequests), exactly ONE claimer wins
    /// it (the cmd-worker — the claim CONSUMES the token), and `running`
    /// defers a queued close while `shell.execute` is in flight — freeing the
    /// Terminal mid-command would leave the worker resuming on freed memory.
    cmd: cmdtoken.CmdToken = .{},
    /// alive: cleared when the terminal is torn down so the command worker stops
    /// touching its (about-to-be-freed) Terminal.
    alive: bool = true,
    /// task: the task running this session's line editor, or null once it has
    /// finished. Published by `run()` on entry so a keystroke or a teardown can
    /// wake it — the session blocks (off the run queue) when idle instead of
    /// busy-polling.
    ///
    /// NEVER read this field directly from outside: go through `wakeTask` /
    /// `cancelTask`, which hold `task_lock` across the read AND the use. A task
    /// that has exited is freed by the scheduler and its memory reissued, so a
    /// pointer loaded a moment earlier can name a different task — or free heap.
    /// The lock is what closes that window: the task clears this field from
    /// inside the same lock, and only then returns and becomes eligible to be
    /// freed, so a holder that reads non-null knows the task cannot exit before
    /// the lock is released.
    /// Set while this session's task is INSIDE a local command (commitLine's
    /// inline c.run — `prime`, `rt`, `run <app>`). The desktop defers a window
    /// close while it is set, exactly as `cmd_running` defers for worker
    /// commands: tearing the session down under a task still executing inside
    /// it would free the arena its stack lives in.
    local_running: bool = false,
    task_lock: SpinLock = .{},
    task: ?*sched.Task = null,
    /// Set by the task's exit hook at REAP — the first moment the task provably
    /// no longer touches its arena-backed stack. `release` waits on this before
    /// tearing down the session's address space and arena, so the slot (and the
    /// stack inside the arena) can never be reused under a task still dying.
    retired: bool = false,
};

// The session slots, in shared .bss. A slot is a SESSION, not a core: the count
// is the number of terminals that may be open at once, and it is sized from the
// core cap only because that is the machine's own scale.
pub const MAX_SESSIONS = percpu.MAX_CPUS;
var sessions: [MAX_SESSIONS]Session = undefined;
var in_use: [MAX_SESSIONS]bool = [_]bool{false} ** MAX_SESSIONS;
// Guards `in_use` claim/release: terminals are opened from two genuinely
// concurrent tasks (the system task via dock/hotkey, the command worker via
// the `term` command), and an unlocked lowest-free scan can hand the same slot
// to both — two Terminals sharing one Session.
var table_lock: SpinLock = .{};

/// Claim the lowest free session slot, or null when every one is taken. Called by
/// the system task when it opens a terminal.
pub fn claim() ?*Session {
    counter.register(&cnt_recalls); // idempotent — first session wins
    counter.register(&cnt_commits);
    counter.register(&cnt_recall_empty);
    counter.register(&cnt_req_drops);
    counter.register(&cnt_emit_stalls);
    const if_was = table_lock.acquireIrqSave();
    defer table_lock.releaseIrqRestore(if_was);
    for (&in_use, 0..) |*used, i| {
        if (used.*) continue;
        used.* = true;
        sessions[i] = .{ .id = @intCast(i) };
        return &sessions[i];
    }
    return null;
}

/// How long release() waits for the session task to be reaped. Task exit is
/// microseconds (cancel → wake → return → reap on the next reschedule); the
/// budget only expires when the task can never exit — its core parked on a
/// kernel fault with the task's stack unrecoverable.
const RELEASE_WAIT_BUDGET_MS: u64 = 1000;

/// Sessions whose slot was deliberately leaked because their task was never
/// reaped (its core died) — the arena cannot be freed under a stack of unknown
/// state, and a leaked 24 MiB beats freeing memory a corpse may still name.
var cnt_leaked_sessions = counter.Counter{ .mod = .ui, .name = "sess.leaked" };
var cnt_leaked_registered = false;

/// Return a session's slot once its task has exited: wait (bounded) for the
/// reaper's retirement signal, tear down the session's address space and arena
/// (MEM-007), then free the slot for the next `term`. If the task is NEVER
/// reaped — its core took a kernel fault and parked with the task aboard — the
/// slot and arena are deliberately leaked (counted, logged): the machine keeps
/// running minus one session, instead of panicking or freeing an arena whose
/// stack a corpse still references.
pub fn release(sess: *Session) void {
    const deadline = timer.millis() + RELEASE_WAIT_BUDGET_MS;
    while (!@atomicLoad(bool, &sess.retired, .acquire)) {
        if (timer.millis() >= deadline) {
            if (!cnt_leaked_registered) {
                cnt_leaked_registered = true;
                counter.register(&cnt_leaked_sessions);
            }
            cnt_leaked_sessions.inc();
            klog.puts("session: task never reaped (core dead?) — slot + arena leaked\n");
            return; // in_use stays set: the slot is never reissued
        }
        // A zombie is reaped on its core's next reschedule; an idle core's next
        // reschedule is a timer tick away. Prod every core so the wait resolves
        // in microseconds, not a quantum — the desktop is the caller, and a
        // quantum here is a dropped frame (PERF-003).
        sched.rescheduleAll();
        sched.yield();
    }
    sessionspace.destroy(sess.id);
    const if_was = table_lock.acquireIrqSave();
    in_use[sess.id] = false;
    table_lock.releaseIrqRestore(if_was);
}

/// Open a session: claim a slot and start its line-editor task, which the
/// scheduler places on whichever core is free (KRN-010). Returns null when every
/// slot is taken or the task could not be created — the caller reports it; there
/// is no fallback that quietly shares a slot between two terminals.
pub fn open() ?*Session {
    const sess = claim() orelse return null;
    // The session's own address space and arena first (MEM-002): the task's
    // stack lives in the arena, behind the guard page (MEM-010).
    _ = sessionspace.create(sess.id) catch {
        unclaim(sess.id);
        return null;
    };
    const t = sched.spawnStacked("term", taskEntry, sessionspace.taskStack(sess.id)) catch {
        sessionspace.destroy(sess.id);
        unclaim(sess.id);
        return null;
    };
    // The reaper's exit hook is what retires the slot (see Session.retired);
    // installed before dispatch so no exit path can miss it. `exit_ctx` doubles
    // as the START context: the task reads its session id from its own Task,
    // never from a shared one-slot mailbox two concurrent opens could race.
    t.exit_hook = &taskReaped;
    t.exit_ctx = sess.id;
    sched.setAddressSpace(t, sessionspace.cr3Of(sess.id));
    sched.dispatch(t);
    return sess;
}

/// Give a just-claimed slot back on an open() failure path — the task never
/// existed, so there is no retirement to wait for.
fn unclaim(id: u32) void {
    const if_was = table_lock.acquireIrqSave();
    in_use[id] = false;
    table_lock.releaseIrqRestore(if_was);
}

/// Abort a session whose window never materialized (a late spawnTerm failure:
/// window cap, OOM): the task IS live — signal the close exactly as a window
/// close would, then release, which waits for it to exit and be reaped.
pub fn abort(sess: *Session) void {
    @atomicStore(bool, &sess.alive, false, .release);
    cancelTask(sess);
    release(sess);
}

/// The session task's exit hook, fired by the reaper (any exit path: entry
/// returned, or killed by a fault — MEM-006). Clears the published task pointer
/// if the task did not get to (a fault death skips run()'s exit path) and
/// signals `release` that the stack is dead. Runs inside schedule() with
/// interrupts off — quick and lock-light by contract.
fn taskReaped(ctx: u64) void {
    const sess = &sessions[@as(u32, @intCast(ctx))];
    {
        const if_was = sess.task_lock.acquireIrqSave();
        defer sess.task_lock.releaseIrqRestore(if_was);
        sess.task = null;
    }
    @atomicStore(bool, &sess.retired, true, .release);
}

/// The id the next `open()` would claim, or null when every slot is taken. The
/// verification harness asks BEFORE opening, so it has a stable handle on the
/// terminal it is about to create.
pub fn nextFreeId() ?u32 {
    const if_was = table_lock.acquireIrqSave();
    defer table_lock.releaseIrqRestore(if_was);
    for (in_use, 0..) |used, i| {
        if (!used) return @intCast(i);
    }
    return null;
}

/// The session task's cumulative on-CPU milliseconds (KRN-005), or null when
/// the session has no live task. Read under `task_lock` so the task cannot exit
/// and be freed between the pointer load and the read.
pub fn taskCpuMs(id: u32) ?u64 {
    if (id >= MAX_SESSIONS) return null;
    const sess = &sessions[id];
    const if_was = sess.task_lock.acquireIrqSave();
    defer sess.task_lock.releaseIrqRestore(if_was);
    const t = sess.task orelse return null;
    return taskstat.taskCpuMs(t);
}

/// Whether session `id` is open — what the diagnostics ask.
pub fn isOpen(id: u32) bool {
    return id < MAX_SESSIONS and in_use[id];
}

/// Task entry: the session id rides on the task itself (`exit_ctx`, set by
/// open() before dispatch), so two concurrent opens cannot race a shared cell.
pub fn taskEntry() void {
    const sess = &sessions[@as(u32, @intCast(sched.currentTask().?.exit_ctx))];
    run(sess);
}

/// The body of a session task. Returns when the terminal is closed (`sess.alive`
/// cleared by the teardown), at which point the task exits and is reaped — and
/// its slot is released, so the next `term` can take it.
/// `sess` is this session's state, shared with the system task's Terminal.
pub fn run(sess: *Session) void {
    sched.clearCancel();
    // Publish our task so a keystroke or teardown can wake us, under the lock
    // that makes the pointer safe for anyone else to use.
    const me = sched.currentTask().?;
    {
        const if_was = sess.task_lock.acquireIrqSave();
        defer sess.task_lock.releaseIrqRestore(if_was);
        sess.task = me;
    }
    while (@atomicLoad(bool, &sess.alive, .acquire)) {
        // Drain any keystrokes routed to us.
        while (sess.keys.pop()) |k| handleKey(sess, k.ascii);
        // Nothing to do: BLOCK until a key arrives or we are torn down (the
        // producer pushes the payload, then wakes us). Our core halts if it has
        // nothing else to run, so an idle terminal costs nothing. `sessionReady`
        // is re-checked inside block()'s critical section, which is what closes
        // the lost-wakeup window.
        sched.block(sess, sessionReady);
    }
    // Clear the published task on exit, so nothing wakes a task that is about to
    // return and be reaped. Under the lock: a waker holding it right now has
    // already read our pointer and is using it, and must finish first.
    {
        const if_was = sess.task_lock.acquireIrqSave();
        defer sess.task_lock.releaseIrqRestore(if_was);
        sess.task = null;
    }
}

/// Wake this session's editor task, if it is still running. The one sanctioned
/// way to reach the task from outside — see `Session.task` for why the lock is
/// held across the use and not merely the read.
pub fn wakeTask(sess: *Session) void {
    const if_was = sess.task_lock.acquireIrqSave();
    defer sess.task_lock.releaseIrqRestore(if_was);
    if (sess.task) |t| sched.wake(t);
}

/// Ask this session's editor task to stop and wake it so it notices promptly.
/// Same locking contract as `wakeTask`.
pub fn cancelTask(sess: *Session) void {
    const if_was = sess.task_lock.acquireIrqSave();
    defer sess.task_lock.releaseIrqRestore(if_was);
    if (sess.task) |t| sched.requestCancel(t);
}

/// block() predicate: resume when a keystroke is waiting OR the terminal was torn
/// down (so the run loop re-checks `alive` and returns).
fn sessionReady(sess: *Session) bool {
    return !sess.keys.isEmpty() or !@atomicLoad(bool, &sess.alive, .acquire);
}

/// editline.Screen echo bound to the req ring: the editor owns no rendering,
/// so every visible effect travels to the system task as a message.
fn scrEcho(ctx: ?*anyopaque, ch: u8) void {
    const sess: *Session = @ptrCast(@alignCast(ctx.?));
    if (!sess.req.push(.{ .kind = .echo, .ch = ch })) cnt_req_drops.inc();
}
/// editline.Screen erase bound to the req ring.
fn scrErase(ctx: ?*anyopaque) void {
    const sess: *Session = @ptrCast(@alignCast(ctx.?));
    if (!sess.req.push(.{ .kind = .backspace })) cnt_req_drops.inc();
}
/// This session's editline.Screen: echo/erase as req-ring messages.
fn screen(sess: *Session) editline.Screen {
    return .{ .ctx = sess, .echoFn = scrEcho, .eraseFn = scrErase };
}

/// Apply one keystroke to this session's line editor (editline owns the edit
/// semantics, shared with the single-core Terminal) and serve what the editor
/// asks of its host: commit runs the line, complete hands it to the system
/// task, recalls are counted. Runs on the session's own task.
fn handleKey(sess: *Session, ascii: u8) void {
    switch (sess.ed.key(ascii, screen(sess))) {
        .none => {},
        .recalled => cnt_recalls.inc(),
        .recall_empty => {
            cnt_recalls.inc();
            cnt_recall_empty.inc();
        },
        .commit => commitLine(sess),
        .complete => requestComplete(sess),
    }
}

/// Tab: hand the line to the system task for completion. The editor task owns
/// neither the terminal's cwd nor the VFS — both live with the Terminal on the
/// system task's side — so completion is a parked handoff exactly like
/// run_line: publish busy, post the request, and block until the system task
/// has grown the line (echoing the appended bytes) and cleared busy.
fn requestComplete(sess: *Session) void {
    @atomicStore(bool, &sess.busy, true, .release);
    if (!sess.req.push(.{ .kind = .complete })) {
        // A full ring loses the Tab (counted, never silent) — un-park, or the
        // editor would wait on a request nobody received.
        cnt_req_drops.inc();
        @atomicStore(bool, &sess.busy, false, .release);
        return;
    }
    sched.block(@intFromPtr(sess), proxyDone);
}

/// Run the committed line. A local command (exact name match — no prefix
/// matching, so `primer` is not `prime`) runs inline on this task; anything else
/// is proxied to the command worker, which owns the grid + kernel state.
fn commitLine(sess: *Session) void {
    cnt_commits.inc();
    const parsed = shell.splitCommand(sess.ed.text());
    if (localcmd.lookup(parsed.cmd)) |c| {
        // A local command runs inline on THIS task, output via the req ring.
        // Exact-match only (no prefix matching, so `primer` is not `prime`);
        // single source of truth shared with the single-core terminal. out_ctx
        // lives HERE on the stack, never a global — see sessionOut: a shared
        // OutCtx would cross-wire the req rings of two sessions.
        var out_ctx: OutCtx = undefined;
        @atomicStore(bool, &sess.local_running, true, .release);
        defer @atomicStore(bool, &sess.local_running, false, .release);
        emit(sess, '\n');
        c.run(sessionOut(&out_ctx, sess), parsed.args);
        sess.ed.len = 0;
        emitPrompt(sess);
        return;
    }
    // Everything else: ask the command worker to run it. It reads sess.line; we
    // park on busy until it's done. Publish busy (release) BEFORE the request so
    // the worker cannot clear it before we set it (the worker clears it with
    // release). The wait ALSO exits when the session dies: if the terminal is
    // closed after the line was committed but before the worker ran it, the
    // worker will never scan this terminal again and `busy` would never clear —
    // this task would wait forever and its session slot could never be reused.
    @atomicStore(bool, &sess.busy, true, .release);
    _ = sess.req.push(.{ .kind = .run_line });
    // PARK, don't spin: a yield loop would peg whatever core we are on at 100%
    // for the whole proxied command and (never pumping the drain) could trip the
    // deadman into a spurious wedge report. block() takes us off the run queue
    // so the core can run something else or halt; the worker wakes us when it
    // clears busy, and signalClose's cancel-wake covers a window close racing
    // the command.
    sched.block(@intFromPtr(sess), proxyDone);
    if (!@atomicLoad(bool, &sess.alive, .acquire)) return;
    sess.ed.len = 0;
}

/// `block` predicate for the proxied-command wait: done when core 0's worker
/// cleared `busy`, or the session died (a close racing the command).
fn proxyDone(ctx: u64) bool {
    const sess: *Session = @ptrFromInt(ctx);
    if (!@atomicLoad(bool, &sess.alive, .acquire)) return true;
    return !@atomicLoad(bool, &sess.busy, .acquire);
}

// --- local-command output sink (localcmd.Out backed by the req ring) -------

// The context a session's localcmd.Out carries: this core's percpu (to ring) and
// the session (to check liveness). Lives in `commitLine`'s frame, which outlives
// the synchronous c.run() call.
const OutCtx = struct { sess: *Session };

/// localcmd.Out putFn: push one output char onto this core's req ring for core 0
/// to render (never touches the grid directly — this task owns no rendering).
fn outPut(ctx: *anyopaque, ch: u8) void {
    const c: *OutCtx = @ptrCast(@alignCast(ctx));
    emit(c.sess, ch);
}
/// localcmd.Out aliveFn: whether the terminal is still open, so a long-running
/// local command bails out promptly once its window is torn down.
fn outAlive(ctx: *anyopaque) bool {
    const c: *OutCtx = @ptrCast(@alignCast(ctx));
    return @atomicLoad(bool, &c.sess.alive, .acquire);
}

/// Build a localcmd.Out over caller-provided OutCtx storage. The storage MUST live
/// on the calling task's stack (commitLine's frame), NOT a module global: local
/// commands run inline on their own core, so N cores can be in `c.run` at once. A
/// shared global OutCtx would let one core's outPut push into ANOTHER core's req
/// ring — breaking the req-ring SPSC invariant (only core N produces core N's ring)
/// that the whole mailbox rests on. Per-core stack storage keeps each Out private.
fn sessionOut(storage: *OutCtx, sess: *Session) localcmd.Out {
    storage.* = .{ .sess = sess };
    return .{ .ctx = storage, .putFn = outPut, .aliveFn = outAlive };
}

// --- ring output helpers (push text to the desktop's grid via the req ring) --

/// Requests dropped because the session died (its window closed) while output
/// was still being produced, or a ring overflowed — never silent.
var cnt_req_drops = counter.Counter{ .mod = .ui, .name = "sess.req_drops" };
var cnt_emit_stalls = counter.Counter{ .mod = .ui, .name = "sess.emit_stalls" };

/// How long emit() may wait for the system task to drain a full req ring before
/// declaring the drain dead. The drain runs every frame, so a healthy ring
/// clears in milliseconds; a full second means nothing is draining — the
/// window is gone or the pump stopped — and no amount of waiting brings it
/// back. Clocked by timer.millis (TSC once calibrated), which no stalled core
/// can freeze.
const EMIT_DRAIN_BUDGET_MS: u64 = 1_000;

/// Push one output char to the desktop's grid via this session's req ring,
/// yielding while the ring is full so no output is dropped — the system task
/// drains it every frame. The wait is bounded, like every wait in the tree: a
/// DEAD session (nothing will ever drain a closed terminal's ring) drops the
/// char at once, and a drain silent past EMIT_DRAIN_BUDGET_MS drops it too —
/// both counted, never silent. The budget is what makes it impossible for one
/// undrained ring to pin this task forever: the command finishes, its flags
/// clear, and the deferred close this task was blocking can then resolve.
fn emit(sess: *Session, ch: u8) void {
    const deadline_ms = timer.millis() + EMIT_DRAIN_BUDGET_MS;
    while (!sess.req.push(.{ .kind = .echo, .ch = ch })) {
        if (!@atomicLoad(bool, &sess.alive, .acquire)) {
            cnt_req_drops.inc();
            return;
        }
        if (timer.millis() >= deadline_ms) {
            cnt_emit_stalls.inc();
            return;
        }
        sched.yield();
    }
}

/// Emit the shell prompt `#<id>> ` for this session through the req ring.
fn emitPrompt(sess: *Session) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "#{d}> ", .{sess.id}) catch "#?> ";
    for (s) |c| emit(sess, c);
}
