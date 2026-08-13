//! The desktop's input routing: one keystroke or mouse sample in, the right
//! app, window action, or dock tile out. One concern of the Desktop: every
//! function takes the Desktop and keeps its call order.

const std = @import("std");
const buildinfo = @import("buildinfo");
const klog = @import("../../kernel/debug/klog.zig");
const framebuffer = @import("../screen/framebuffer.zig");
const gles = @import("gles"); // the draw API (the dock exists only on the GPU path)
const dock = @import("dock.zig"); // the frosted app dock (click hit-testing)
const cursor = @import("cursor.zig"); // the software pointer image (its damage rects)
const tsc = @import("../../kernel/cpu/tsc.zig");
const imouse = @import("imouse");
const sessionspace = @import("../../kernel/memory/sessionspace.zig");
const smp = @import("../../kernel/smp/smp.zig");
const sched = @import("../../kernel/sched/sched.zig");
const debug = @import("../../kernel/debug/debug.zig");
const iaccel = @import("iaccel"); // the GPU-acceleration seam (iface/iaccel.zig)
const iwindow = @import("iwindow"); // module windows: pointer + key delivery
const desktop_mod = @import("desktop.zig");
const Desktop = desktop_mod.Desktop;
const lifecycle = @import("lifecycle.zig");

/// Route one keystroke to the focused app. In the SMP build a terminal's key
/// is forwarded to its own core's editor (via routeKey); everything else is
/// handled inline and its window repainted.
pub fn onKey(d: *Desktop, ascii: u8) void {
    if (d.focusedApp()) |a| {
        if (buildinfo.smp and a == .term) {
            // SMP: the focused terminal's editor runs in its session's task;
            // route the keystroke there (Terminal.routeKey owns the ring + wake
            // plumbing). The desktop never edits the line itself. The redraw is
            // triggered when applyRequests drains the echo back (see tick).
            a.term.routeKey(ascii);
        } else {
            a.onKey(ascii);
            d.wm.markWindow(a.window()); // and repaints this window
        }
    }
}

/// Give the focused VM window's guest the pointer while it is over that
/// window's content, in the guest's own coordinates. Absolute, because the
/// window shows the guest's whole screen: where the pointer sits inside the
/// content IS where it sits on the guest's display, and a relative delta would
/// need a second cursor to accumulate against.
fn forwardPointerToGuest(d: *Desktop, buttons: u8) void {
    const a = d.focusedApp() orelse return;
    // A loaded module's window gets the pointer the same way a guest's does
    // (Interface.input): content-local coordinates while the pointer is over
    // the FOCUSED blob window, an explicit "not here" otherwise — so a module
    // never sees a frozen last position and mistakes it for a hover.
    if (a == .blob) {
        const bwin = a.window();
        const bw = bwin.contentW();
        const bh = bwin.contentH();
        const bx = d.cursor_x - bwin.contentX();
        const by = d.cursor_y - bwin.contentY();
        if (bw == 0 or bh == 0 or bx < 0 or by < 0 or
            bx >= @as(i32, @intCast(bw)) or by >= @as(i32, @intCast(bh)))
        {
            iwindow.clearPointer(a.blob.handle);
        } else {
            iwindow.pushPointer(a.blob.handle, bx, by, buttons);
        }
        return;
    }
    if (a != .vm) return;
    const win = a.window();
    const cw = win.contentW();
    const ch = win.contentH();
    if (cw == 0 or ch == 0) return;
    const rel_x = d.cursor_x - win.contentX();
    const rel_y = d.cursor_y - win.contentY();
    if (rel_x < 0 or rel_y < 0) return;
    if (rel_x >= @as(i32, @intCast(cw)) or rel_y >= @as(i32, @intCast(ch))) return;
    a.vm.onPointer(@intCast(rel_x), @intCast(rel_y), @intCast(cw), @intCast(ch), buttons);
}

/// Offer one key EDGE — press or release, by Linux key code — to the focused
/// app. Returns whether it was taken. This runs BESIDE the ascii path, not
/// instead of it: a VM window feeds its guest both, because a guest running a
/// shell reads its serial port and one running a compositor reads evdev, and
/// the window cannot know which it has.
pub fn onRawKey(d: *Desktop, code: u16, down: bool) bool {
    if (code == 0) return false; // a usage Linux does not name
    const a = d.focusedApp() orelse return false;
    return a.onRawKey(code, down);
}

