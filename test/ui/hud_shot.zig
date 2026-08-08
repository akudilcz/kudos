//! A picture of the heads-up display, rendered on the host.
//!
//! The display's view is a pure function of a snapshot, so it can be drawn without
//! a machine to read: this fabricates a plausible one for each screen kudos is put
//! on — a busy core, a heap that has been leaking for half a minute, a HID fault
//! counter that has ticked, and the core matrix that screen's machine brings — and
//! renders it through the REAL painter, lowered into the software rasteriser. The
//! result is a PPM: the layout can be reviewed, and a regression seen, on a laptop
//! with no GPU, no QEMU and no kudos running.
//!
//! Run it with `zig build hud-shot`, which writes build/hud_shot.ppm.
//!
//! It is also the display's layout test: the assertions below fail the build if a
//! band escapes the screen or a panel collapses, so a screenshot nobody looks at
//! still catches the geometry going wrong.

const std = @import("std");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");
const kgl = @import("kgl");
const rects = @import("rects");
const typeface = @import("typeface");
const hudview = @import("hudview");

/// The pages the display is taken as: a screen, and the machine that drives it.
/// The pairing is the claim — a full page is a page a real machine puts on the
/// real screen it is attached to — and the core count is the half of the machine
/// that changes the page's shape, because the core matrix is the only band that
/// grows with the hardware. The desk machine fills the matrix to the display's
/// ceiling; the small screen is a `-Dsoft-display` dev build, which comes with
/// the laptop's smaller core count and is the screen the page must set itself a
/// step smaller for.
const Shape = struct { w: u32, h: u32, cores: u32, path: []const u8 };
const SHAPES = [_]Shape{
    .{ .w = 1920, .h = 1080, .cores = DESK_CORES, .path = "build/hud_shot.ppm" },
    .{ .w = 1280, .h = 800, .cores = LAPTOP_CORES, .path = "build/hud_shot_small.ppm" },
    // The desk-wide panel: the roomiest shape the desk machine is seen on, where
    // the core tiles grow past their smallest and the memory ribbon breathes.
    .{ .w = 3440, .h = 1440, .cores = DESK_CORES, .path = "build/hud_shot_wide.ppm" },
};

/// Cores the desk machine brings up: the display's ceiling, which is the matrix
/// kudos' own target fills (a 32-thread desktop).
const DESK_CORES: u32 = hudview.MAX_CORES;
/// Cores a laptop dev build brings up — a smaller matrix on a smaller screen.
const LAPTOP_CORES: u32 = 16;

fn screenOf(sp: Shape) rects.Rect {
    return .{ .x = 0, .y = 0, .w = @floatFromInt(sp.w), .h = @floatFromInt(sp.h) };
}

// ── the fabricated machine ──────────────────────────────────────────────────────

const GIB: u64 = 1024 * 1024 * 1024;
const MIB: u64 = 1024 * 1024;

fn cores(s: *hudview.Snapshot, n: u32) void {
    const Spec = struct { busy: u32, task: []const u8, act: []const u8, rq: u32 };
    const named = [_]Spec{
        .{ .busy = 71, .task = "desktop", .act = "present", .rq = 2 },
        .{ .busy = 88, .task = "vcpu0", .act = "guest", .rq = 0 },
        .{ .busy = 12, .task = "term1", .act = "shell", .rq = 1 },
        .{ .busy = 34, .task = "term2", .act = "net fetch", .rq = 1 },
        .{ .busy = 9, .task = "netpump", .act = "rx drain", .rq = 0 },
        .{ .busy = 21, .task = "agent", .act = "compile", .rq = 0 },
        .{ .busy = 0, .task = "idle", .act = "", .rq = 0 },
        .{ .busy = 1, .task = "idle", .act = "", .rq = 0 },
    };
    s.cores_online = n;
    // Past the named work the machine is idle, at the small wandering occupancy
    // an idle core actually reads at — a matrix of flat zeroes would hide a tile
    // that failed to draw its figure.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const sp = if (i < named.len) named[i] else Spec{
            .busy = @intCast((i * 7) % 5),
            .task = "idle",
            .act = "",
            .rq = 0,
        };
        var line = hudview.CoreLine{ .online = true, .is_bsp = i == 0, .busy_pct = sp.busy, .runnable = sp.rq };
        line.setTask(sp.task, sp.act);
        s.cores[i] = line;
    }
    s.busy_pct = 37;
}

