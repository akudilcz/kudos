//! App spawning and window lifecycle for the desktop: opening app windows
//! (cascade geometry, per-kind sizes, the terminal's core binding), the
//! console contract handed to each terminal, and the close path (queued
//! teardown, deferred while a command is in flight). One concern of the
//! Desktop: every function takes the Desktop and mutates its state under the
//! Desktop's own locks.

const std = @import("std");
const buildinfo = @import("buildinfo");
const framebuffer = @import("../screen/framebuffer.zig");
const smp = @import("../../kernel/smp/smp.zig");
const sessionmod = @import("../../console/session.zig");
const console_mod = @import("../../console/console.zig");
const wm_mod = @import("../wm/wm.zig");
const window_mod = @import("../wm/window.zig");
const Window = window_mod.Window;
const app = @import("../../apps/app.zig");
const App = app.App;
const Kind = app.Kind;
const Terminal = @import("../../apps/terminal.zig").Terminal;
const System = @import("../../apps/system.zig").System;
const modelview = @import("../../apps/modelview.zig");
const ModelView = modelview.ModelView;
const Clock = @import("../../apps/clock.zig").Clock;
const Calculator = @import("../../apps/calculator.zig").Calculator;
const VmApp = @import("../../apps/vm.zig").Vm;
const virt = @import("../../kernel/virt/virt.zig");
const ivirt = @import("ivirt");
const png = @import("modelcache").png;
const debug = @import("../../kernel/debug/debug.zig");
const desktop_mod = @import("desktop.zig");
const Desktop = desktop_mod.Desktop;
const render = @import("render.zig");

const TERM_W: usize = 560;
const TERM_H: usize = 340;
const SYS_W: usize = 640;
const SYS_H: usize = 460;
const CLOCK_W: usize = 300;
const CLOCK_H: usize = 320;
const CALC_W: usize = 520;
const CALC_H: usize = 420;
const MODEL_W: usize = 640; // `show <file>` model windows (cascaded)
const MODEL_H: usize = 520;
const CASCADE_ORIGIN: usize = 60; // origin (x and y) of the first cascaded window
const CASCADE_STEP: usize = 28; // diagonal offset per successive cascaded window

/// The kernel command line handed to every guest — owned by the hypervisor,
/// which is where the guest's device map is decided.
const GUEST_CMDLINE = virt.STAGED_CMDLINE;

/// The desktop's services as the console contract (console/console.zig) sees
/// them — handed to each Terminal at spawn, so shell commands reach the
/// desktop through the contract instead of the console group importing
/// upward into ui/. Each implementation casts its opaque context back.
fn consoleDesktop(d: *Desktop) console_mod.Desktop {
    return .{
        .ctx = d,
        .spawnAppFn = conSpawnApp,
        .spawnModelFn = conSpawnModel,
        .setBackgroundFn = conSetBackground,
        .closeFn = conClose,
    };
}
fn conSpawnApp(ctx: *anyopaque, kind: console_mod.AppKind) anyerror!void {
    const d: *Desktop = @ptrCast(@alignCast(ctx));
    return spawnApp(d, kind);
}
fn conSpawnModel(ctx: *anyopaque, path: []const u8, maximized: bool) anyerror!void {
    const d: *Desktop = @ptrCast(@alignCast(ctx));
    return spawnModel(d, path, maximized);
}
fn conSetBackground(ctx: *anyopaque, img: png.Image) bool {
    const d: *Desktop = @ptrCast(@alignCast(ctx));
    return render.setBackground(d, img);
}
fn conClose(ctx: *anyopaque, win: *anyopaque) void {
    const d: *Desktop = @ptrCast(@alignCast(ctx));
    requestClose(d, @ptrCast(@alignCast(win)));
}

