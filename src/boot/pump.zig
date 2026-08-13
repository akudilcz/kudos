//! The desktop PUMP: both cooperative loops that drive the desktop, and the
//! input routing they share. `systemLoop` is the no-GPU loop (single-core
//! main loop; SMP core 0's system task on an emulated boot); `desktopPump` +
//! `pollInputOnly` are the GPU session's callbacks (iaccel.compositor). Split
//! from main_root.zig along the boot/steady-state seam: main decides how the
//! machine comes up, this file is what it does every iteration after that.

const std = @import("std");
const buildinfo = @import("buildinfo");
const klog = @import("../kernel/debug/klog.zig");
const timer = @import("../kernel/timer/timer.zig");
const tsc = @import("../kernel/cpu/tsc.zig");
const counter = @import("../kernel/debug/counter.zig");
const keyboard = @import("../drivers/input/keyboard.zig");
const imouse = @import("imouse");
const xhci = @import("../drivers/usb/xhci.zig");
const net = @import("../drivers/net/stack/net.zig");
const fileserv = @import("../drivers/net/debug/fileserv.zig");
const smp = @import("../kernel/smp/smp.zig");
const services = @import("services.zig"); // THE service table both steady loops step
const virt = @import("../kernel/virt/virt.zig");
const idesk = @import("idesk"); // the desktop-control seam: window requests in, the window list out
const iwindow = @import("iwindow"); // module windows: create/close requests, focus
const apprun = @import("../console/apprun.zig"); // detached windowed runs, reaped on this loop
const power = @import("../kernel/power/reboot.zig");
const framebuffer = @import("../ui/screen/framebuffer.zig");
const hud = @import("../ui/desktop/hud.zig");
const prof = @import("../drivers/gpu/prof.zig");
const iaccel = @import("iaccel");
const Desktop = @import("../ui/desktop/desktop.zig").Desktop;
const lifecycle = @import("../ui/desktop/lifecycle.zig"); // window close, the deferred path
const Window = @import("../ui/wm/window.zig").Window;

/// The window whose title was last published to the remote-request inbox. Only
/// a CHANGE of focused window is republished — this loop runs at kHz and the
/// title would otherwise be copied thousands of times a second to say the same
/// thing. Starts null, which is also "nothing focused", so the first real focus
/// always publishes.
var last_published_focus: ?*Window = null;

/// The desktop the pumps drive. Created inside main's run(); the no-arg
/// callback pumps and the SMP system task reach it through this global.
/// Single global owner.
pub var desktop: *Desktop = undefined;

// Display-backend workaround: how often the system loop forces a full present
// (~20 Hz) so QEMU's VNC/GTK scanout surface stays live when nothing changed.
// See systemLoop.
const REPAINT_PERIOD_MS: u64 = 50;
const REPAINT_PERIOD_TICKS: u64 = REPAINT_PERIOD_MS * timer.TICK_HZ / 1000;

/// Open an application window by name — the desktop-side of the agent's
/// application tool (AGT-006). Unknown names are an error the caller traces.
/// Apply one desktop-control request (AGT-023). A request that names no window
/// acts on the focused one, which is what "maximise it" means when nobody said
/// which; a name that matches nothing is TRACED, because silence reads exactly
/// like a window that never opened.
fn applyWindowAction(d: *Desktop, req: idesk.Request) void {
    var msg: [96]u8 = undefined;
    // Named by a substring of its title, minimised ones included: a window in
    // the dock is still a window the user can point at, and `restore` is
    // precisely how they bring it back — so this is a plain scan of the list
    // rather than wm.focusByTitle, which only considers visible windows.
    const target: ?*Window = if (req.name.len == 0) d.wm.focused else blk: {
        for (d.wm.windows.items) |w| {
            if (std.mem.indexOf(u8, w.title, req.name) != null) break :blk w;
        }
        break :blk null;
    };
    const win = target orelse {
        klog.puts(std.fmt.bufPrint(&msg, "desk: no window matching '{s}'\n", .{req.name}) catch "desk: no match\n");
        return;
    };
    switch (req.action) {
        .focus => d.wm.focus(win),
        .maximise => d.toggleMaximise(win),
        .minimise => d.wm.minimise(win),
        .restore => d.wm.unminimise(win),
        .close => lifecycle.requestClose(d, win),
    }
    publishWindowList(d);
}