fn counters(s: *hudview.Snapshot) void {
    const C = struct { g: hudview.Group, n: []const u8, v: u64, r: f64 };
    const list = [_]C{
        .{ .g = .usb, .n = "kbd_reports", .v = 41208, .r = 18 },
        .{ .g = .usb, .n = "mouse_reports", .v = 88471, .r = 62 },
        .{ .g = .usb, .n = "ev.consumed", .v = 131902, .r = 80 },
        .{ .g = .usb, .n = "ev.xfer", .v = 129660, .r = 79 },
        .{ .g = .usb, .n = "ev.psc", .v = 14, .r = 0 },
        .{ .g = .usb, .n = "hid.queued", .v = 2, .r = 0 },
        .{ .g = .usb, .n = "hid.orphan", .v = 2, .r = 0.4 },
        .{ .g = .usb, .n = "hid.badcc", .v = 0, .r = 0 },
        .{ .g = .usb, .n = "mouse.drops", .v = 0, .r = 0 },
        .{ .g = .usb, .n = "key.inject_drops", .v = 0, .r = 0 },
        .{ .g = .net, .n = "rx.frames", .v = 418902, .r = 96 },
        .{ .g = .net, .n = "netdebug.fifo_drops", .v = 0, .r = 0 },
        .{ .g = .net, .n = "kmr1.reqs", .v = 1044, .r = 2 },
        .{ .g = .net, .n = "kmr1.service", .v = 1044, .r = 2 },
        .{ .g = .net, .n = "kmr1.reply_sent", .v = 1041, .r = 2 },
        .{ .g = .net, .n = "kmr1.reply_none", .v = 3, .r = 0 },
        .{ .g = .net, .n = "kmr1.busy_drops", .v = 0, .r = 0 },
        .{ .g = .net, .n = "kmr1.reply_senderr", .v = 0, .r = 0 },
        .{ .g = .gpu_ui, .n = "frame_drops", .v = 3, .r = 0 },
        .{ .g = .gpu_ui, .n = "input_present_max_us", .v = 11340, .r = 0 },
        .{ .g = .gpu_ui, .n = "input_present_over_budget", .v = 0, .r = 0 },
        .{ .g = .gpu_ui, .n = "sess.commits", .v = 211, .r = 0 },
        .{ .g = .gpu_ui, .n = "sess.recalls", .v = 58, .r = 0 },
        .{ .g = .gpu_ui, .n = "sess.recall_empty", .v = 4, .r = 0 },
        .{ .g = .gpu_ui, .n = "key.drops", .v = 0, .r = 0 },
        .{ .g = .kernel, .n = "irq.spurious", .v = 0, .r = 0 },
        .{ .g = .kernel, .n = "session_faults", .v = 0, .r = 0 },
        .{ .g = .kernel, .n = "spin_exceeded", .v = 0, .r = 0 },
    };
    for (list, 0..) |c, i| {
        s.counters[i] = .{ .group = c.g, .name = c.n, .value = c.v, .per_second = c.r };
        if (hudview.isFault(c.n) and c.v > 0) s.faults += 1;
    }
    s.counter_count = list.len;
}

fn snapshot(sp: Shape) hudview.Snapshot {
    var s = hudview.Snapshot{
        .taken_ms = 4 * 3600_000 + 17 * 60_000 + 36_000,
        .seconds_since_midnight = 14 * 3600 + 32 * 60 + 7,
        .tsc_hz = 3_187_000_000,
        .mem_total = 64 * GIB,
        .mem_used = 18 * GIB + 400 * MIB,
        .heap_arena = 512 * MIB,
        .heap_used = 148 * MIB,
        .heap_free = 364 * MIB,
        .heap_largest = 312 * MIB,
        .heap_blocks = 39,
        .ramdisk_files = 9,
        .ramdisk_bytes = 38 * MIB,
        .fps = 60,
        .presents = 1284913,
        .pump_avg_us = 14900,
        .pump_max_us = 15850,
        .refresh_us = 16667,
        .link_up = true,
        .ip = .{ 10, 55, 0, 62 },
        .tx_dropped = 0,
        .kbd = true,
        .mouse = true,
        .usbdisk = true,
        .kbd_reports = 41208,
        .mouse_reports = 88471,
        .vt_available = true,
        .guests_running = 1,
        .guest_capacity = 4,
        .guest_exits = 88401227,
    };
    @memcpy(&s.vendor, "GenuineIntel");
    cores(&s, sp.cores);
    counters(&s);
    return s;
}