/// Cascade position for the n-th spawned window of size `w`x`h`, clamped so
/// the *whole* window stays on screen. The diagonal step
/// (`CASCADE_STEP` per window) walks down-right from `CASCADE_ORIGIN`; once a
/// step would push the far edge past the screen, the cascade wraps back to the
/// origin (modulo the available travel) instead of marching off-screen.
fn cascadePos(n: u32, w: usize, h: usize) struct { i32, i32 } {
    const sw = framebuffer.width();
    const sh = framebuffer.height();
    // Maximum origin that still fits the window fully on screen. A window
    // wider/taller than the screen pins to 0 (the min-size invariant in
    // window.create still guarantees a valid surface).
    const max_x: usize = if (sw > w) sw - w else 0;
    const max_y: usize = if (sh > h) sh - h else 0;
    // Travel available for the cascade past the origin, in whole steps.
    const travel_x: usize = if (max_x > CASCADE_ORIGIN) max_x - CASCADE_ORIGIN else 0;
    const travel_y: usize = if (max_y > CASCADE_ORIGIN) max_y - CASCADE_ORIGIN else 0;
    const steps_x: usize = travel_x / CASCADE_STEP + 1;
    const steps_y: usize = travel_y / CASCADE_STEP + 1;
    const x: usize = @min(CASCADE_ORIGIN + (n % steps_x) * CASCADE_STEP, max_x);
    const y: usize = @min(CASCADE_ORIGIN + (n % steps_y) * CASCADE_STEP, max_y);
    return .{ @intCast(x), @intCast(y) };
}

/// The outer size a freshly spawned window of `kind` opens at.
fn kindSize(kind: Kind) struct { w: usize, h: usize } {
    return switch (kind) {
        .term => .{ .w = TERM_W, .h = TERM_H },
        .system => .{ .w = SYS_W, .h = SYS_H },
        .clock => .{ .w = CLOCK_W, .h = CLOCK_H },
        .calc => .{ .w = CALC_W, .h = CALC_H },
        .vm => .{ .w = TERM_W, .h = TERM_H }, // serial-console sized; the guest scanout scales to fit
    };
}

/// Open one terminal window at the given geometry — the one owner of the
/// window → session → Terminal sequence (spawnApp's .term arm, spawnAgent,
/// boot_layout.spawnBootLayout). `title` is heap-owned and passes to the window;
/// `ai_mode` makes every committed line an agent turn. Returns the window so the
/// boot layout can refocus it.
///
/// The terminal is bound to a SESSION, not to a core. Opening one starts the
/// session's editor task, which the scheduler places on whichever processor is
/// free and may move later (KRN-009/011); this function never names a core.
///
/// A null `title` means "name it after the session" — `term #<id>`, which can
/// only be formatted once the session is claimed, so this function owns it. Pass
/// a title for a window that is named after its purpose instead (the agent).
pub fn spawnTerm(d: *Desktop, x: i32, y: i32, w: usize, h: usize, title: ?[]const u8, ai_mode: bool) !*Window {
    // SMP: claim a session and start its editor task first — it is the step that
    // can legitimately run out (every slot in use), and failing here costs
    // nothing, whereas failing after the window is up has to unwind it.
    const sess: ?*sessionmod.Session = if (buildinfo.smp) (sessionmod.open() orelse return error.NoFreeSessions) else null;
    // On a later failure (window cap, OOM) the session's editor TASK is already
    // live — abort signals the close and cancels it before releasing, exactly
    // as a window close would; a bare release would wait on a task that was
    // never told to exit.
    errdefer if (sess) |sp| sessionmod.abort(sp);
    const id: u32 = if (sess) |sp| sp.id else 0;

    const owned_title = title orelse try std.fmt.allocPrint(d.a, "term #{d}", .{id});
    errdefer if (title == null) d.a.free(owned_title);

    const win = try addWindowLocked(d, x, y, w, h, owned_title);
    // If Terminal.create or apps.append below fails, undo the window so
    // we don't leak a focused, app-less window that eats keystrokes.
    errdefer destroyWindow(d, win);

    const t = try Terminal.create(d.a, win, consoleDesktop(d), id, sess, ai_mode);
    errdefer t.destroy(d.a);
    try appendApp(d, .{ .term = t });
    return win;
}

