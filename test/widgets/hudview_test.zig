//! Host tests for the heads-up display's view: the page divides into bands that
//! stay on the screen and in reading order, it is set at the largest type step
//! the screen can hold a full page at, the bands that can give room up do so in
//! the stated order, and every label it draws is one the typeface can draw.
//!
//! The picture itself is `zig build hud-shot` (test/ui/hud_shot.zig); this is the
//! geometry and the policy under it.

const std = @import("std");
const hudview = @import("hudview");
const rects = @import("rects");
const typeface = @import("typeface");

const wide: rects.Rect = .{ .x = 0, .y = 0, .w = 3440, .h = 1440 };
const laptop: rects.Rect = .{ .x = 0, .y = 0, .w = 1280, .h = 800 };
const qemu: rects.Rect = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
const tiny: rects.Rect = .{ .x = 0, .y = 0, .w = 1024, .h = 600 };

/// A machine with enough of everything that every band has something to ask for.
/// Its matrix is full, because that is the page the type step is chosen for: a
/// layout checked only against a small machine is a layout checked against a
/// page kudos' own hardware never draws.
fn machine(counters: usize) hudview.Snapshot {
    var s = hudview.Snapshot{ .cores_online = hudview.MAX_CORES, .mem_total = 64 << 30, .mem_used = 18 << 30 };
    var i: usize = 0;
    while (i < counters) : (i += 1) {
        s.counters[i] = .{ .group = .usb, .name = "ev.consumed", .value = 1 };
    }
    s.counter_count = counters;
    return s;
}

fn layoutOf(screen: rects.Rect, counters: usize) hudview.Layout {
    const s = machine(counters);
    const sc = hudview.scaleFor(screen);
    return hudview.layout(screen, sc, hudview.demandOf(&s, sc));
}

fn bands(l: hudview.Layout) [7]rects.Rect {
    return .{ l.vitals, l.silicon, l.memory, l.io, l.traces, l.counters, l.footer };
}

test "every band stays inside the screen, at every size the desktop runs at" {
    try typeface.init(std.heap.page_allocator);
    for ([_]rects.Rect{ wide, laptop, qemu, tiny }) |screen| {
        const l = layoutOf(screen, 12);
        for (bands(l)) |b| {
            try std.testing.expect(b.x >= screen.x);
            try std.testing.expect(b.y >= screen.y);
            try std.testing.expect(b.right() <= screen.right() + 0.01);
            try std.testing.expect(b.bottom() <= screen.bottom() + 0.01);
            try std.testing.expect(b.w >= 0 and b.h >= 0);
        }
    }
}

test "the bands stack in reading order and never overlap" {
    try typeface.init(std.heap.page_allocator);
    for ([_]rects.Rect{ wide, laptop, qemu, tiny }) |screen| {
        const l = layoutOf(screen, 12);
        try std.testing.expect(l.vitals.bottom() <= l.silicon.y);
        try std.testing.expect(l.silicon.bottom() <= l.traces.y);
        try std.testing.expect(l.traces.bottom() <= l.counters.y);
        try std.testing.expect(l.counters.bottom() <= l.footer.y);
        // The three panels tile their band left to right.
        try std.testing.expect(l.silicon.right() <= l.memory.x);
        try std.testing.expect(l.memory.right() <= l.io.x);
        // …and share its top and height, so they read as one row.
        try std.testing.expectEqual(l.silicon.y, l.memory.y);
        try std.testing.expectEqual(l.silicon.h, l.io.h);
    }
}

test "the memory column is the widest: it carries the most" {
    try typeface.init(std.heap.page_allocator);
    const l = layoutOf(qemu, 12);
    try std.testing.expect(l.memory.w > l.silicon.w);
    try std.testing.expect(l.memory.w > l.io.w);
}

test "the page is set at the largest type step the screen can hold it at" {
    try typeface.init(std.heap.page_allocator);
    // A full page is a full core matrix, and only a desk-wide panel has the room
    // for one set comfortably.
    try std.testing.expectEqual(hudview.Density.comfortable, hudview.scaleFor(wide).density);
    // A 1080p panel, a laptop panel, and a screen that is wide but shallow are
    // all short of that room: the page steps down rather than spilling off.
    try std.testing.expectEqual(hudview.Density.compact, hudview.scaleFor(qemu).density);
    try std.testing.expectEqual(hudview.Density.compact, hudview.scaleFor(laptop).density);
    try std.testing.expectEqual(hudview.Density.compact, hudview.scaleFor(.{ .x = 0, .y = 0, .w = 3440, .h = 768 }).density);
}