/// Traces with plausible shape: frame time steady with one spike, cpu wandering,
/// heap stepping down (a leak), network bursty.
const Traces = struct {
    frame_ms: hudview.Series = .{},
    cpu_busy: hudview.Series = .{},
    heap_free: hudview.Series = .{},
    net_rx: hudview.Series = .{},

    fn fill(self: *Traces) void {
        var i: usize = 0;
        while (i < hudview.HISTORY) : (i += 1) {
            const t: u64 = i * hudview.SAMPLE_MS;
            const f: f64 = @floatFromInt(i);
            const wave = @sin(f * 0.7) * 0.6;
            self.frame_ms.push(if (i == 41) 24.8 else 14.9 + wave * 0.5, t);
            self.cpu_busy.push(34 + wave * 12 + @sin(f * 0.21) * 9, t);
            self.heap_free.push(402 - f * 0.63, t); // a leak, plain to see
            self.net_rx.push(@max(0, 90 + @sin(f * 0.9) * 60 + @sin(f * 0.13) * 25), t);
        }
    }

    fn refs(self: *const Traces) hudview.Traces {
        return .{
            .frame_ms = &self.frame_ms,
            .cpu_busy = &self.cpu_busy,
            .heap_free = &self.heap_free,
            .net_rx = &self.net_rx,
        };
    }
};

// ── the shot ────────────────────────────────────────────────────────────────────

fn writePpm(g: *gles.Context, sp: Shape) !void {
    const cs: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
    const bgra = cs.color;
    const tio = std.testing.io;
    var file = try std.Io.Dir.cwd().createFile(tio, sp.path, .{});
    defer file.close(tio);
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(tio, &wbuf);
    const w = &fw.interface;
    try w.print("P6\n{d} {d}\n255\n", .{ sp.w, sp.h });
    var i: usize = 0;
    while (i < @as(usize, sp.w) * sp.h) : (i += 1) {
        try w.writeByte(bgra[i * 4 + 2]); // R
        try w.writeByte(bgra[i * 4 + 1]); // G
        try w.writeByte(bgra[i * 4 + 0]); // B
    }
    try w.flush();
}

test "the layout puts every band on the screen, at every page it is shipped for" {
    try typeface.init(std.heap.page_allocator);
    for (SHAPES) |sp| {
        errdefer std.debug.print("{d} cores at {d}x{d}\n", .{ sp.cores, sp.w, sp.h });
        const s = snapshot(sp);
        const scr = screenOf(sp);
        const sc = hudview.scaleFor(scr);
        const l = hudview.layout(scr, sc, hudview.demandOf(&s, sc));
        const bands = [_]rects.Rect{ l.vitals, l.silicon, l.memory, l.io, l.traces, l.counters, l.footer };
        for (bands) |b| {
            try std.testing.expect(!b.isEmpty());
            try std.testing.expect(b.x >= 0 and b.y >= 0);
            try std.testing.expect(b.right() <= scr.right() + 0.01);
            try std.testing.expect(b.bottom() <= scr.bottom() + 0.01);
        }
        // The three middle columns tile their band without overlapping.
        try std.testing.expect(l.silicon.right() <= l.memory.x);
        try std.testing.expect(l.memory.right() <= l.io.x);
        // The bands stack in reading order.
        try std.testing.expect(l.vitals.bottom() <= l.silicon.y);
        try std.testing.expect(l.silicon.bottom() <= l.traces.y);
        try std.testing.expect(l.traces.bottom() <= l.counters.y);
        try std.testing.expect(l.counters.bottom() <= l.footer.y);
    }
}

