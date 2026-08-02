//! The heads-up display's SAMPLER (spec HUD-001..032): it reads the machine at a
//! fixed cadence into a snapshot, holds the traces, and owns the display's own
//! state — shown, frozen, alarm latched. The drawing is somewhere else on purpose
//! (widgets/hudview.zig): a value in, a picture out, host-testable and
//! screenshot-able off-target.
//!
//! Reading costs a walk of the counter registry and of the heap's free list, so it
//! happens twice a second, never per frame, and not at all while the display is
//! hidden or frozen. A frame therefore costs geometry, not telemetry — which is
//! what makes it safe to put on the compositor's path.

const std = @import("std");
const kgl = @import("kgl");
const rects = @import("rects");
const hudview = @import("hudview");
const hudcontrol = @import("hudcontrol"); // the pure control state + rate arithmetic
const framebuffer = @import("../screen/framebuffer.zig");

const pmm = @import("../../kernel/memory/pmm.zig");
const heap = @import("../../kernel/memory/heap.zig");
const smp = @import("../../kernel/smp/smp.zig");
const percpu = @import("../../kernel/sched/percpu.zig");
const sched = @import("../../kernel/sched/sched.zig");
const taskstat = @import("../../kernel/sched/taskstat.zig");
const cpustat = @import("../../kernel/sched/cpustat.zig");
const cpu = @import("../../kernel/cpu/cpu.zig");
const tsc = @import("../../kernel/cpu/tsc.zig");
const timer = @import("../../kernel/timer/timer.zig");
const wallclock = @import("../../kernel/timer/wallclock.zig");
const counter = @import("../../kernel/debug/counter.zig");
const gate = @import("../../kernel/debug/gate.zig");
const virt = @import("../../kernel/virt/virt.zig");
const iaccel = @import("iaccel");
const idevices = @import("idevices");
const iramdisk = @import("iramdisk");
const inet = @import("inet");

/// Sampling period — the display's cadence and the denominator of every rate.
pub const SAMPLE_MS = hudview.SAMPLE_MS;
/// Tasks read per core when looking for the one that is running.
const TASKS_PER_CORE = 8;

/// Control state and sampling clock — the decisions live in hudcontrol, where
/// they are host-tested; this module owns only the machine they sample.
var ctl = hudcontrol.Control{};
var snap: hudview.Snapshot = .{};

/// Previous per-core TSC readings. Occupancy is differenced HERE, against our own
/// previous reading, because `sched.cpuPercentSince` CONSUMES the window it reads
/// — sharing it with `ps` would leave both showing half the truth.
var prev_busy: [hudview.MAX_CORES]u64 = [_]u64{0} ** hudview.MAX_CORES;
var prev_idle: [hudview.MAX_CORES]u64 = [_]u64{0} ** hudview.MAX_CORES;
/// Previous counter totals, in registry order, for the per-second rates.
var prev_counter: [hudview.MAX_COUNTERS]u64 = [_]u64{0} ** hudview.MAX_COUNTERS;
var have_prev = false;
/// When the last sample's counter readings were taken. Distinct from the
/// control's scheduling clock: `due` advances that BEFORE the sample runs, and
/// a rate divided by zero elapsed time is not a rate.
var rate_base_ms: u64 = 0;

var frame_ms = hudview.Series{};
var cpu_busy = hudview.Series{};
var heap_free = hudview.Series{};
var net_rx = hudview.Series{};

// ── control ─────────────────────────────────────────────────────────────────────

/// Whether the display is on screen.
pub fn visible() bool {
    return ctl.shown;
}

/// Show or hide (HUD-002). Showing samples immediately, so the display is never
/// blank for half a second when it appears.
pub fn toggle() void {
    if (ctl.toggle(timer.millis())) sampleNow();
}

/// Stop or resume sampling (HUD-030).
pub fn toggleFreeze() void {
    ctl.toggleFreeze();
}

/// Whether sampling is stopped.
pub fn isFrozen() bool {
    return ctl.frozen;
}