/// Publish the window list through the desktop-control seam: one line per
/// window, in the desktop's own order, carrying what a person sees at a glance —
/// which window has focus and which are in the dock. Written whenever the list
/// or the focus can have changed, so a reader always has the desktop's last word
/// rather than a pointer into state it does not own.
fn publishWindowList(d: *Desktop) void {
    var buf: [idesk.MAX_WINDOWS_TEXT]u8 = undefined;
    var used: usize = 0;
    for (d.wm.windows.items) |w| {
        const line = std.fmt.bufPrint(buf[used..], "{s}{s}  {d}x{d} at {d},{d}{s}\n", .{
            if (w == d.wm.focused) "*" else " ",
            w.title,
            w.w,
            w.h,
            w.x,
            w.y,
            if (w.minimized) "  [dock]" else "",
        }) catch break; // full: a partial list is still an answer
        used += line.len;
    }
    idesk.publishWindows(buf[0..used]);
}


/// Open the application a person or an agent named. The agent window is the one
/// name that is not an `AppKind` — it is a terminal opened straight into a
/// conversation, so it has its own spawner; every other name is looked up in
/// the contract's catalogue rather than re-spelled here.
fn spawnByName(d: *Desktop, name: []const u8) !void {
    if (std.mem.eql(u8, name, "ai")) return d.spawnAgent();
    const kind = idesk.AppKind.fromName(name) orelse return error.UnknownApp;
    return d.spawnApp(kind);
}