test "every whole page fits its screen, with nothing hidden (HUD-001)" {
    // The point of the type step: at 1080p and at a laptop's panel alike, the
    // panels get the room their readings need and the wall gets the room its
    // counters need. A page that had to hide a row here would be a page the type
    // scale chose wrongly for — and the core matrix is the band that grows with
    // the machine, so the type step has to be chosen for the matrix the screen's
    // own machine brings, not for a smaller one.
    try typeface.init(std.heap.page_allocator);
    for (SHAPES) |sp| {
        errdefer std.debug.print("{d} cores at {d}x{d}\n", .{ sp.cores, sp.w, sp.h });
        const s = snapshot(sp);
        const scr = screenOf(sp);
        const sc = hudview.scaleFor(scr);
        const d = hudview.demandOf(&s, sc);
        const l = hudview.layout(scr, sc, d);
        try std.testing.expect(l.silicon.h + 0.01 >= d.panels);
        try std.testing.expect(l.counters.h + 0.01 >= d.counters);
        // The bands being big enough is the arithmetic; this is the fills
        // themselves saying they placed every reading they were given.
        try std.testing.expectEqual(@as(usize, 0), hudview.hiddenBy(&s, sc, l));
    }
}

test "a page too full for its screen gives way in priority order, counting what it hid" {
    // The pairings above are the machines kudos is put on; this is what the page
    // does when it meets one it was not sized for — the desk machine's full
    // matrix on the small screen, which no type step on the ladder can hold.
    // The readings the display exists for keep their room, the traces starve,
    // and the counter wall says how many rows it could not show. Silence is the
    // one failure mode a diagnostic screen may not have.
    try typeface.init(std.heap.page_allocator);
    var over = SHAPES[1];
    over.cores = DESK_CORES;
    const s = snapshot(over);
    const scr = screenOf(over);
    const sc = hudview.scaleFor(scr);
    const d = hudview.demandOf(&s, sc);
    const l = hudview.layout(scr, sc, d);
    // The panels are never traded away: the silicon, memory and IO readings are
    // all still placed.
    try std.testing.expect(l.silicon.h + 0.01 >= d.panels);
    for ([_]rects.Rect{ l.silicon, l.memory, l.io }) |b| {
        try std.testing.expect(b.bottom() <= scr.bottom() + 0.01);
    }
    // What gave way, gave way in order — and was counted.
    try std.testing.expect(l.traces.h < sc.trace_min_h);
    try std.testing.expect(l.counters.h < d.counters);
    try std.testing.expect(hudview.hiddenBy(&s, sc, l) > 0);
}

// ── every presented datum reaches the pixels ────────────────────────────────────

/// The page the probes below are rendered as: the smallest screen kudos ships
/// for, with the machine that drives it — the cheapest of the three, and the
/// tightest, so a datum that only reaches the pixels when there is room to
/// spare is caught here.
const PROBE_SHAPE = SHAPES[1];

/// Render the page once and hash the raster. Two snapshots that should read
/// differently must paint differently, or the display is not presenting the
/// datum that changed — this is what "shall present X" means, made falsifiable
/// without a golden image. The laptop shape keeps the ~20 renders cheap.
fn renderHash(ta: std.mem.Allocator, s: *const hudview.Snapshot, tr: hudview.Traces, opts: hudview.Options) !u64 {
    const sp = PROBE_SHAPE;
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = sp.w, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);
    gles.beginFrame(&g, sp.w, sp.h);
    const sheet = typeface.sheetBytes();
    const la = try ta.alloc(u8, sheet.len * 2);
    defer ta.free(la);
    typeface.expandToLuminanceAlpha(la);
    const sheet_tex = kgl.uploadAtlas(&g, typeface.SHEET_W, typeface.sheetHeight(), la);
    p.begin(&g, sp.w, sp.h);
    p.fillRect(0, 0, @floatFromInt(sp.w), @floatFromInt(sp.h), 0xFF1E4E8C);
    hudview.draw(&p, sheet_tex, screenOf(sp), s, tr, opts);
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);
    const cs: *raster.SoftCtx = @ptrCast(@alignCast(g.target.ctx));
    return std.hash.XxHash64.hash(0, cs.color[0 .. @as(usize, sp.w) * sp.h * 4]);
}