/// Open a new app window of the given kind, cascaded.
pub fn spawnApp(d: *Desktop, kind: Kind) !void {
    const n = d.spawn_count;
    d.spawn_count += 1;
    const sz = kindSize(kind);
    const x, const y = cascadePos(n, sz.w, sz.h);
    switch (kind) {
        .term => _ = try spawnTerm(d, x, y, sz.w, sz.h, null, false),
        .system => {
            // Titles are heap-owned so close-time teardown frees them
            // uniformly.
            const title = try std.fmt.allocPrint(d.a, "system", .{});
            const win = try addWindowLocked(d, x, y, sz.w, sz.h, title);
            errdefer destroyWindow(d, win);
            const s = try System.create(d.a, win);
            errdefer d.a.destroy(s);
            try appendApp(d, .{ .system = s });
        },
        .clock => {
            const title = try std.fmt.allocPrint(d.a, "clock", .{});
            const win = try addWindowLocked(d, x, y, sz.w, sz.h, title);
            errdefer destroyWindow(d, win);
            const c = try Clock.create(d.a, win);
            errdefer d.a.destroy(c);
            try appendApp(d, .{ .clock = c });
        },
        .calc => {
            const title = try std.fmt.allocPrint(d.a, "calculator", .{});
            const win = try addWindowLocked(d, x, y, sz.w, sz.h, title);
            errdefer destroyWindow(d, win);
            const c = try Calculator.create(d.a, win);
            errdefer d.a.destroy(c);
            try appendApp(d, .{ .calc = c });
        },
        .vm => {
            // Boot the guest FIRST: it is the part that can legitimately fail
            // (no VT-x, no staged image, no free core, no slot), and failing
            // before any window exists means nothing to unwind and a clear error
            // for the caller to report.
            const id = try virt.bootStaged(virt.stagedRamBytes(), GUEST_CMDLINE);
            errdefer virt.windowClosed(id); // no window will own it — give it back
            try spawnVmWindow(d, id);
        },
    }
}

/// Open the console window onto guest slot `id` — a guest that already exists
/// (spawnApp's staged boot, or a network image boot the hypervisor claimed
/// first, VIRT-019: its window opens on `.fetching` and narrates the download
/// through the lifecycle state, VIRT-010).
pub fn spawnVmWindow(d: *Desktop, id: ivirt.Id) !void {
    const n = d.spawn_count;
    d.spawn_count += 1;
    const sz = kindSize(.vm);
    const x, const y = cascadePos(n, sz.w, sz.h);
    // The window is opened before the guest's vCPU task has necessarily been
    // placed, so its core may not be known yet — the status strip inside the
    // window reports it once it is. The title names the guest, which is stable.
    const title = try std.fmt.allocPrint(d.a, "linux #{d}", .{id});
    const win = try addWindowLocked(d, x, y, sz.w, sz.h, title);
    errdefer destroyWindow(d, win);
    const v = try VmApp.create(d.a, win, id, virt.guestCore(id));
    errdefer d.a.destroy(v);
    try appendApp(d, .{ .vm = v });
}

/// Open the dedicated AI agent window (spec AGT-002; F10). Structurally a
/// terminal — same core binding, SMP session, render and close-defer path —
/// but created in ai_mode, so every committed line is a turn for the on-demand
/// openclaw agent (AGT-001) rather than a shell command.
pub fn spawnAgent(d: *Desktop) !void {
    const n = d.spawn_count;
    d.spawn_count += 1;
    const sz = kindSize(.term);
    const x, const y = cascadePos(n, sz.w, sz.h);
    const title = try std.fmt.allocPrint(d.a, "AI Agent", .{});
    errdefer d.a.free(title);
    _ = try spawnTerm(d, x, y, sz.w, sz.h, title, true);
}

/// Raise and focus the most recently opened visible window of `kind`, if
/// any — the dock tile's reveal path for an app that is already running.
pub fn focusRunning(d: *Desktop, kind: Kind) bool {
    var i: usize = d.apps.items.len;
    while (i > 0) {
        i -= 1;
        const a2 = d.apps.items[i];
        if (a2.kind() == kind and !a2.window().minimized) {
            d.wm.focus(a2.window());
            return true;
        }
    }
    return false;
}