/// Drain the keyboard + mouse rings into the desktop; returns true when
/// something changed that needs a recomposite. The ONE owner of the global
/// hotkeys and key/mouse routing — shared by systemLoop and desktopPump so the
/// two loops' input behavior cannot drift.
///
/// Mouse: with the HW cursor active, pure pointer motion returns false — the
/// cursor plane already moved (inside onMouse, unconditionally); nothing to
/// render. A drag/click returns true → content must recomposite. The cursor
/// plane is updated here PER EVENT, before any (blocking) render, so pointer
/// motion tracks input at loop rate even while a drag's content render is gated
/// behind vblank ("Session update cycle").
fn dispatchInput(d: *Desktop) bool {
    var changed = false;
    var msg: [64]u8 = undefined; // scratch for the hotkey failure traces
    // The agent's application tool (AGT-006) parks an app-spawn request in the
    // remote-request inbox; the desktop opens it here, on its own core, the same
    // place the F10/F12 hotkeys spawn windows.
    if (fileserv.takeSpawnRequest()) |name| {
        spawnByName(d, name) catch |e|
            klog.puts(std.fmt.bufPrint(&msg, "agent open_app '{s}' failed: {s}\n", .{ name, @errorName(e) }) catch "agent open_app failed\n");
        changed = true;
    }
    // A remote focus-by-name request (DIAG-020), from the same inbox and for the
    // same reason: the window list is the desktop's, and this is its core. A
    // needle that matches nothing is traced rather than ignored — silence would
    // read exactly like a window that never opened.
    if (fileserv.takeFocusRequest()) |needle| {
        if (d.wm.focusByTitle(needle) != null) {
            changed = true;
        } else {
            klog.puts(std.fmt.bufPrint(&msg, "focus: no visible window matching '{s}'\n", .{needle}) catch "focus: no match\n");
        }
    }
    // A window operation asked for through the desktop-control seam (AGT-023):
    // the same five things a person does with the title bar and the dock, run
    // here because the window list is the desktop's and this is its core.
    if (idesk.takeAction()) |req| {
        applyWindowAction(d, req);
        changed = true;
    }
    // A loaded module asked for a window (MOD-012), or is done with one. Both are
    // drained here — the desktop's core — because the window list is the desktop's;
    // the module is meanwhile spinning in `WindowApi.create` (bounded) or already
    // returning. A spawn failure is traced, and the module's wait times out into a
    // refused create rather than hanging on silence.
    if (iwindow.takeCreateRequest()) |req| {
        lifecycle.spawnBlobWindow(d, req) catch |e|
            klog.puts(std.fmt.bufPrint(&msg, "module window open failed: {s}\n", .{@errorName(e)}) catch "module window open failed\n");
        changed = true;
    }
    if (iwindow.takeClose()) |handle| {
        lifecycle.closeBlobWindow(d, handle);
        changed = true;
    }
    // Give a finished detached run its session back (the run task set `done` as
    // its last act; the reap is cheap and idempotent).
    apprun.reapWindowed();
    // Publish where a keystroke would land, for the remote injector that has to
    // know before it types — and tell a module window whether it is the one
    // holding focus (its `WindowApi.focused`).
    if (d.wm.focused != last_published_focus) {
        last_published_focus = d.wm.focused;
        fileserv.publishFocus(d.wm.focusedTitle());
        publishWindowList(d);
        for (d.apps.items) |a| {
            if (a == .blob) iwindow.setFocused(a.blob.handle, d.wm.focused == a.window());
        }
    }
    while (keyboard.poll()) |ev| {
        // PERF-008: this event's visible effect (echo, spawned window) rides the
        // next present — latch its receipt stamp for the input→present latency
        // counters. An empty event (no ascii, no named key) changes nothing on
        // screen and is not latched.
        if (ev.ascii != 0 or ev.key != .none) iaccel.input_latch.consumed(ev.t_tsc);
        if (ev.key == .f1) {
            // Global hotkey: show or hide the heads-up display (spec HUD-002),
            // independent of focus — a machine in trouble is exactly when the
            // focused window is the wrong place to have to click. Both
            // directions repaint everything: showing draws over the whole
            // screen, hiding must restore what was underneath.
            hud.toggle();
            d.markFullRepaint();
            changed = true;
        } else if (ev.key == .f10) {
            // Global hotkey: open the dedicated AI agent window (spec AGT-002),
            // independent of focus. OOM / no-free-cores must not bring down the
            // kernel, but the reason is traced, never silently swallowed.
            d.spawnAgent() catch |e|
                klog.puts(std.fmt.bufPrint(&msg, "F10: spawn AI agent failed: {s}\n", .{@errorName(e)}) catch "F10: spawn AI agent failed\n");
            changed = true;
        } else if (ev.key == .f12) {
            // Global hotkey: open a new terminal, independent of focus — the
            // recovery path when every terminal has been closed
            // OOM / no-free-cores must not bring down the
            // kernel, but the reason is traced, never silently swallowed.
            d.spawnApp(.term) catch |e|
                klog.puts(std.fmt.bufPrint(&msg, "F12: spawn term failed: {s}\n", .{@errorName(e)}) catch "F12: spawn term failed\n");
            changed = true;
        } else if (ev.down and ev.ascii != 0 and hud.onKey(ev.ascii)) {
            // While it is up, the display takes the keys it owns (freeze,
            // acknowledge) before ANY window sees them — including a window
            // that runs its own input stack, which is offered raw edges below.
            // The matching release still reaches that window: a release for a
            // press it never saw is ignored by every input stack, while
            // swallowing releases would leave a key stuck down in a guest.
            changed = true;
        } else {
            // Every edge — press and release alike — is offered to the focused
            // window first, for an app that runs its own input stack (a VM's
            // guest). It is not consumed there: the ascii path below still runs,
            // so a guest with only a serial console keeps working.
            if (d.onRawKey(ev.evdev, ev.down)) changed = true;
            if (ev.down and ev.ascii != 0) {
                d.onKey(ev.ascii);
                changed = true;
            }
        }
    }
    while (imouse.poll()) |ev| {
        if (d.onMouse(ev)) {
            changed = true;
            // PERF-008: latch only content-changing pointer input (click, drag) —
            // pure motion under the HW cursor is already on glass via the cursor
            // plane and needs no present.
            iaccel.input_latch.consumed(ev.t_tsc);
        }
    }
    return changed;
}