const Probe = struct {
    what: []const u8,
    mutate: *const fn (s: *hudview.Snapshot, tr: *Traces, o: *hudview.Options) void,
};

fn probe(comptime what: []const u8, comptime m: fn (s: *hudview.Snapshot, tr: *Traces, o: *hudview.Options) void) Probe {
    return .{ .what = what, .mutate = m };
}

test "every presented datum reaches the pixels: a changed value is a changed page" {
    const ta = std.testing.allocator;
    try typeface.init(ta);
    var base_tr = Traces{};
    base_tr.fill();
    const base_s = snapshot(PROBE_SHAPE);
    const base_o = hudview.Options{ .alarm = base_s.faults > 0, .now_ms = base_s.taken_ms + 320 };
    const base = try renderHash(ta, &base_s, base_tr.refs(), base_o);
    // Determinism first: the same inputs must repaint the same page, or every
    // probe below is noise.
    try std.testing.expectEqual(base, try renderHash(ta, &base_s, base_tr.refs(), base_o));

    const S = hudview.Snapshot;
    const O = hudview.Options;
    const probes = [_]Probe{
        // HUD-005: the number of processor cores online.
        probe("cores online (HUD-005)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.cores_online = 3; }
        }.m),
        // HUD-006: each core's occupancy over the last sampling interval.
        probe("core occupancy (HUD-006)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.cores[0].busy_pct = 5; }
        }.m),
        // HUD-007: the task scheduled on each core.
        probe("task on core (HUD-007)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.cores[1].setTask("watchdog", "idle"); }
        }.m),
        // HUD-008: the number of tasks waiting to run on each core.
        probe("run-queue depth (HUD-008)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.cores[2].runnable = 9; }
        }.m),
        // HUD-009: total, used and free physical memory.
        probe("physical memory (HUD-009)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.mem_used = 40 * GIB; }
        }.m),
        // HUD-010: physical memory divided by the purpose it is held for.
        probe("memory by purpose (HUD-010)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.ramdisk_bytes = 300 * MIB; }
        }.m),
        // HUD-011: the kernel heap's size, used and free bytes.
        probe("kernel heap (HUD-011)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.heap_used = 300 * MIB; s.heap_free = 212 * MIB; }
        }.m),
        // HUD-012: the largest allocation the heap could still satisfy.
        probe("largest allocation (HUD-012)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.heap_largest = 12 * MIB; }
        }.m),
        // HUD-015: the display's present rate (the dropped-frame count is the
        // frame_drops counter on the wall, probed as HUD-019's row family).
        probe("present rate (HUD-015)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.fps = 31; }
        }.m),
        // HUD-017: the network link state and address lease.
        probe("link + leased address (HUD-017)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.link_up = false; s.ip = .{ 0, 0, 0, 0 }; }
        }.m),
        // HUD-018: the guest VM's state and exit rate while one runs.
        probe("guest state (HUD-018)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.guests_running = 0; s.guest_exits = 0; }
        }.m),
        // HUD-019: the value of every diagnostic counter.
        probe("counter value (HUD-019)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.counters[12].value = 999_999_999; }
        }.m),
        // HUD-021: the time of day.
        probe("time of day (HUD-021)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.seconds_since_midnight = 3 * 3600 + 5; }
        }.m),
        // HUD-022: the time elapsed since boot (age display pinned so only the
        // elapsed value changes).
        probe("time since boot (HUD-022)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; s.taken_ms = 100_000; o.now_ms = 100_320; }
        }.m),
        // HUD-024: rolling history of frame time.
        probe("frame-time trace (HUD-024)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = s; _ = o; tr.frame_ms = .{}; }
        }.m),
        // HUD-025: rolling history of processor occupancy.
        probe("cpu trace (HUD-025)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = s; _ = o; tr.cpu_busy = .{}; }
        }.m),
        // HUD-026: rolling history of free kernel heap.
        probe("heap trace (HUD-026)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = s; _ = o; tr.heap_free = .{}; }
        }.m),
        // HUD-027: rolling history of received network traffic.
        probe("net-rx trace (HUD-027)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = s; _ = o; tr.net_rx = .{}; }
        }.m),
        // HUD-028: the visible alarm a fault counter raises.
        probe("alarm visibility (HUD-028)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = s; _ = tr; o.alarm = false; }
        }.m),
        // HUD-031: the time at which the shown values were sampled.
        probe("sample age (HUD-031)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; o.now_ms = s.taken_ms + 9_000; }
        }.m),
        // HUD-030's visible half: a frozen display says so on the page.
        probe("frozen banner (HUD-030)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = s; _ = tr; o.frozen = true; }
        }.m),
        // A meter crossing its threshold recolours (the near-full heap).
        probe("meter threshold recolour", struct {
            fn m(s: *S, tr: *Traces, o: *O) void {
                _ = tr; _ = o;
                s.heap_used = s.heap_arena - MIB;
                s.heap_free = MIB;
            }
        }.m),
        // An emptied io panel: absent volumes and devices leave no ghost rows.
        probe("empty io panel", struct {
            fn m(s: *S, tr: *Traces, o: *O) void {
                _ = tr; _ = o;
                s.usbdisk = false; s.ramdisk_files = 0; s.ramdisk_bytes = 0;
                s.kbd = false; s.mouse = false; s.link_up = false;
            }
        }.m),
        // HUD-004: the processor's make — the CPUID vendor string.
        probe("cpu make (HUD-004)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; @memcpy(&s.vendor, "AuthenticAMD"); }
        }.m),
        // HUD-016: each mounted volume and the bytes it holds.
        probe("mounted volumes (HUD-016)", struct {
            fn m(s: *S, tr: *Traces, o: *O) void { _ = tr; _ = o; s.usbdisk = false; s.ramdisk_files = 2; }
        }.m),
    };

    for (probes) |pr| {
        var s = snapshot(PROBE_SHAPE);
        var tr = Traces{};
        tr.fill();
        var o = hudview.Options{ .alarm = s.faults > 0, .now_ms = s.taken_ms + 320 };
        pr.mutate(&s, &tr, &o);
        const h = try renderHash(ta, &s, tr.refs(), o);
        if (h == base) {
            std.debug.print("datum not presented: {s}\n", .{pr.what});
            return error.DatumNotPresented;
        }
    }
}