/// Restore the most recently opened minimised window of `kind`, if any.
pub fn restoreMinimised(d: *Desktop, kind: Kind) bool {
    var i: usize = d.apps.items.len;
    while (i > 0) {
        i -= 1;
        const a2 = d.apps.items[i];
        if (a2.kind() == kind and a2.window().minimized) {
            d.wm.unminimise(a2.window());
            return true;
        }
    }
    return false;
}

/// Open a model-viewer window on the ABSOLUTE VFS path `name` (vfs.zig;
/// `show PATH` resolved it), cascaded like spawnApp; `maximized` opens
/// it maximised. The window title is the path's file name.
pub fn spawnModel(d: *Desktop, name: []const u8, maximized: bool) !void {
    // `show`ing a model whose window is minimised restores it (the model
    // has no dock tile, so re-showing is its way back).
    for (d.apps.items) |a2| {
        if (a2 == .model and a2.window().minimized and std.mem.eql(u8, a2.model.name, name)) {
            d.wm.unminimise(a2.window());
            return;
        }
    }
    const n = d.spawn_count;
    d.spawn_count += 1;
    const x, const y = cascadePos(n, MODEL_W, MODEL_H);
    const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
    const title = try std.fmt.allocPrint(d.a, "{s}", .{base});
    const win = try addWindowLocked(d, x, y, MODEL_W, MODEL_H, title);
    errdefer destroyWindow(d, win);
    const mv = try ModelView.create(d.a, win, name);
    errdefer {
        mv.deinit();
        d.a.destroy(mv);
    }
    try appendApp(d, .{ .model = mv });
    if (maximized) d.toggleMaximise(win);
}

/// Append an app entry under the structure lock. Capacity was reserved at
/// create so this never reallocates; the lock orders the length bump against
/// a preempting core-0 task mid-iteration (see structure_lock).
pub fn appendApp(d: *Desktop, entry: App) !void {
    if (d.apps.items.len >= wm_mod.MAX_WINDOWS) return error.OutOfMemory;
    const if_was = d.structure_lock.acquireIrqSave();
    defer d.structure_lock.releaseIrqRestore(if_was);
    d.apps.appendAssumeCapacity(entry);
}

/// wm.addWindow under the structure lock — the window list has the same
/// two-task append/iterate exposure as the app list. Takes ownership of the
/// heap-allocated `title` whether it succeeds (the window frees it at close)
/// or fails (freed here), so no spawn path can leak it.
pub fn addWindowLocked(d: *Desktop, x: i32, y: i32, w: usize, h: usize, title: []const u8) !*Window {
    errdefer d.a.free(title); // owns the heap title from this call on
    const if_was = d.structure_lock.acquireIrqSave();
    defer d.structure_lock.releaseIrqRestore(if_was);
    return d.wm.addWindow(x, y, w, h, title);
}

/// spawnApp's errdefer when a later step (Terminal.create, apps.append) fails:
/// without it a half-constructed spawn leaves a focused, app-less window that
/// leaks and swallows keystrokes. It does NOT free any app struct (none was
/// registered yet) — that is what distinguishes it from the full closeWindow.
pub fn destroyWindow(d: *Desktop, win: *Window) void {
    if (d.wm.focused == win) d.wm.focused = null;
    {
        const if_was = d.structure_lock.acquireIrqSave();
        defer d.structure_lock.releaseIrqRestore(if_was);
        d.wm.removeWindow(win);
    }
    if (d.wm.topmost()) |t| d.wm.focus(t);
    d.a.free(win.title);
    d.a.destroy(win);
    d.wm.markFull();
}