/// The system loop: poll input + USB, route keys, drain terminal rings, render.
/// In the single-core build this is the kernel's main loop; in the SMP build it
/// is core 0's system task, time-shared with the #0> terminal task. Never returns.
/// Soft-display render-loop counters (emitted as `dbg: ui.*` on the trace
/// heartbeat): how often the CPU compositor rendered, what each frame cost,
/// and which trigger asked for it — the profile that says where an unusably
/// slow soft desktop spends its time.
var cnt_soft_frames = counter.Counter{ .mod = .ui, .name = "soft.frames" };
var cnt_soft_frame_us = counter.Counter{ .mod = .ui, .name = "soft.frame_us" };
var cnt_soft_frame_us_peak = counter.Counter{ .mod = .ui, .name = "soft.frame_us_peak" };
var cnt_soft_render_input = counter.Counter{ .mod = .ui, .name = "soft.render.input" };
var cnt_soft_render_tick = counter.Counter{ .mod = .ui, .name = "soft.render.tick" };
var cnt_soft_render_forced = counter.Counter{ .mod = .ui, .name = "soft.render.forced" };

/// net's guest-bridge hook, wired to the hypervisor here at the apex: the
/// stack must stay ignorant of guests and the hypervisor of NICs, and this is
/// the one file that already knows both.
fn bridgeOffer(_: *anyopaque, from: net.Port, frame: []const u8) bool {
    return virt.bridgeOffer(from, frame);
}
fn bridgePoll(_: *anyopaque, buf: []u8, from: *net.Port) ?usize {
    return virt.bridgePoll(buf, from);
}

/// Uses the module's `desktop` (set by main before either loop starts).
pub fn systemLoop() noreturn {
    counter.register(&cnt_soft_frames);
    counter.register(&cnt_soft_frame_us);
    counter.register(&cnt_soft_frame_us_peak);
    counter.register(&cnt_soft_render_input);
    counter.register(&cnt_soft_render_tick);
    counter.register(&cnt_soft_render_forced);
    // Guests reach the wire from the first frame they send: connect the
    // hypervisor's bridge before the loop's first net.pump().
    var bridge_ctx: u8 = 0;
    net.connectBridge(.{ .ctx = &bridge_ctx, .offer = bridgeOffer, .poll = bridgePoll });
    // Paint once on entry so the desktop is on screen immediately. In the SMP
    // build the desktop was already rendered once on the boot stack (consuming
    // the compositor's initial full-present), so force a fresh full present here
    // from the system task's context — otherwise nothing is dirty and the screen
    // stays whatever the boot-stack present left (which QEMU may not have scanned).
    if (buildinfo.smp) desktop.markFullRepaint();
    desktop.render();
    var loop_n: u64 = 0;
    var last_repaint: u64 = timer.now();
    while (true) {
        loop_n += 1;

        // Every background service, in one ordered pass (boot/services.zig):
        // the trace drain, the network pump and its KMR1 replies, backgrounded
        // jobs, the boot log, module capabilities, guest boot requests. The
        // list lives there rather than here because the GPU session loop steps
        // the same one — two hand-written lists had already diverged.
        services.stepAll(.service);
        var changed = false;

        if (power.shutdown_requested) power.poweroff();

        xhci.poll(); // drain USB HID reports into the keyboard/mouse rings

        if (dispatchInput(desktop)) {
            changed = true;
            cnt_soft_render_input.inc();
        }
        if (desktop.tick()) {
            changed = true;
            cnt_soft_render_tick.inc();
        }

        // PERIODIC FORCED REPAINT: QEMU's VNC/GTK scanout surface
        // goes stale if the guest stops presenting (it only re-samples on a
        // present), so a pure render-on-change loop would leave the host display
        // black between changes even though the framebuffer is correct. Real
        // hardware scans the framebuffer out continuously and needs no such
        // repaint. Force a full present at most every REPAINT_PERIOD_TICKS timer
        // ticks (wall-clock, NOT loop iterations — the loop spins arbitrarily
        // fast), keeping the emulated display live at a bounded ~20 Hz. A
        // display-backend workaround, NOT the steady-state render path; otherwise
        // we render ONLY when something changed (an unchanged frame would still
        // recomposite for nothing).
        //
        // The soft-display path is EXEMPT: it writes the VGA framebuffer memory
        // directly, which QEMU dirty-tracks and re-samples on its own — and a
        // forced full frame there would cost a whole-screen CPU re-raster.
        const now = timer.now();
        if (framebuffer.linearTarget() == null and now -% last_repaint >= REPAINT_PERIOD_TICKS) {
            last_repaint = now;
            desktop.markFullRepaint();
            changed = true;
            cnt_soft_render_forced.inc();
        }
        if (changed) {
            const t0 = tsc.rdtsc();
            desktop.render();
            const us = tsc.elapsedUs(t0);
            cnt_soft_frames.inc();
            cnt_soft_frame_us.add(us);
            cnt_soft_frame_us_peak.peak(us);
        }

        // The post-render slice: every live guest advances by one bounded slice
        // AFTER this pass's input, tick and render, so a guest can never push a
        // present past its deadline (PERF-003) — it runs in what is left of the
        // pass. A no-op on SMP, where each guest's vCPU is a task of its own.
        services.stepAll(.slice);

        // The only per-variant difference: an SMP core 0 yields so its other tasks
        // (terminals, cmd-worker) run; single-core has nothing else to run, so it
        // halts until the next IRQ — unless a guest has work this instant, which
        // is exactly what this core would otherwise be sleeping through. A guest
        // parked in HLT does not count: see virt.mayHaltCore.
        if (buildinfo.smp) smp.yieldCpu() else if (virt.mayHaltCore()) asm volatile ("hlt");
    }
}