/// Acknowledge the alarm (HUD-029).
pub fn acknowledgeAlarm() void {
    ctl.acknowledge();
}

/// Keys the display consumes while it is shown. Returns true when the key was
/// the display's, so the caller does not also hand it to the focused window.
pub fn onKey(ascii: u8) bool {
    if (!ctl.shown) return false;
    switch (ascii) {
        'a', 'A' => acknowledgeAlarm(),
        'f', 'F' => toggleFreeze(),
        else => return false,
    }
    return true;
}

/// Sample if the period has elapsed. Called from the desktop's tick; returns true
/// when a new sample landed, which is this display's redraw request (HUD-032).
pub fn tick() bool {
    if (!ctl.due(timer.millis())) return false;
    sampleNow();
    return true;
}

/// Draw the display over the whole screen (HUD-003).
pub fn draw(p: *kgl.Painter, sheet_tex: u32) void {
    if (!ctl.shown) return;
    const screen: rects.Rect = .{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(framebuffer.width()),
        .h = @floatFromInt(framebuffer.height()),
    };
    hudview.draw(p, sheet_tex, screen, &snap, .{
        .frame_ms = &frame_ms,
        .cpu_busy = &cpu_busy,
        .heap_free = &heap_free,
        .net_rx = &net_rx,
    }, .{
        .frozen = ctl.frozen,
        .alarm = ctl.alarm,
        .now_ms = timer.millis(),
    });
}

// ── sampling ────────────────────────────────────────────────────────────────────

fn sampleNow() void {
    const now = timer.millis();
    // Sampled straight into the module-owned snapshot — no stack copy. The
    // Snapshot is tens of KiB; a by-value local here joined the per-frame
    // render path's stack frame. Single writer, same-task reader (the draw
    // later in the same pump), so in-place assembly is race-free.
    snap = .{
        .taken_ms = now,
        .seconds_since_midnight = wallclock.secondsSinceMidnight(),
        .tsc_hz = tsc.hz(),
    };
    vendorInto(&snap.vendor);

    sampleCores(&snap);
    sampleMemory(&snap);
    sampleDisplay(&snap);
    sampleIo(&snap);
    sampleCounters(&snap, now);

    // The traces. Frame time is the compositor's own build average — the figure
    // the 60 Hz gate is judged against, so the trace and the gate agree.
    frame_ms.push(@as(f64, @floatFromInt(snap.pump_avg_us)) / 1000.0, now);
    cpu_busy.push(@floatFromInt(snap.busy_pct), now);
    heap_free.push(@as(f64, @floatFromInt(snap.heap_free)) / (1024.0 * 1024.0), now);

    rate_base_ms = now;
    have_prev = true;
}

fn sampleCores(s: *hudview.Snapshot) void {
    s.cores_online = smp.coresOnline();
    var total_busy: u64 = 0;
    var total_idle: u64 = 0;

    var i: usize = 0;
    while (i < hudview.MAX_CORES and i < s.cores_online) : (i += 1) {
        const pc = percpu.at(@intCast(i));
        var line = hudview.CoreLine{ .online = true, .is_bsp = pc.is_bsp };

        const busy = pc.busy_tsc;
        const idle = pc.idle_tsc;
        if (have_prev) {
            const dbusy = busy -% prev_busy[i];
            const didle = idle -% prev_idle[i];
            line.busy_pct = cpustat.busyPercent(dbusy, didle);
            total_busy +%= dbusy;
            total_idle +%= didle;
        }
        prev_busy[i] = busy;
        prev_idle[i] = idle;

        var tasks: [TASKS_PER_CORE]taskstat.TaskInfo = undefined;
        const n = taskstat.snapshotTasks(@intCast(i), &tasks);
        var runnable: u32 = 0;
        for (tasks[0..n]) |t| {
            if (t.is_current) {
                line.setTask(t.nameSlice(), t.activitySlice());
            } else if (t.state == .runnable) {
                runnable += 1;
            }
        }
        line.runnable = runnable;
        s.cores[i] = line;
    }
    s.busy_pct = cpustat.busyPercent(total_busy, total_idle);
}