test "render the heads-up display through kgl + Soft and write a screenshot" {
    const ta = std.testing.allocator;
    try typeface.init(ta);

    // The software rasteriser IS the draw device for this fixture — the one place
    // it is ever published outside the GPU bring-up (see CLAUDE.md: soft.zig is a
    // host-test fixture, never the kernel's path).
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();

    var traces = Traces{};
    traces.fill();
    std.Io.Dir.cwd().createDirPath(std.testing.io, "build") catch {};

    for (SHAPES) |sp| {
        // Each picture is of the machine that screen belongs to, so the shot of
        // the desk panel is a shot of the matrix kudos' own target fills.
        const s = snapshot(sp);
        var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = sp.w, .off_x = 0, .off_y = 0 }) orelse
            return error.NoDevice;
        defer g.deinit();
        var p = try kgl.Painter.init(ta);
        defer p.deinit(ta);

        gles.beginFrame(&g, sp.w, sp.h);

        // The typeface sheet, uploaded exactly as the kernel uploads it.
        const sheet = typeface.sheetBytes();
        const la = try ta.alloc(u8, sheet.len * 2);
        defer ta.free(la);
        typeface.expandToLuminanceAlpha(la);
        const sheet_tex = kgl.uploadAtlas(&g, typeface.SHEET_W, typeface.sheetHeight(), la);

        p.begin(&g, sp.w, sp.h);
        // A stand-in for the desktop underneath: the display draws its own scrim
        // over whatever is there, and a flat field shows how much survives.
        p.fillRect(0, 0, @floatFromInt(sp.w), @floatFromInt(sp.h), 0xFF1E4E8C);

        hudview.draw(&p, sheet_tex, screenOf(sp), &s, traces.refs(), .{
            .alarm = s.faults > 0,
            .now_ms = s.taken_ms + 320,
        });
        p.end();
        gles.swapBuffers(&g);
        gles.finish(&g);

        try writePpm(&g, sp);
    }
}
