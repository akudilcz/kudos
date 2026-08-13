//! Desktop: the one type that owns the compositor state and the apps. One
//! instance, created on the heap so apps can hold a stable back-pointer.
//! The behavior lives in one sibling module per concern — lifecycle.zig (app
//! spawning + window close), input.zig (key/mouse routing), render.zig (the
//! whole-desktop GL frame), boot_layout.zig (the boot terminal tile) — each operating
//! on this struct; the public methods below forward to them so callers keep
//! one `Desktop` surface. This file keeps the shared state, the time-driven
//! `tick`, the app-list queries, and window geometry (resize/maximise).

const std = @import("std");
const buildinfo = @import("buildinfo");
const framebuffer = @import("../screen/framebuffer.zig");
const gles = @import("gles"); // the draw API (context teardown on a logical resize)
const timer = @import("../../kernel/timer/timer.zig");
const tsc = @import("../../kernel/cpu/tsc.zig");
const square = @import("../wm/square.zig");
const hud = @import("hud.zig"); // the F1 heads-up display: samples on the desktop tick
const dock = @import("dock.zig"); // the dock's Icon vocabulary for DOCK_APPS
const mouse_accel = @import("mouse_accel.zig");
const imouse = @import("imouse");
const percpu = @import("../../kernel/sched/percpu.zig");
const SpinLock = @import("../../kernel/sync/spinlock.zig").SpinLock;
const wm_mod = @import("../wm/wm.zig");
const window_mod = @import("../wm/window.zig");
const Window = window_mod.Window;
const app = @import("../../apps/app.zig");
const App = app.App;
const Kind = app.Kind;
const modelview = @import("../../apps/modelview.zig");
const ModelView = modelview.ModelView;
const png = @import("modelcache").png;
const debug = @import("../../kernel/debug/debug.zig");
const lifecycle = @import("lifecycle.zig");
const ivirt = @import("ivirt");
const input = @import("input.zig");
const render_mod = @import("render.zig");
const boot_layout = @import("boot_layout.zig");

const BLINK_TICKS: u64 = 50; // 0.5 s at 100 Hz
/// Software-rasteriser 3D animation cadence, 100 Hz ticks: ~4 fps. See the throttle in
/// tick() — a bounded animation rate is what keeps a software desktop's input alive.
const MODEL_SOFT_PERIOD_TICKS: u64 = 25;
// Pending-close queue cap: one terminal per core + the boot tiles. More than can
// be closed between two `tick`s, so the queue never overflows in practice.
const pending_close_cap: usize = percpu.MAX_CPUS + 4;

// Test-hooks WM state mirror (build.zig `-Dtest-hooks`; see emitWmState): the
// last-emitted snapshot of every window, so each tick emits only CHANGES.
const WM_SNAP_CAP: usize = 32; // more windows than any test scenario opens
const WmSnap = struct { id: u32, x: i32, y: i32, w: usize, h: usize, max: bool, seen: bool };

/// The dock's launcher tiles — a fixed set of apps, each a rounded accent tile with a
/// glyph; `running` is filled per frame from the open windows. Clicking a tile reveals a
/// running instance of that app or spawns one (input.zig, spec R26). The dock is drawn
/// only on the gles/GPU compositor path.
/// Shared home for its two users: input.zig hit-tests the tiles, render.zig draws them.
pub const DockApp = struct { kind: Kind, accent: u32, icon: dock.Icon };
pub const DOCK_APPS = [_]DockApp{
    .{ .kind = .term, .accent = 0xFF0A84FF, .icon = .terminal }, // Terminal — blue
    .{ .kind = .system, .accent = 0xFF30D158, .icon = .system }, // System monitor — green
    .{ .kind = .clock, .accent = 0xFFFF453A, .icon = .clock }, // Clock — red
    .{ .kind = .calc, .accent = 0xFFFF9F0A, .icon = .calculator }, // Calculator — orange
    .{ .kind = .vm, .accent = 0xFFBF5AF2, .icon = .vm }, // Virtual machine — purple
};