fn sampleMemory(s: *hudview.Snapshot) void {
    s.mem_total = pmm.totalBytes();
    s.mem_used = pmm.usedBytes();
    const h = heap.stats();
    s.heap_arena = h.arena;
    s.heap_used = h.used;
    s.heap_free = h.free;
    s.heap_largest = h.largest;
    s.heap_blocks = h.free_blocks;

    if (iramdisk.instance) |rd| {
        s.ramdisk_files = rd.count();
        var i: usize = 0;
        while (i < s.ramdisk_files) : (i += 1) s.ramdisk_bytes +%= rd.at(i).data.len;
    }
}

fn sampleDisplay(s: *hudview.Snapshot) void {
    const fs = iaccel.frame_stats;
    s.fps = fs.fps;
    s.pump_avg_us = fs.pump_avg_us;
    s.pump_max_us = fs.pump_max_us;
    s.refresh_us = iaccel.accel.refresh_us;
}

fn sampleIo(s: *hudview.Snapshot) void {
    if (inet.instance) |n| {
        s.link_up = n.isUp();
        if (s.link_up) s.ip = n.lease().ip;
    }
    if (idevices.txDropped()) |d| {
        s.tx_dropped = d;
        s.tx_dropped_known = true;
    }
    const usb = idevices.usbStatus();
    s.usb_devices = usb.devices;
    s.kbd = usb.keyboard;
    s.mouse = usb.mouse;
    s.usbdisk = usb.usbdisk;
    s.kbd_reports = usb.kbd_reports;
    s.mouse_reports = usb.mouse_reports;

    const v = virt.status();
    s.vt_available = v.available;
    s.guests_running = v.in_use;
    s.guest_capacity = v.capacity;
    var guests: [hudview.MAX_GUESTS]virt.GuestInfo = undefined;
    const n = virt.snapshot(&guests);
    for (guests[0..n]) |g| s.guest_exits +%= g.exits;
}

fn sampleCounters(s: *hudview.Snapshot, now: u64) void {
    const all = counter.all();
    const n = @min(all.len, hudview.MAX_COUNTERS);
    const dt_ms = if (have_prev) now -% rate_base_ms else 0;
    var faults: u32 = 0;
    var rx_total: u64 = 0;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const c = all[i];
        s.counters[i] = .{
            .group = groupOf(c.mod),
            .name = c.name,
            .value = c.v,
            .per_second = hudcontrol.ratePerSecond(prev_counter[i], c.v, dt_ms, have_prev),
        };
        prev_counter[i] = c.v;
        if (hudview.isFault(c.name) and c.v > 0) faults += 1;
        if (std.mem.eql(u8, c.name, "rx.frames")) rx_total = c.v;
    }
    s.counter_count = n;
    s.faults = faults;
    ctl.observeFaults(faults);
    net_rx.pushCounter(rx_total, now);
}

/// Which column of the counter wall a module's counters belong in. The registry
/// has more module tags than the wall has columns, and the leftovers are all
/// kernel-side, so they share one.
fn groupOf(m: gate.Mod) hudview.Group {
    return switch (m) {
        .usb => .usb,
        .net => .net,
        .gpu, .ui => .gpu_ui,
        else => .kernel,
    };
}

/// The 12-character vendor string from CPUID leaf 0 (EBX, EDX, ECX in that order).
fn vendorInto(dst: *[12]u8) void {
    const r = cpu.cpuid(0, 0);
    writeReg(dst[0..4], r.ebx);
    writeReg(dst[4..8], r.edx);
    writeReg(dst[8..12], r.ecx);
}

fn writeReg(dst: *[4]u8, v: u32) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
    dst[2] = @truncate(v >> 16);
    dst[3] = @truncate(v >> 24);
}