test "a step down the ladder is smaller in every voice, and still a ladder" {
    try typeface.init(std.heap.page_allocator);
    const roomy = hudview.Scale.of(.comfortable);
    const tight = hudview.Scale.of(.compact);
    for ([_][2]typeface.Role{
        .{ roomy.fine, tight.fine },
        .{ roomy.body, tight.body },
        .{ roomy.value, tight.value },
        .{ roomy.clock, tight.clock },
        .{ roomy.chrome.title, tight.chrome.title },
        .{ roomy.tile.value, tight.tile.value },
    }) |pair| {
        try std.testing.expect(typeface.lineHeight(pair[1]) < typeface.lineHeight(pair[0]));
    }
    // Every band and every gap comes down with the type — a page set smaller is
    // the same page, not the same layout with smaller words in it.
    try std.testing.expect(tight.vitals_h < roomy.vitals_h);
    try std.testing.expect(tight.footer_h < roomy.footer_h);
    try std.testing.expect(tight.gap < roomy.gap);
    try std.testing.expect(tight.core_min_h < roomy.core_min_h);
    try std.testing.expect(tight.chrome.header_h < roomy.chrome.header_h);
    // The voices stay in order: the ladder is shifted, never flattened.
    try std.testing.expect(typeface.lineHeight(tight.fine) < typeface.lineHeight(tight.body));
    try std.testing.expect(typeface.lineHeight(tight.body) < typeface.lineHeight(tight.value));
    try std.testing.expect(typeface.lineHeight(tight.value) < typeface.lineHeight(tight.clock));
}

test "a band asks for the room its content needs, and no more" {
    try typeface.init(std.heap.page_allocator);
    const sc = hudview.Scale.of(.comfortable);
    const few = machine(3);
    const many = machine(20);
    try std.testing.expect(hudview.demandOf(&many, sc).counters > hudview.demandOf(&few, sc).counters);
    // A machine with more cores wants a taller panel band; one with fewer gives
    // the room back rather than drawing a taller empty box.
    var one_core = machine(3);
    one_core.cores_online = 2;
    try std.testing.expect(hudview.demandOf(&one_core, sc).panels < hudview.demandOf(&few, sc).panels);
}

test "the counter wall grows with its rows, and the panels keep theirs" {
    try typeface.init(std.heap.page_allocator);
    const few = layoutOf(qemu, 4);
    const many = layoutOf(qemu, 20);
    try std.testing.expect(many.counters.h > few.counters.h);
    // What the wall takes comes out of the room nothing needed, never out of the
    // panels: the readings the display exists for are not what a page pays with.
    try std.testing.expect(many.silicon.h >= few.silicon.h - 0.01);
}

test "on a page too short for everything, the wall gives before the panels do" {
    try typeface.init(std.heap.page_allocator);
    // A small machine on a small screen: its panels fit and its 40 counters do
    // not, which is the case that shows what the page gives up first. (A full
    // matrix on this screen is short of room for the panels themselves — what
    // the page does THERE is asserted in the shot fixture.)
    var s = machine(40);
    s.cores_online = 8;
    const sc = hudview.scaleFor(tiny);
    const d = hudview.demandOf(&s, sc);
    const l = hudview.layout(tiny, sc, d);
    try std.testing.expect(l.counters.h < d.counters); // squeezed…
    try std.testing.expect(l.counters.h + 0.01 >= sc.wall_min_h); // …but never below its floor
    try std.testing.expectApproxEqAbs(d.panels, l.silicon.h, 0.01); // the readings keep their room
}

test "the alarm band is reserved whether or not an alarm is up" {
    try typeface.init(std.heap.page_allocator);
    const sc = hudview.scaleFor(qemu);
    const l = layoutOf(qemu, 12);
    // The vitals band carries the strip AND the alarm row, so nothing below it
    // moves when a fault latches.
    try std.testing.expectEqual(sc.vitals_h + sc.alarm_h, l.vitals.h);
}