pub const Desktop = struct {
    a: std.mem.Allocator,
    wm: wm_mod.Wm,
    apps: std.array_list.Managed(App),
    cursor_x: i32,
    cursor_y: i32,
    spawn_count: u32 = 0,
    blink_phase: u64 = 0,
    // The last animation phase a software-rasterised model window redrew at
    // (timer.now() / MODEL_SOFT_PERIOD_TICKS) — the throttle in tick().
    model_anim_phase: u64 = 0,
    // The GL desktop's state (render.zig), built lazily on the first frame
    // with a draw device.
    gles_comp: ?render_mod.GlesComp = null,
    /// A hardware GL frame is built and kicked but its finish/flip is deferred
    /// to the next render (see render.zig renderGles/completeOpenFrame) — the
    /// GPU drains it during the inter-frame gap instead of on the frame's
    /// critical path.
    frame_open: bool = false,
    /// Serializes STRUCTURE mutations (the windows/apps lists, the close queue)
    /// between preemptible tasks: the SMP command worker spawns and
    /// queues closes from shell commands while the system task iterates the same
    /// lists every tick. Held only across short, NON-YIELDING sections (a list
    /// append, a queue push, a swapRemove) — never across a render, a GPU wait,
    /// or anything that can block. IRQ-save so a preemption cannot interleave a
    /// half-done mutation with a reader on the same core.
    structure_lock: SpinLock = .{},
    /// A decoded background image handed over by the `background` command
    /// (the cmd-worker task), waiting for the render task to upload it at frame
    /// start. Guarded by structure_lock; pixels owned by `a`.
    bg_pending: ?png.Image = null,
    // Windows queued for close (from `exit` or a close-box click). Teardown is
    // deferred to the top of `tick` so a window is never freed while code is still
    // executing inside it. A QUEUE, not a single slot: several
    // windows can be closed before the next tick drains them (e.g. closing two
    // terminals back to back), and a single slot would drop all but the last.
    // Fixed-size + deduped so `requestClose` stays infallible (no allocation, no
    // double-enqueue → no double-free). Cap covers one terminal per core plus the
    // boot tiles, comfortably more than can be closed between two ticks.
    pending_close: [pending_close_cap]*Window = undefined,
    pending_close_len: usize = 0,
    // Once an absolute pointer (USB tablet) is seen, it is authoritative and
    // relative motion is ignored. QEMU exposes a
    // usb-tablet (absolute); without this they fight and the relative stream drags
    // the cursor into a small box; all real pointer input is the USB tablet/mouse.
    have_abs_pointer: bool = false,
    // Pointer acceleration state for the relative-motion path; unused once
    // have_abs_pointer is true.
    accel: mouse_accel.Accelerator = .{},
    // Test-hooks WM state mirror (see emitWmState; only touched under
    // `comptime buildinfo.test_hooks`, same pattern as the terminal mirror).
    wm_snap: [WM_SNAP_CAP]WmSnap = undefined,
    wm_snap_len: usize = 0,
    wm_focus_last: u32 = 0, // focused window id last emitted; 0 = none
    wm_nwins_last: usize = std.math.maxInt(usize), // force the first emit
    wm_ptr_buttons_last: u8 = 0, // last button mask emitted as a wm.ptr record
    // The LATEST resize request of this frame — mouse events batch several per
    // frame, and each apply re-lays-out the hosted app; render() applies just
    // the last one.
    pending_resize: ?wm_mod.ResizeReq = null,

    /// Allocate the single desktop on the heap (so apps can hold a stable
    /// back-pointer), init the compositor + wallpaper, and center the cursor.
    pub fn create(a: std.mem.Allocator) !*Desktop {
        const self = try a.create(Desktop);
        self.* = .{
            .a = a,
            .wm = wm_mod.Wm.init(a, framebuffer.width(), framebuffer.height(), tsc.rdtsc()),
            .apps = try std.array_list.Managed(App).initCapacity(a, wm_mod.MAX_WINDOWS),
            .cursor_x = @intCast(framebuffer.width() / 2),
            .cursor_y = @intCast(framebuffer.height() / 2),
        };
        return self;
    }

    // ── app spawning & window lifecycle (lifecycle.zig) ──────────────────────

    /// Open a new app window of the given kind, cascaded.
    pub fn spawnApp(self: *Desktop, kind: Kind) !void {
        return lifecycle.spawnApp(self, kind);
    }

    /// Open the console window onto an already-claimed guest slot (network
    /// image boots — see lifecycle.spawnVmWindow).
    pub fn spawnVmWindow(self: *Desktop, id: ivirt.Id) !void {
        return lifecycle.spawnVmWindow(self, id);
    }

    /// Open the dedicated AI agent window (spec AGT-002; F10).
    pub fn spawnAgent(self: *Desktop) !void {
        return lifecycle.spawnAgent(self);
    }

    /// Open a model-viewer window on the ABSOLUTE VFS path `name`.
    pub fn spawnModel(self: *Desktop, name: []const u8, maximized: bool) !void {
        return lifecycle.spawnModel(self, name, maximized);
    }

    /// Queue a window for close; teardown is deferred to the next `tick`.
    pub fn requestClose(self: *Desktop, win: *Window) void {
        lifecycle.requestClose(self, win);
    }

    /// Focus terminal `id` (verification harness).
    pub fn focusTermId(self: *Desktop, id: u32) void {
        lifecycle.focusTermId(self, id);
    }

    /// Close terminal `id` (verification harness) — the real close-box path.
    pub fn closeTermId(self: *Desktop, id: u32) void {
        lifecycle.closeTermId(self, id);
    }

    /// Close the VM window showing guest `id` — the real close-box path, which
    /// stops the guest and reclaims everything it holds.
    pub fn closeVm(self: *Desktop, id: usize) void {
        lifecycle.closeVm(self, id);
    }

    /// Core 0's command worker (SMP): run any pending shell command.
    pub fn runPendingCommands(self: *Desktop) bool {
        return lifecycle.runPendingCommands(self);
    }

    // ── boot layout (boot_layout.zig) ────────────────────────────────────────

    /// Spawn the boot tiles: SMP four terminals tiled 2x2 (two autostarted),
    /// single-core the one quarter-screen terminal (boot_layout.zig).
    pub fn spawnBootLayout(self: *Desktop) !void {
        return boot_layout.spawnBootLayout(self);
    }

    /// Re-apply the boot geometry at the CURRENT screen size.
    pub fn retileBoot(self: *Desktop) void {
        boot_layout.retileBoot(self);
    }

    // ── input routing (input.zig) ────────────────────────────────────────────

    /// Route one keystroke to the focused app.
    pub fn onRawKey(self: *Desktop, code: u16, down: bool) bool {
        return input.onRawKey(self, code, down);
    }

    pub fn onKey(self: *Desktop, ascii: u8) void {
        input.onKey(self, ascii);
    }

    /// Handle one mouse sample; returns true when something visible beyond
    /// the pointer itself changed.
    pub fn onMouse(self: *Desktop, ev: imouse.MouseEvent) bool {
        return input.onMouse(self, ev);
    }

    // ── compositing / render path (render.zig) ───────────────────────────────

    /// Draw one desktop frame.
    pub fn render(self: *Desktop) void {
        render_mod.render(self);
    }

    /// Hand the desktop a decoded background image (spec R24); false while a
    /// previous hand-off is still pending (the caller keeps ownership).
    pub fn setBackground(self: *Desktop, img: png.Image) bool {
        return render_mod.setBackground(self, img);
    }

    // ── shared state: geometry, queries, time ────────────────────────────────

    /// Resize `win` to the new outer size and re-lay-out its hosted app. Marks the
    /// old and new frames dirty so the vacated area + the grown/shrunk window both
    /// repaint. On realloc failure the window is left unchanged and
    /// false is returned — LOUDLY, so a half-applied maximise cannot leave the
    /// window and its damage rects disagreeing.
    pub fn applyResize(self: *Desktop, win: *Window, w: usize, h: usize) bool {
        // Capture the OLD outer rect before resize mutates win.w/h: a shrink
        // vacates the strip between the old and new far edges, which damage
        // tracking (the frame draws only current footprints) would otherwise
        // leave stale on the software device.
        const old_x = win.x;
        const old_y = win.y;
        const old_w = win.w;
        const old_h = win.h;
        win.resize(w, h);
        for (self.apps.items) |a| {
            if (a.window() == win) {
                _ = a.onResize(); // the app re-derives its layout from the new content area
                break;
            }
        }
        // Damage exactly the OLD ∪ NEW window footprint instead of the whole screen:
        // a per-drag-step full recomposite + GPU upload costs too much to hold the
        // drag's frame rate. markRect coalesces the two rects (they share the top-left
        // corner) into one bounding box, so a resize step recomposites only the
        // window's swept area — the grown/shrunk region and the vacated strip both
        // repaint.
        self.wm.markRect(old_x, old_y, old_w, old_h); // old footprint (vacated strip)
        self.wm.markWindow(win); // new footprint
        return true;
    }

    /// Toggle `win` between maximised (filling the screen) and its prior geometry.
    /// Stores the pre-maximise geometry in `win.restore`; un-maximise restores and
    /// clears it. ATOMIC: geometry/restore state changes only after
    /// the resize succeeded, so a failed alloc leaves the window exactly as it was
    /// (no moved-but-unresized half state).
    /// Pub: `show <name> max` opens a maximised model window.
    pub fn toggleMaximise(self: *Desktop, win: *Window) void {
        if (win.restore) |g| {
            if (!self.applyResize(win, g.w, g.h)) return;
            win.restore = null;
            win.x = g.x;
            win.y = g.y;
        } else {
            const saved = window_mod.Geometry{ .x = win.x, .y = win.y, .w = win.w, .h = win.h };
            if (!self.applyResize(win, framebuffer.width(), framebuffer.height())) return;
            win.restore = saved;
            win.x = 0;
            win.y = 0;
        }
        // The window's ORIGIN moved after applyResize marked its rects, so the
        // marks cover the wrong places for both directions of the toggle. A
        // maximise toggle repaints everything — it is rare and touches most of
        // the screen anyway.
        self.wm.markFull();
    }

    /// The app hosted by the currently-focused window, or null if none is focused.
    /// Pub for the sibling concern modules (input routing, tick) only.
    pub fn focusedApp(self: *Desktop) ?App {
        const f = self.wm.focused orelse return null;
        for (self.apps.items) |a| {
            if (a.window() == f) return a;
        }
        return null;
    }

    /// The model-viewer app hosted in `win`, if that is what the window holds — the
    /// whole-desktop frame draws its 3D inline rather than sampling a content layer.
    /// Pub for the sibling concern modules (render path) only.
    pub fn modelFor(self: *Desktop, win: *Window) ?*ModelView {
        for (self.apps.items) |a| {
            if (a == .model and a.window() == win) return a.model;
        }
        return null;
    }

    /// The app hosted in `win`, whatever its kind — the whole-desktop frame asks it to
    /// draw its content directly. Pub for the sibling concern modules only.
    pub fn appFor(self: *Desktop, win: *Window) ?App {
        for (self.apps.items) |a| {
            if (a.window() == win) return a;
        }
        return null;
    }

    /// Whether any window hosting an app of `kind` is open — lights the dock's
    /// running dot. Pub for the sibling concern modules (render path) only.
    pub fn kindRunning(self: *Desktop, kind: Kind) bool {
        for (self.apps.items) |a| {
            if (a.kind() == kind) return true;
        }
        return false;
    }

    /// Force the next render to do a full-screen present (used by the SMP system
    /// task to repaint from scheduler context after the boot-stack render).
    pub fn markFullRepaint(self: *Desktop) void {
        self.wm.markFull();
    }

    /// Advance time-driven state. Returns true if anything changed (blink phase
    /// or a self-animating app), so a re-render is warranted.
    pub fn tick(self: *Desktop) bool {
        var changed = false;
        // Faulted sessions are retired from the TICK, not only from mouse
        // handling: a headless or untouched machine must still close the window
        // of a session whose task died (MEM-006/KRN-006).
        if (input.drainFaults(self)) changed = true;
        // Screen-size change from the GPU display path (setLogicalSize): adopt the
        // new logical desktop size and force a full recomposite. The GL context was
        // built at the old size (its frame extent + Dst stride), so drop it — the
        // next renderGles rebuilds it at the new screen size. In practice this fires
        // once, during GPU bring-up, BEFORE the first render (so gles_comp is still
        // null and this is a no-op then); the teardown covers a later mode change.
        if (framebuffer.consumeLogicalResize()) {
            if (self.gles_comp) |*gc| {
                gles.destroyContext(&gc.gctx);
                self.gles_comp = null;
            }
            self.wm.resizeScreen(framebuffer.width(), framebuffer.height());
            self.retileBoot();
            changed = true;
        }
        // Drain ALL queued closes FIRST, before any loop iterates the app list, so
        // nothing touches a window that is about to be freed.
        // Snapshot-then-clear the count up front: closeWindow can re-enter
        // requestClose (a terminal mid-command defers its own teardown by one
        // tick), and those re-queued requests must wait for the NEXT tick, not be
        // dropped or double-processed here. Note there is NO automatic recovery
        // terminal: closing the last terminal leaves none — F12 (boot/pump.zig
        // dispatchInput) is the recovery path, spawning a fresh terminal from
        // anywhere. The integration suite (boot 1 phase 5) pins this contract.
        if (self.pending_close_len > 0) {
            // Snapshot-and-clear under the structure lock (the worker's
            // requestClose races this drain); the closes themselves run
            // unlocked — closeWindow frees and can touch the GPU.
            var pending: [pending_close_cap]*Window = undefined;
            var n: usize = 0;
            {
                const if_was = self.structure_lock.acquireIrqSave();
                defer self.structure_lock.releaseIrqRestore(if_was);
                n = self.pending_close_len;
                for (0..n) |i| pending[i] = self.pending_close[i];
                self.pending_close_len = 0;
            }
            for (pending[0..n]) |win| lifecycle.closeWindow(self, win);
            changed = true;
        }
        const phase = timer.now() / BLINK_TICKS;
        if (phase != self.blink_phase) {
            self.blink_phase = phase;
            changed = true;
            // The blink cursor lives in the focused window only. For a terminal
            // only the CURSOR CELL changes — mark just it (the terminal's draw
            // is likewise incremental); other
            // apps repaint their whole window.
            if (self.focusedApp()) |a| {
                if (a == .term) {
                    const r = a.term.cursorCellScreen();
                    self.wm.markRect(r.x, r.y, r.w, r.h);
                } else {
                    self.wm.markWindow(a.window());
                }
            }
        }
        for (self.apps.items) |a| {
            if (a.tick()) {
                // A 3D animation on the SOFTWARE rasteriser is throttled: its window's
                // damage forces a large software repaint (hundreds of milliseconds at
                // desktop size), and at every tick that starves the input path — the
                // emulator's keyboard queue holds ~a quarter second of typing. The
                // hardware device animates at the panel rate; software gets a bounded
                // cadence, which is what a screensaver-grade nicety deserves there.
                // A module's replayed scene (the blob window) is 3D on the same
                // rasteriser, so it rides the same throttle — its recorder simply
                // waits in end_frame until the next consumed frame.
                const anim3d = a == .model or (a == .blob and a.blob.mode == .scene);
                const throttled = anim3d and !gles.hasGpuDevice() and
                    (timer.now() / MODEL_SOFT_PERIOD_TICKS) == self.model_anim_phase;
                if (!throttled) {
                    if (anim3d and !gles.hasGpuDevice())
                        self.model_anim_phase = timer.now() / MODEL_SOFT_PERIOD_TICKS;
                    changed = true;
                    self.wm.markWindow(a.window()); // (diag scroll, system refresh)
                }
            }
            // SMP: as the system task, apply each terminal's posted grid
            // requests (echo/backspace/run_line) from its session task. This is
            // where the ring is drained and the actual rendering happens.
            if (buildinfo.smp and a == .term) {
                if (a.term.applyRequests()) {
                    changed = true;
                    self.wm.markWindow(a.window());
                }
            }
            // Command OUTPUT is written by the cmd-worker task between ticks
            // (shell.execute → putChar), off every damage path above — take
            // the terminal's own dirty flag so output repaints its window.
            if (a == .term and a.term.takeDirty()) {
                changed = true;
                self.wm.markWindow(a.window());
            }
        }
        // Screensaver cube: advance it on its own cadence phase and mark its
        // damage. It composites below the windows, so no per-window state to
        // touch — the frame draws it from its Motion (position AND spin angle).
        if (self.wm.tickSquare(timer.now() / square.STEP_TICKS)) changed = true;
        // Test-hooks WM state mirror: emit any window-manager state CHANGES since
        // the last tick as `dbg: wm.*` records, so the integration harness asserts
        // exact focus/geometry/maximise state instead of inferring it from pixels.
        // One diff-based call site catches every cause — mouse, command, F11/F12,
        // maximise toggle — regardless of which path mutated the state.
        // The heads-up display samples on its own half-second cadence; a new
        // sample is a redraw request like any other (spec HUD-032). It draws
        // over the whole screen, so its damage is the whole screen.
        if (hud.tick()) {
            changed = true;
            self.wm.markFull();
        }
        if (comptime buildinfo.test_hooks) self.emitWmState();
        return changed;
    }

    /// Test-hooks only (compiled out otherwise): diff the compositor's window
    /// state against the last emitted snapshot and emit one `dbg: wm.*` record per
    /// change, under the `.ui` gate:
    ///   wm.nwins = N                                  window count changed
    ///   wm.focus = <id>:<title>                       focus moved (0:none possible)
    ///   wm.win<id> = x=… y=… w=… h=… max=0|1 t=<tail> opened OR geometry/max changed
    ///   wm.closed = <id>                              window went away
    fn emitWmState(self: *Desktop) void {
        const n = self.wm.windows.items.len;
        if (n != self.wm_nwins_last) {
            debug.setNum(.ui, "wm.nwins", n);
            self.wm_nwins_last = n;
        }
        const fid: u32 = if (self.wm.focused) |f| f.id else 0;
        if (fid != self.wm_focus_last) {
            var vb: [debug.VAL_CAP]u8 = undefined;
            const title: []const u8 = if (self.wm.focused) |f| f.title else "none";
            debug.set(.ui, "wm.focus", std.fmt.bufPrint(&vb, "{d}:{s}", .{ fid, titleTail(title) }) catch "?");
            self.wm_focus_last = fid;
        }
        // Per-window diff: mark snapshots unseen, walk live windows (update/add),
        // then compact away the unseen ones (closed windows).
        for (self.wm_snap[0..self.wm_snap_len]) |*s| s.seen = false;
        for (self.wm.windows.items) |w| {
            const max = w.restore != null;
            var found = false;
            for (self.wm_snap[0..self.wm_snap_len]) |*s| {
                if (s.id != w.id) continue;
                found = true;
                s.seen = true;
                if (s.x != w.x or s.y != w.y or s.w != w.w or s.h != w.h or s.max != max) {
                    s.* = .{ .id = w.id, .x = w.x, .y = w.y, .w = w.w, .h = w.h, .max = max, .seen = true };
                    emitWinGeom(w, max);
                }
                break;
            }
            if (!found) {
                if (self.wm_snap_len < WM_SNAP_CAP) {
                    self.wm_snap[self.wm_snap_len] = .{ .id = w.id, .x = w.x, .y = w.y, .w = w.w, .h = w.h, .max = max, .seen = true };
                    self.wm_snap_len += 1;
                    emitWinGeom(w, max); // first sight = the window opened
                } else {
                    debug.setNum(.ui, "wm.snap_overflow", w.id); // loud, never silent
                }
            }
        }
        var i: usize = 0;
        while (i < self.wm_snap_len) {
            if (self.wm_snap[i].seen) {
                i += 1;
            } else {
                debug.setNum(.ui, "wm.closed", self.wm_snap[i].id);
                self.wm_snap[i] = self.wm_snap[self.wm_snap_len - 1];
                self.wm_snap_len -= 1;
            }
        }
    }

    /// One window's geometry record (see emitWmState). The title tail is capped so
    /// the whole value always fits debug.VAL_CAP (path titles can be long).
    fn emitWinGeom(w: *Window, max: bool) void {
        var kb: [debug.KEY_CAP]u8 = undefined;
        var vb: [debug.VAL_CAP]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "wm.win{d}", .{w.id}) catch "wm.win?";
        const val = std.fmt.bufPrint(&vb, "x={d} y={d} w={d} h={d} max={d} t={s}", .{
            w.x, w.y, w.w, w.h, @intFromBool(max), titleTail(w.title),
        }) catch "?";
        debug.set(.ui, key, val);
    }

    /// Last ≤24 bytes of a window title — keeps `/usbdisk/models/rabbit.glb`-style
    /// path titles recognisable (the basename end) within the record cap.
    fn titleTail(title: []const u8) []const u8 {
        return if (title.len <= 24) title else title[title.len - 24 ..];
    }
};