// Set when any pump iteration saw a change (input, tick, command output) that
// has not been rendered yet. The pump renders only when this is set AND the
// GPU flip gate is open, so one render fires per opened gate no matter how
// many kHz-rate input iterations accumulated changes meanwhile
// ("Session update cycle + vsync pacing").
var g_render_pending: bool = false;

/// Wall time of the last d.render() in the GPU pump (µs): the CPU scene build
/// plus the wait for that frame's own de-tile to land. The pipelined-start
/// decision compares it against the panel refresh (see desktopPump).
var g_last_render_us: u64 = 0;
/// Slack subtracted from the refresh budget when deciding a frame is too slow
/// to also wait out the previous flip's latch: covers the flip-arm cost and
/// one input-sampling pass, so a frame within a hair of the budget still takes
/// the pipelined start instead of slipping to the second vblank.
const RENDER_START_SLACK_US: u64 = 2_000;

/// The pre-reset flush behind power.flush_hook (STO-007): every buffered
/// service emptied before the machine goes, plus the state of anything that
/// was not healthy on the way out — both derived from the service table, in
/// reverse order, so a service added there is flushed here without anyone
/// remembering to say so.
pub fn orderlyFlush() void {
    services.traceStatus();
    services.flushAll();
}

/// Poll USB + input WITHOUT rendering (iaccel.compositor.poll_input). The GPU
/// bring-up calls this in a bounded settle before the first present, so a slow
/// device that finishes coming up during GSP boot (the keyboard) is enumerated
/// while the desktop is not yet shown — its blocking bring-up lands before the
/// cadence window instead of dropping a frame inside it. xhci.poll() drains the
/// event ring and enumerates any newly-connected port; dispatchInput keeps the
/// input rings from backing up. No render, no present.
pub fn pollInputOnly() void {
    xhci.poll();
    // Re-attempt a connected-but-not-yet-ready leaf device (the keyboard): its one
    // connect-time attempt can fail while its interface is still coming up, and no
    // fresh PSCE follows. Safe in-place retry (no reset). Settle-only.
    xhci.retryLatePorts();
    _ = dispatchInput(desktop);
}