test "fault names are recognised by what they record, not by a list of counters" {
    for ([_][]const u8{
        "usb.hid.orphan",
        "mouse.drops",
        "netdebug.fifo_drops",
        "kmr1.reply_senderr",
        "boot.spin_exceeded",
        "smp.session_faults",
        "hid.badcc",
        "gpu.kick_fail",
    }) |name| {
        try std.testing.expect(hudview.isFault(name));
    }
    for ([_][]const u8{
        "kbd_reports",
        "rx.frames",
        "sess.commits",
        "ev.consumed",
        "input_present_max_us",
    }) |name| {
        try std.testing.expect(!hudview.isFault(name));
    }
}

test "every counter group is named, so a column can never be blank-headed" {
    for (hudview.Group.ALL) |g| {
        try std.testing.expect(g.title().len > 0);
    }
}

test "every label the display draws is one the typeface can draw" {
    // The sheet is baked over printable ASCII and text is drawn byte by byte, so
    // a typographic middle dot would draw as NOTHING while still taking a pen
    // width per byte. That failure is silent on screen; it is not silent here.
    try typeface.init(std.heap.page_allocator);
    try std.testing.expect(typeface.drawable(hudview.SEP));
    try std.testing.expect(typeface.drawable(hudview.CUT));
    for (hudview.Group.ALL) |g| try std.testing.expect(typeface.drawable(g.title()));
    for ([_]hudview.Section{ .silicon, .memory, .io }) |sec| {
        try std.testing.expect(typeface.drawable(sec.dropped()));
    }
}

test "the wall is sized by its fullest column" {
    var s = hudview.Snapshot{};
    s.counters[0] = .{ .group = .usb, .name = "a", .value = 1 };
    s.counters[1] = .{ .group = .usb, .name = "b", .value = 1 };
    s.counters[2] = .{ .group = .usb, .name = "c", .value = 1 };
    s.counters[3] = .{ .group = .net, .name = "d", .value = 1 };
    s.counter_count = 4;
    try std.testing.expectEqual(@as(usize, 3), hudview.tallestGroup(&s));

    var empty = hudview.Snapshot{};
    try std.testing.expectEqual(@as(usize, 0), hudview.tallestGroup(&empty));
}

test "a label too long for its column is cut where a reader can see it was" {
    try typeface.init(std.heap.page_allocator);
    var buf: [64]u8 = undefined;
    const role = typeface.Role.fine;
    const name = "input_present_over_budget";
    // Room for the whole label: it is left alone.
    try std.testing.expectEqualStrings(name, hudview.elide(&buf, role, name, typeface.width(role, name) + 1));
    // Room for half of it: what is drawn fits, and says it is not the whole name.
    const cut = hudview.elide(&buf, role, name, typeface.advance(role) * 12);
    try std.testing.expectEqual(@as(usize, 12), cut.len);
    try std.testing.expect(std.mem.endsWith(u8, cut, hudview.CUT));
    try std.testing.expect(typeface.width(role, cut) <= typeface.advance(role) * 12);
    // No room worth writing in: nothing, rather than a mark meaning nothing.
    try std.testing.expectEqualStrings("", hudview.elide(&buf, role, name, 2));
}

test "a core line truncates a long task label instead of overrunning it" {
    var c = hudview.CoreLine{};
    c.setTask("a-task-name-far-longer-than-the-label-budget", "and-an-activity-just-as-long");
    try std.testing.expectEqual(@as(usize, hudview.TASK_LABEL), c.taskName().len);
    try std.testing.expectEqual(@as(usize, hudview.TASK_LABEL), c.activityName().len);
    try std.testing.expect(std.mem.startsWith(u8, c.taskName(), "a-task-name"));
}

test "the core matrix keeps label-carrying columns through twelve cores" {
    // Two columns up to eight cores, three through twelve — both tile widths
    // carry a task label, so a machine this size shows what runs where. Four
    // columns only past twelve, where the count itself is the story.
    var s = hudview.Snapshot{};
    for ([_]struct { n: u32, cols: usize }{
        .{ .n = 1, .cols = 2 },
        .{ .n = 8, .cols = 2 },
        .{ .n = 9, .cols = 3 },
        .{ .n = 12, .cols = 3 },
        .{ .n = 13, .cols = 4 },
        .{ .n = 32, .cols = 4 },
    }) |case| {
        s.cores_online = case.n;
        const grid = hudview.coreGrid(&s);
        try std.testing.expectEqual(case.cols, grid.cols);
        try std.testing.expectEqual(@as(usize, case.n), grid.cores);
        try std.testing.expect(grid.rows * grid.cols >= grid.cores);
    }
}