/// Queue a window for close. Teardown is deferred to the next `tick` so the
/// window is not freed while code is still running inside it.
/// Deduped: requesting the same window twice (e.g. a close-box click and an
/// `exit` in the same frame) enqueues it once, so it is torn down once. The
/// queue cannot overflow — its cap exceeds the live window count — but if it
/// somehow filled, the request is dropped rather than overwriting a pending one.
pub fn requestClose(d: *Desktop, win: *Window) void {
    debug.setNum(.ui, "wm.close_req", win.id);
    // Under the structure lock: the command worker queues closes (`exit`)
    // while the system task drains the same queue in tick().
    const if_was = d.structure_lock.acquireIrqSave();
    defer d.structure_lock.releaseIrqRestore(if_was);
    for (d.pending_close[0..d.pending_close_len]) |w| {
        if (w == win) return; // already queued
    }
    if (d.pending_close_len >= d.pending_close.len) {
        // Cap exceeded — cannot happen with the cap sized above the live
        // window count, but a dropped close must never be silent.
        debug.setNum(.ui, "wm.close_dropped", win.id);
        return;
    }
    d.pending_close[d.pending_close_len] = win;
    d.pending_close_len += 1;
}

/// Tear down a window and its app, freeing every allocation and removing it
/// from both registries. Order matters: dangling compositor pointers are
/// cleared before any free, and the new focus is chosen while `win` is still
/// alive.
pub fn closeWindow(d: *Desktop, win: *Window) void {
    // Drop a pending resize referencing this window — a freed window must
    // not be resized next frame.
    if (d.pending_resize) |req| {
        if (req.win == win) d.pending_resize = null;
    }
    // 1) Find the app for this window; capture BY VALUE before removal.
    var idx: ?usize = null;
    for (d.apps.items, 0..) |a, i| {
        if (a.window() == win) {
            idx = i;
            break;
        }
    }
    const i = idx orelse {
        // No app owns this window: it was already closed (double-request) —
        // or a real close was about to vanish. Either way, say so.
        debug.setNum(.ui, "wm.close_orphan", win.id);
        return;
    };
    const a = d.apps.items[i];

    // 1a+3) Deferral check and removal are ONE critical section under the
    // structure lock: the command worker CLAIMS a terminal (sets cmd_running)
    // under this same lock before running its command, so checking the flags
    // and removing the window atomically is what closes the window where the
    // worker claims a terminal we are in the middle of freeing. A terminal
    // whose worker command OR local command (prime / rt / run — they execute
    // on the session task, whose stack lives in the arena the teardown frees)
    // is in flight is deferred: signal the close — alive=false + cancel, so
    // the command observes it and unwinds — and re-queue for a later tick.
    {
        const if_was = d.structure_lock.acquireIrqSave();
        if (a == .term and (a.term.commandRunning() or a.term.commandPending() or a.term.localRunning())) {
            d.structure_lock.releaseIrqRestore(if_was);
            debug.setNum(.ui, "wm.close_deferred", win.id);
            a.term.signalClose();
            requestClose(d, win);
            return;
        }
        // 2) Clear the focus ref before any free (removeWindow below clears the
        // drag/resize refs; step 4 re-picks `focused`).
        if (d.wm.focused == win) d.wm.focused = null;
        _ = d.apps.swapRemove(i);
        d.wm.removeWindow(win);
        d.structure_lock.releaseIrqRestore(if_was);
    }

    // 4) Refocus the new front-most window (win is still alive here).
    if (d.wm.topmost()) |t| d.wm.focus(t);

    // 5) Free app-specific buffers + the app struct.
    switch (a) {
        .term => |t| {
            // Release this terminal's core (SMP) so the next `term` reuses the
            // lowest free core; the Terminal owns the session-teardown plumbing.
            t.shutdown();
            t.destroy(d.a);
        },
        .system => |s| d.a.destroy(s),
        .clock => |c| d.a.destroy(c),
        .calc => |c| d.a.destroy(c),
        .model => |mv| {
            // Return the mesh's GL objects to the desktop context before the
            // CPU-side teardown, so a closed window's VRAM is reusable now.
            // The deferred frame may still be fetching from them on the GPU —
            // complete it first, or the freed extents get reused mid-flight.
            render.completeOpenFrame(d);
            if (d.gles_comp) |*gc| mv.deinitGl(&gc.gctx);
            mv.deinit();
            d.a.destroy(mv);
        },
        .vm => |v| {
            // Complete any deferred frame before freeing the scanout texture —
            // the GPU may still be sampling it — then hand the guest back.
            // windowClosed asks it to stop and releases the window's hold on its
            // slot; the guest's own core frees its memory and releases the other
            // hold, so this returns immediately and frees nothing the guest owns.
            render.completeOpenFrame(d);
            if (d.gles_comp) |*gc| v.deinitGl(&gc.gctx);
            virt.windowClosed(v.id);
            d.a.destroy(v);
        },
    }

    // 6) Free the window: heap-owned title + struct (a window owns no pixels).
    d.a.free(win.title);
    d.a.destroy(win);

    // 7) Repaint the vacated region (the frame draws only listed windows).
    d.wm.markFull();
}