/// One iteration of the GPU session/bring-up pump (`iaccel.Compositor.pump`):
/// poll USB HID + drain the input rings into the desktop (this is the ~kHz
/// input-sampling path — the caller loops fast), then render IF something
/// changed AND the previous flip has latched (`iaccel.Accel.flip_ready`).
/// `force_full_present` marks the whole screen dirty and skips the gate — the
/// warm-up path uses it to seed the double buffers.
pub fn desktopPump(force_full_present: bool) void {
    const d = desktop;
    prof.frameBegin();
    prof.section(.xhci);
    xhci.poll(); // drain USB HID into the keyboard/mouse rings
    prof.section(.input);
    var changed = force_full_present;
    if (force_full_present) d.markFullRepaint();
    if (dispatchInput(d)) changed = true;
    prof.section(.tick);
    if (d.tick()) changed = true;
    // Typed commands run on the cmd-worker task ONLY — never dispatched from
    // this pump. The claim in claimPendingCommand is consume-once (see
    // console/cmdtoken.zig) and this loop stays out of it entirely.
    prof.section(.cmd);
    if (changed) g_render_pending = true;
    // Render only when the previous flip has latched (gate open) — otherwise
    // keep sampling input; dirty rects accumulate in the compositor meanwhile.
    // Renders only the DIRTY regions: a full repaint every frame would CE-copy
    // the whole 19 MB frame at 60 Hz for nothing.
    //
    // render() is SYNCHRONOUS (composite + CE copy) and during a window drag its
    // dirty rects are large, so it blocks the pump for its whole duration — no
    // xhci.poll() runs meanwhile, and the cursor would advance only at the render
    // rate, in coarse steps. To keep the pointer smooth THROUGH the render, we
    // re-drain HID and re-move the HW cursor to the latest position immediately
    // AFTER the render returns, before yielding — so a queued burst of motion that
    // arrived during the render is applied to the cursor plane at once instead of
    // waiting for the next full pump iteration.
    prof.section(.render);
    // PIPELINED START on a heavy scene: the render's own duration spans the CPU
    // scene build PLUS the wait for its de-tile to land (gles.finish), so when it
    // approaches the panel's refresh period there is no time left to ALSO sit out
    // the previous flip's latch before starting — doing so pushes every present to
    // the SECOND vblank and hard-locks the desktop at half rate. The tri-ring is
    // triple-buffered exactly so the next build may begin once the previous flip
    // is merely ARMED: the compose buffer it draws into left scanout when the flip
    // BEFORE that latched, which presentDesktopFrame's one-flip-ahead guard
    // (waitFlipLatched) already guaranteed. On a light scene the latched gate is
    // kept — waiting here, where input still gets sampled, beats waiting inside
    // the present with the pointer frozen.
    const latched = if (iaccel.accel.flip_ready) |ready| ready() else true;
    const heavy = iaccel.accel.refresh_us != 0 and
        g_last_render_us + RENDER_START_SLACK_US >= iaccel.accel.refresh_us;
    const gate_open = latched or heavy;
    if (g_render_pending and (gate_open or force_full_present)) {
        // LATE-LATCH ("Session update cycle"): drain HID one final
        // time right before compositing, so a drag/motion frame reflects the NEWEST
        // pointer position — not one sampled at the top of this pump iteration (a
        // flip-interval ago). The gate may have been closed for most of a refresh
        // while input kept arriving; latching here shrinks the input→photon latency
        // to ~the composite time instead of ~a full frame.
        xhci.poll();
        while (imouse.poll()) |ev| {
            // Apply latest motion to win pos + cursor; content-changing input
            // rides the render below — latch its receipt (PERF-008).
            if (d.onMouse(ev)) iaccel.input_latch.consumed(ev.t_tsc);
        }
        g_render_pending = false;
        const t_render = tsc.rdtsc();
        d.render();
        g_last_render_us = tsc.elapsedUs(t_render);
        // Catch the cursor up to any motion that queued during the blocking render.
        xhci.poll();
        while (imouse.poll()) |ev| {
            if (d.onMouse(ev)) {
                g_render_pending = true; // more content to draw next iter
                iaccel.input_latch.consumed(ev.t_tsc); // …judged at that present (PERF-008)
            }
        }
    }
    // SMP: this pump is driven by the GPU session loop, which (unlike systemLoop)
    // is core 0's ONLY loop on a native boot. Yield to the scheduler each iteration
    // so core 0's #0> terminal task and the cmd-worker time-share the core — without
    // this the session loop monopolizes core 0 and its terminal never drains the
    // keystrokes routed to it. Single-core has no other
    // task to run, so it never yields.
    prof.section(.yield);
    if (buildinfo.smp) smp.yieldCpu();
    prof.frameEnd();
}