test "the clock reads unknown rather than midnight when it has not been read" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("--:--:--", hudview.formatClock(&buf, null));
    try std.testing.expectEqualStrings("14:32:07", hudview.formatClock(&buf, 14 * 3600 + 32 * 60 + 7));
    // Past a day, the clock wraps rather than counting hours forever.
    try std.testing.expectEqualStrings("00:00:01", hudview.formatClock(&buf, 24 * 3600 + 1));
}

test "uptime is stated in the units a person reads it in" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0h 0m 5s", hudview.formatUptime(&buf, 5_000));
    try std.testing.expectEqualStrings("4h 17m 36s", hudview.formatUptime(&buf, 4 * 3600_000 + 17 * 60_000 + 36_000));
}

test "the trace ceiling leaves the frame budget mid-panel" {
    // A budget line pinned to the middle is what makes a breach obvious; if the
    // ceiling drifted, an over-budget frame would stop looking like one.
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5),
        hudview.FRAME_BUDGET_MS / hudview.FRAME_TRACE_MAX_MS,
        0.01,
    );
}

test "the history window is what the display says it is" {
    // The footer and every trace's note quote this figure; it is derived, not
    // written twice.
    try std.testing.expectEqual(@as(u64, 30), hudview.HISTORY * hudview.SAMPLE_MS / 1000);
    try std.testing.expectEqual(hudview.HISTORY, hudview.Series.CAPACITY);
}

test "the sample period refreshes the display at least twice a second (HUD-032)" {
    // The product of HISTORY and SAMPLE_MS above is 30 s for MANY pairs — 30
    // samples a second apart satisfies it while refreshing at 1 Hz, half the
    // required rate. This is the assertion that pins the RATE rather than the
    // window, so slowing the HUD down cannot pass by lengthening the history.
    try std.testing.expect(hudview.SAMPLE_MS <= 500);
}

// ── the painted half ────────────────────────────────────────────────────────────

const kgl = @import("kgl");
const gles = @import("gles");
const idraw = @import("idraw");
const raster = @import("soft");

test "the desk-wide page PAINTS: per-core silicon rows, ribbon, panels, wall" {
    const ta = std.testing.allocator;
    try typeface.init(std.heap.page_allocator);
    var dev = raster.Soft{ .alloc = ta };
    idraw.device = dev.iface();
    defer idraw.device = null;
    defer dev.deinit();
    var g = gles.createContext(ta, .{ .win_base = 0, .stride_px = 3440, .off_x = 0, .off_y = 0 }) orelse
        return error.NoDevice;
    defer g.deinit();
    var p = try kgl.Painter.init(ta);
    defer p.deinit(ta);
    gles.beginFrame(&g, 3440, 1440);
    const sheet = typeface.sheetBytes();
    const la = try ta.alloc(u8, sheet.len * 2);
    defer ta.free(la);
    typeface.expandToLuminanceAlpha(la);
    const sheet_tex = kgl.uploadAtlas(&g, typeface.SHEET_W, typeface.sheetHeight(), la);

    var s = machine(24);
    s.cores_online = 32;
    for (0..32) |i| {
        var line = hudview.CoreLine{ .online = true, .is_bsp = i == 0, .busy_pct = @intCast((i * 7) % 100), .runnable = @intCast(i % 4) };
        line.setTask("worker", "busy");
        s.cores[i] = line;
    }
    s.heap_arena = 512 << 20;
    s.heap_used = 300 << 20;
    s.heap_free = 212 << 20;
    s.ramdisk_bytes = 38 << 20;
    s.guests_running = 1;
    s.guest_capacity = 4;
    s.link_up = true;
    var frame_ms = hudview.Series{};
    var cpu = hudview.Series{};
    var heap = hudview.Series{};
    var rx = hudview.Series{};
    var i: usize = 0;
    while (i < hudview.HISTORY) : (i += 1) {
        const t: u64 = i * hudview.SAMPLE_MS;
        frame_ms.push(15, t);
        cpu.push(40, t);
        heap.push(300, t);
        rx.push(80, t);
    }
    p.begin(&g, 3440, 1440);
    hudview.draw(&p, sheet_tex, .{ .x = 0, .y = 0, .w = 3440, .h = 1440 }, &s, .{
        .frame_ms = &frame_ms, .cpu_busy = &cpu, .heap_free = &heap, .net_rx = &rx,
    }, .{ .alarm = true, .frozen = true, .now_ms = 12_345 });
    p.end();
    gles.swapBuffers(&g);
    gles.finish(&g);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));
}