/// Handle one mouse sample: update the cursor position (absolute tablet wins
/// over relative motion once seen — see `have_abs_pointer`), forward it to the
/// compositor, then carry out any window action the click requested (the
/// desktop owns the apps + allocator; the compositor only records it).
/// Returns true when something VISIBLE beyond the pointer itself changed —
/// with the hardware cursor active (`iaccel.Accel.cursor`), pure pointer
/// motion is handled entirely by the cursor plane and warrants NO render;
/// with the software cursor every position change must repaint.
pub fn onMouse(d: *Desktop, ev: imouse.MouseEvent) bool {
    const max_x: i32 = @intCast(framebuffer.width() - 1);
    const max_y: i32 = @intCast(framebuffer.height() - 1);
    // Where the software cursor was before this sample — its old rect is
    // damage exactly like a moved window's (see the bottom of this function).
    const prev_x = d.cursor_x;
    const prev_y = d.cursor_y;
    if (ev.abs) |a| {
        d.have_abs_pointer = true; // tablet is now authoritative
        d.accel.resetVelocity(); // stale relative-motion history, if any
        d.cursor_x = std.math.clamp(a.x, 0, max_x);
        d.cursor_y = std.math.clamp(a.y, 0, max_y);
    } else {
        // Ignore relative motion once an absolute pointer exists (see field).
        // Buttons still pass through so a relative device's clicks aren't lost.
        if (!d.have_abs_pointer) {
            const a = d.accel.apply(ev.dx, ev.dy, ev.t_tsc, tsc.hz());
            d.cursor_x = std.math.clamp(d.cursor_x + a.dx, 0, max_x);
            d.cursor_y = std.math.clamp(d.cursor_y + a.dy, 0, max_y);
        }
    }
    // Hardware cursor: the pointer moves via the scanout cursor plane, two
    // MMIO writes, no compositing.
    if (iaccel.accel.cursor) |gc| gc(d.cursor_x, d.cursor_y);
    // Test-hooks pointer mirror: on every BUTTON transition emit the cursor
    // position + new mask (`dbg: wm.ptr = x=… y=… b=…`, `.ui` gate). Button
    // edges only — never per-motion — so the record rate stays trivial. This
    // closes the loop for mouse-driven tests: pointer ACCELERATION makes a
    // relative move non-1:1, so the harness verifies where a click actually
    // landed instead of trusting its own dead reckoning.
    if (comptime buildinfo.test_hooks) {
        if (ev.buttons != d.wm_ptr_buttons_last) {
            var vb: [debug.VAL_CAP]u8 = undefined;
            debug.set(.ui, "wm.ptr", std.fmt.bufPrint(&vb, "x={d} y={d} b={d}", .{
                d.cursor_x, d.cursor_y, ev.buttons,
            }) catch "?");
            d.wm_ptr_buttons_last = ev.buttons;
        }
    }
    // Dock: a fresh press on a dock tile opens its app. Only where the dock is drawn
    // (the gles/GPU path); checked before the window hit-test so the floating bar
    // claims the click. `wm.prev_buttons` still holds the previous frame's mask here.
    if ((gles.hasGpuDevice() or gles.hasSoftwareDevice()) and (ev.buttons & 1) != 0 and (d.wm.prev_buttons & 1) == 0) {
        const sw: f32 = @floatFromInt(framebuffer.width());
        const sh: f32 = @floatFromInt(framebuffer.height());
        const n_wins = blk: {
            var tmp: [desktop_mod.DOCK_WIN_SLOTS]dock.WinItem = undefined;
            break :blk d.dockWinItems(&tmp);
        };
        if (dock.hitAt(sw, sh, desktop_mod.DOCK_APPS.len, n_wins, @floatFromInt(d.cursor_x), @floatFromInt(d.cursor_y))) |hit| {
            switch (hit) {
                // A launcher tile SPAWNS — always a new window. Reaching a
                // running one is the window zone's job (DSK-021); the two
                // zones existing separately is what makes either unambiguous.
                .launcher => |i| lifecycle.spawnApp(d, desktop_mod.DOCK_APPS[i].kind) catch |e| {
                    klog.puts("desktop: dock spawn failed (");
                    klog.puts(@errorName(e));
                    klog.puts(")\n");
                },
                // A window slot focuses its window, restoring it out of the
                // dock first when minimised.
                .window => |j| if (d.dockWindowAt(j)) |win| {
                    if (win.minimized) d.wm.unminimise(win);
                    d.wm.focus(win);
                    d.wm.markFull();
                },
            }
            d.wm.prev_buttons = ev.buttons; // consume the press
            return true;
        }
    }
    // A VM window's guest owns the pointer while it is over that window's
    // content: a browser inside the guest needs to know where the pointer is,
    // and the desktop has nothing to do with a position inside someone else's
    // screen. The window chrome is NOT forwarded — the title bar, the controls
    // and the resize grips stay the desktop's, so a guest can never take the
    // pointer hostage.
    forwardPointerToGuest(d, ev.buttons);

    var changed = d.wm.onMouse(d.cursor_x, d.cursor_y, ev.buttons);
    // The compositor records at most one window action per click; carry it out
    // here (the desktop owns the apps + allocator) and clear it. Drained right
    // after onMouse — close defers to the next tick via requestClose.
    // Fault containment (KRN-006): a core that faulted retired itself and parked.
    // Whatever task it was running is gone, so the window of the SESSION that was
    // on it is closed here; the dead core is never handed work again. The rest of
    // the desktop and every other session run on untouched.
    //
    // The dead session is identified by the TASK the core was running, not by the
    // core: a session's task may run on any core and may have moved there only an
    // instant before the fault (KRN-011), so "the terminal belonging to core N"
    // no longer names anything.
    if (drainFaults(d)) changed = true;
    if (d.wm.pending) |action| {
        d.wm.pending = null;
        changed = true;
        switch (action) {
            .close => |win| lifecycle.requestClose(d, win),
            // Coalesce: mouse events batch several resize steps per frame and
            // each apply repaints/uploads; keep only the LAST request — render()
            // applies it once per frame.
            .resize => |req| d.pending_resize = req,
            .maximise => |win| d.toggleMaximise(win),
            .minimise => |win| d.wm.minimise(win),
        }
    }
    // Software cursor: a moved pointer repaints exactly its old + new rects —
    // the same move-and-damage primitive a window drag uses. Never a
    // full-screen repaint: on the CPU rasteriser the frame's cost is the
    // damage box's area, and a pointer is a few hundred pixels.
    if (iaccel.accel.cursor == null and (d.cursor_x != prev_x or d.cursor_y != prev_y)) {
        d.wm.markRect(prev_x, prev_y, cursor.W, cursor.H);
        d.wm.markRect(d.cursor_x, d.cursor_y, cursor.W, cursor.H);
        changed = true;
    }
    return changed;
}