/// Focus terminal `id` (no-op if none). Used by the scripted verification
/// harness (src/console/verifyscript.zig) to route a command — e.g. `ps` — to an
/// idle terminal while another is pegged.
pub fn focusTermId(d: *Desktop, id: u32) void {
    for (d.apps.items) |a| {
        if (a == .term and a.term.id == id) {
            d.wm.focus(a.window());
            return;
        }
    }
}

/// Close the VM window showing guest `id` (no-op if none) — the same path as a
/// close-box click, so it exercises the real stop-and-reclaim sequence. Used by
/// the verification harness to drive a guest's full lifecycle.
pub fn closeVm(d: *Desktop, id: ivirt.Id) void {
    for (d.apps.items) |a| {
        if (a == .vm and a.vm.id == id) {
            requestClose(d, a.window());
            return;
        }
    }
}

/// Close terminal `id` (no-op if none) — same path as a close-box click. Works
/// even while that terminal is busy (e.g. running `prime`), since teardown runs
/// in the system task. Used by the verification harness to exercise the full
/// terminal lifecycle (open → work → close) and watch CPU%/task lists update.
pub fn closeTermId(d: *Desktop, id: u32) void {
    for (d.apps.items) |a| {
        if (a == .term and a.term.id == id) {
            requestClose(d, a.window());
            return;
        }
    }
}

/// Core 0's command worker (SMP): run any pending shell command for each
/// terminal. Called repeatedly by the command-worker task, which yields
/// between scans. Because shell.execute yields during its waits, a slow
/// command on one terminal does not block this scan reaching the others, nor
/// the system task's rendering. Returns true if any command ran (so a render
/// is warranted).
pub fn runPendingCommands(d: *Desktop) bool {
    // CLAIM one terminal with a pending command under the structure lock —
    // reading the list AND publishing cmd_running in the same critical section
    // the system task's closeWindow uses for its deferral-check-and-remove.
    // Without the lock, the scan can dereference a Terminal the system task is
    // freeing in parallel (both tasks float on their own cores); with it, a
    // claimed terminal is guaranteed deferred by any close until the command
    // finishes. The claim is a pointer + flag copy; shell.execute itself runs
    // OUTSIDE the lock (it yields on slow commands).
    const claimed: ?*@import("../../apps/terminal.zig").Terminal = blk: {
        const if_was = d.structure_lock.acquireIrqSave();
        defer d.structure_lock.releaseIrqRestore(if_was);
        for (d.apps.items) |a| {
            if (a != .term) continue;
            if (a.term.claimPendingCommand()) break :blk a.term;
        }
        break :blk null;
    };
    const t = claimed orelse return false;
    _ = t.runPendingCommand();
    // Do NOT dereference `t`/`t.win` here: runPendingCommand clears the
    // session's cmd_running as its last act, so the moment it returns a queued
    // close for this terminal can free `t` (the deferral guard no longer
    // holds). Mark a full repaint instead of markWindow(t.win) — pointer-free,
    // and correct since a command's output warrants a repaint regardless of
    // which window it was.
    d.markFullRepaint();
    return true;
}