/// Drain fault reports and close the affected sessions' windows — called from
/// every desktop tick (a faulted session must be retired even on a machine
/// with no pointer traffic) and from mouse handling. Returns true if any
/// window close was queued.
pub fn drainFaults(d: *Desktop) bool {
    if (comptime !buildinfo.smp) return false;
    var changed = false;
    // Kernel faults park their core; the dead session is identified by the TASK
    // that core was running — a session's task may have migrated there only an
    // instant before the fault (KRN-011), so a core number names nothing.
    while (smp.takeFaultedTask()) |dead_task| {
        changed = true;
        for (d.apps.items) |a2| {
            if (a2 != .term) continue;
            const sess = a2.term.session orelse continue;
            if (@atomicLoad(?*sched.Task, &sess.task, .acquire) != dead_task) continue;
            klog.puts("desktop: closing the terminal whose task faulted\n");
            lifecycle.requestClose(d, a2.window());
            break;
        }
    }
    // Sessions whose ADDRESS SPACE faulted (MEM-006): the task was killed in
    // place and the core lives on; all that is left is to close the window.
    // Matched by session id — the classifier knows the space, and the id is
    // stable where the dead task pointer no longer is.
    while (sessionspace.takeFaulted()) |sid| {
        changed = true;
        klog.puts("desktop: closing the session whose address space faulted\n");
        lifecycle.closeTermId(d, sid);
    }
    return changed;
}
