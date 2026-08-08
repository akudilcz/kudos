//! The heads-up display's VIEW: everything about how the machine's vitals are
//! laid out and drawn, and nothing about how they are read. It takes a `Snapshot`
//! — a plain value — plus the traces, and paints them with the widget toolkit.
//!
//! Separated from the sampler (ui/desktop/hud.zig) for the reason the rails give:
//! the drawing is expressible as a pure function of a value, so it lives where a
//! host test can drive it. That is not a technicality — it is how this screen gets
//! looked at: `zig build hud-shot` renders a fabricated snapshot through the same
//! painter the kernel uses and writes an image, so the layout is reviewed, and
//! regressions are seen, on a laptop with no GPU and no kudos running.
//!
//! Two rules hold the page together, and both are worth stating before the code:
//!
//!   - **The page is set at the largest type step it fits at.** A display whose
//!     type is fixed either wastes a big screen or spills off a small one; this
//!     one shifts the WHOLE ladder down a step when the screen is short or narrow
//!     (see `Scale`), so every voice keeps its relationship to its neighbours.
//!   - **Every band asks for the room its content needs, and no band draws
//!     outside the room it was granted.** Panels fill themselves through
//!     `panel.Rows`, which refuses what will not fit and says how much it refused
//!     — a reading is either on the screen or counted, never painted over the
//!     band below it.
//!
//! Nothing here touches kernel state, allocates, or keeps state of its own. Every
//! string is formatted into a stack buffer sized at its use, and every string is
//! printable ASCII, which is the repertoire the typeface is baked over.

const std = @import("std");
const kgl = @import("kgl");
const rects = @import("rects");
const sampler = @import("sampler");
const typeface = @import("typeface");
const theme = @import("theme");
const panel = @import("panel");
const meter = @import("meter");
const stackbar = @import("stackbar");
const sparkline = @import("sparkline");
const statile = @import("statile");

// ── budgets: every fixed size the display is built on ───────────────────────────

/// Frame-time trace ceiling: two vsync periods, so the budget line sits at
/// mid-height and a dropped frame is unmistakably above it.
pub const FRAME_TRACE_MAX_MS: f64 = 33.4;
/// The frame budget a 60 Hz present holds under.
pub const FRAME_BUDGET_MS: f64 = 16.7;

/// Separator between the clauses of one line of display text, and the marker a
/// cut label ends in. Both are ASCII on purpose: the typeface is baked over
/// printable ASCII (typeface.drawable), so a typographic middle dot or ellipsis
/// would draw as nothing at all while still taking a pen width — text vanishing
/// in silence, which is the one thing a diagnostic screen may not do.
pub const SEP = " | ";
/// What a label cut to fit its column ends in.
pub const CUT = "..";

// ── the pool palette ────────────────────────────────────────────────────────────
//
// Identity colours, distinct from the theme's reserved ok/warn/fault ramp and
// from each other. Validated on the display's dark field for colour-vision
// deficiency as well as normal vision — worst adjacent pair ΔE 15.9 simulated,
// 19.7 normal. Identity is never colour alone: every swatch is drawn beside its
// name and its number.

/// Kernel heap.
pub const POOL_HEAP: u32 = 0xFFD55181;
/// Everything else the kernel holds.
pub const POOL_OTHER: u32 = 0xFF9085E9;
/// Processor time.
pub const POOL_CPU: u32 = 0xFF3987E5;
/// Network.
pub const POOL_NET: u32 = 0xFF1F9AA6;
/// The scrim over the desktop: dark enough that nothing underneath competes with
/// a figure, sheer enough that the desktop still reads as context.
pub const SCRIM: u32 = 0xD00A0D10;

// ── the snapshot model (hudsnapshot.zig), re-exported: the sampler and the
// shot fixture address the whole HUD surface through this view module ─────────

const snap = @import("hudsnapshot.zig");
pub const HISTORY = snap.HISTORY;
pub const SAMPLE_MS = snap.SAMPLE_MS;
pub const MAX_CORES = snap.MAX_CORES;
pub const MAX_COUNTERS = snap.MAX_COUNTERS;
pub const TASK_LABEL = snap.TASK_LABEL;
pub const MAX_GUESTS = snap.MAX_GUESTS;
pub const Series = snap.Series;
pub const Group = snap.Group;
pub const CoreLine = snap.CoreLine;
pub const CounterLine = snap.CounterLine;
pub const Snapshot = snap.Snapshot;
pub const Traces = snap.Traces;
pub const Options = snap.Options;
pub const isFault = snap.isFault;

// ── the type scale: how large the page is set ───────────────────────────────────

/// How tightly the page is set. Not a theme and not a preference: the display
/// picks the one the screen in front of it can hold (see `scaleFor`).
pub const Density = enum {
    /// The design size, for a screen with the room for it.
    comfortable,
    /// Every voice one step down the type ladder, for a screen without.
    compact,

    /// Steps down `typeface.Role` this density sets the page at.
    pub fn steps(self: Density) u8 {
        return switch (self) {
            .comfortable => 0,
            .compact => 1,
        };
    }
};

/// Every size the page is set at, derived from ONE decision: which step of the
/// type ladder it is set on. Chrome, padding and band heights all come out of the
/// line heights, so a page a step smaller is the same page — not a different
/// layout with smaller numbers in it.
pub const Scale = struct {
    density: Density,
    /// The frame every panel on the page shares.
    chrome: panel.Chrome,
    /// Dense rows: counter walls, legends, core tiles, footnotes.
    fine: typeface.Role,
    /// Panel rows.
    body: typeface.Role,
    /// A panel's headline figure.
    value: typeface.Role,
    /// The vitals tiles.
    tile: statile.Type,
    /// The wall clock.
    clock: typeface.Role,

    /// Margin from the screen edge.
    margin: f32,
    /// Gap between bands, and between columns within a band.
    gap: f32,
    /// Gap between core tiles — tighter than the band gap: they are one matrix.
    core_gap: f32,

    /// Height of the vitals strip, alarm band excluded.
    vitals_h: f32,
    /// Height of the alarm band under the vitals strip (HUD-028).
    alarm_h: f32,
    /// Height of the footer.
    footer_h: f32,
    /// Shortest a trace panel is worth drawing.
    trace_min_h: f32,
    /// Tallest a trace panel grows to. Past this a sparkline is just a taller
    /// sparkline, and the room is better spent on the panels.
    trace_max_h: f32,
    /// Shortest the counter wall may be squeezed to before it hides rows.
    wall_min_h: f32,
    /// Smallest core tile that still carries a figure and a task label.
    core_min_h: f32,
    /// Largest core tile worth growing to.
    core_max_h: f32,
    /// Height of the memory ribbon.
    ribbon_h: f32,
    /// Height of a bar drawn under a row.
    bar_h: f32,
    /// Width of the status-chip cluster at the right of the vitals strip.
    chips_w: f32,

    /// Longest chip label, in characters: what the cluster is sized to hold.
    const CHIP_CHARS: f32 = 15;

    /// The scale at a density. All arithmetic over the baked line heights — the
    /// typeface must be ready before this is called.
    pub fn of(d: Density) Scale {
        const n = d.steps();
        const fine = down(.fine, n);
        const body = down(.body, n);
        const label = down(.label, n);
        const value = down(.value, n);
        const fine_h = typeface.lineHeight(fine);
        const body_h = typeface.lineHeight(body);
        const value_h = typeface.lineHeight(value);
        const pad = @round(fine_h * 0.72);
        const chrome: panel.Chrome = .{
            .title = label,
            .note = fine,
            .row = body,
            .header_h = @round(typeface.lineHeight(label) + fine_h * 0.5),
            .pad = pad,
        };
        const core_h = @round(fine_h + value_h + pad);
        const plot_h = @round(value_h * 2.2);
        return .{
            .density = d,
            .chrome = chrome,
            .fine = fine,
            .body = body,
            .value = value,
            .tile = .{ .caption = fine, .value = down(.hero, n), .unit = body },
            .clock = down(.mega, n),
            .margin = @round(fine_h),
            .gap = @round(fine_h * 0.85),
            .core_gap = @round(fine_h * 0.3),
            .vitals_h = @round(2 * pad + typeface.lineHeight(down(.mega, n)) + fine_h * 1.3),
            .alarm_h = @round(body_h + pad),
            .footer_h = @round(fine_h + pad),
            .trace_min_h = chrome.overhead() + value_h + plot_h,
            .trace_max_h = chrome.overhead() + value_h + plot_h * 2,
            .wall_min_h = chrome.overhead() + fine_h * 4,
            .core_min_h = core_h,
            .core_max_h = @round(core_h * 1.3),
            .ribbon_h = @round(body_h * 1.7),
            .bar_h = @round(fine_h * 0.8),
            .chips_w = @round(2 * (typeface.advance(fine) * CHIP_CHARS + fine_h * 2)),
        };
    }

    /// Height a counter wall of `rows` rows asks for, frame included.
    pub fn wallH(self: Scale, rows: usize) f32 {
        return self.chrome.overhead() + typeface.lineHeight(self.fine) * @as(f32, @floatFromInt(rows));
    }

    /// `role`, `n` steps down the ladder.
    fn down(role: typeface.Role, n: u8) typeface.Role {
        var r = role;
        var i: u8 = 0;
        while (i < n) : (i += 1) r = r.smaller();
        return r;
    }
};

/// A full page of content, in the units the page is made of: the type step is
/// chosen against THIS rather than against the machine in front of it, so the
/// page does not resize when a counter appears or a core goes idle.
/// Rows of core tiles a full page holds: the matrix at the display's ceiling.
/// A page whose type step was chosen against half a matrix has nothing left for
/// the traces when a full one arrives, and kudos' own target fills it.
pub const REF_CORE_ROWS: usize = gridFor(snap.MAX_CORES).rows;
/// Counter rows a wall column must hold without hiding one.
pub const REF_WALL_ROWS: usize = 12;
/// Characters a wall column must hold: the longest counter name the kernel
/// registers, plus room for its value and its rate.
pub const REF_WALL_CHARS: f32 = 34;

/// The largest type step this screen can hold a full page at. This is the whole
/// answer to a small screen: not a scrollbar, not a cropped page, not a second
/// layout — the same page, set a step smaller.
pub fn scaleFor(screen: rects.Rect) Scale {
    const roomy = Scale.of(.comfortable);
    const page_h = screen.h - 2 * roomy.margin;
    const page_w = screen.w - 2 * roomy.margin;
    if (page_h >= refHeight(roomy) and page_w >= refWidth(roomy)) return roomy;
    return Scale.of(.compact);
}

/// Height a full page needs at `sc`: every band at the height its reference
/// content asks for.
fn refHeight(sc: Scale) f32 {
    const cores = @as(f32, @floatFromInt(REF_CORE_ROWS));
    const silicon = sc.chrome.overhead() + 2 * typeface.lineHeight(sc.body) +
        sc.core_gap + cores * (sc.core_min_h + sc.core_gap);
    return sc.vitals_h + sc.alarm_h + sc.gap +
        silicon + sc.gap +
        sc.trace_min_h + sc.gap +
        sc.wallH(REF_WALL_ROWS) + sc.gap +
        sc.footer_h;
}

/// Width a full page needs at `sc`: four counter columns wide enough for a
/// counter row, which is the narrowest thing on the page.
fn refWidth(sc: Scale) f32 {
    const col = typeface.advance(sc.fine) * REF_WALL_CHARS + 2 * sc.chrome.pad;
    return 4 * col + 3 * sc.gap;
}

// ── layout ──────────────────────────────────────────────────────────────────────

/// Where each band of the display sits. Pure, so a test can assert the whole page
/// fits on a screen before anything is drawn.
pub const Layout = struct {
    vitals: rects.Rect,
    silicon: rects.Rect,
    memory: rects.Rect,
    io: rects.Rect,
    traces: rects.Rect,
    counters: rects.Rect,
    footer: rects.Rect,
};

/// Column proportions of the panel band: silicon, memory, display+IO.
pub const COLUMNS = [_]f32{ 1.05, 1.25, 1.05 };

/// What the page's two content-sized bands ask for, in pixels — measured by
/// walking the same fills that draw them (`demandOf`).
pub const Demand = struct {
    /// Tallest of the three panels' content, frame included — the least the band
    /// can show every reading in.
    panels: f32,
    /// The most the panel band can put to use: the same content with its core
    /// tiles grown to the height past which a tile is only a bigger box.
    panels_grown: f32,
    /// The counter wall's fullest column, frame included.
    counters: f32,
};

/// How much room each band wants for the machine in `s`. Measured, not
/// estimated: `panel.Rows.measuring` walks the very code that draws each panel,
/// so a row added to a panel changes its demand in the same edit.
pub fn demandOf(s: *const Snapshot, sc: Scale) Demand {
    var silicon = panel.Rows.measuring(sc.body);
    fillSilicon(&silicon, sc, s);
    var memory = panel.Rows.measuring(sc.body);
    fillMemory(&memory, sc, s);
    var io = panel.Rows.measuring(sc.body);
    fillIo(&io, sc, s);
    const least = sc.chrome.overhead() + @max(silicon.used, @max(memory.used, io.used));
    const grid = coreGrid(s);
    return .{
        .panels = least,
        .panels_grown = least + @as(f32, @floatFromInt(grid.rows)) * (sc.core_max_h - sc.core_min_h),
        .counters = sc.wallH(tallestGroup(s)),
    };
}

/// Divide a screen into the display's bands.
///
/// Every band asks for what its content needs and the page grants the room in
/// one priority ladder, so neither band is padded with air while another hides
/// content. From highest priority down: the panels' demand (the readings the
/// display exists for are never traded away), the counter wall's floor, the
/// traces' floor, the core tiles' growth, the wall's full demand, the traces'
/// ceiling. On a short page the low rungs simply go unfunded — the traces
/// starve before the wall's floor is breached, and the wall shrinks below its
/// demand (saying how many rows it hid) before the panels give up anything.
pub fn layout(screen: rects.Rect, sc: Scale, d: Demand) Layout {
    const page = screen.inset(sc.margin);
    const head_h = sc.vitals_h + sc.alarm_h;
    const rest = page.belowTop(head_h + sc.gap);

    // Three bands and the three gaps between them and the footer, granted in
    // priority order with each grant bounded by what is left: the panels' full
    // demand (the readings the display exists for give up room last), the
    // wall's floor, the traces' floor, the tiles' growth, the wall's demand,
    // the traces' ceiling. What remains after every demand lands on the wall —
    // the page's one open-ended band. This ladder is why a busy counter wall
    // can never shrink the panels: the wall's demand is fed from spare room
    // and then from the traces — the last thirty seconds' shape is decoration
    // next to counters the machine is reporting NOW — never from the tiles.
    var left = @max(0, rest.h - sc.footer_h - 3 * sc.gap);
    const panels_min = @min(d.panels, left);
    left -= panels_min;
    const wall_floor = @min(sc.wall_min_h, left);
    left -= wall_floor;
    var traces_h = @min(sc.trace_min_h, left);
    left -= traces_h;
    const panels_growth = @min(@max(0, d.panels_grown - panels_min), left);
    left -= panels_growth;
    var wall_demand = @min(@max(0, d.counters - wall_floor), left);
    left -= wall_demand;
    // Demand still unmet: the traces give, to the last pixel, before a counter
    // row hides.
    const from_traces = @min(@max(0, d.counters - wall_floor - wall_demand), traces_h);
    traces_h -= from_traces;
    wall_demand += from_traces;
    const traces_growth = @min(@max(0, sc.trace_max_h - traces_h), left);
    left -= traces_growth;
    traces_h += traces_growth;

    const panels_h = panels_min + panels_growth;
    const wall_h = wall_floor + wall_demand + left;

    const body = rest.top(panels_h);
    return .{
        .vitals = page.top(head_h),
        .silicon = rects.weighted(body, &COLUMNS, 0, sc.gap),
        .memory = rects.weighted(body, &COLUMNS, 1, sc.gap),
        .io = rects.weighted(body, &COLUMNS, 2, sc.gap),
        .traces = rest.belowTop(panels_h + sc.gap).top(traces_h),
        .counters = rest.belowTop(panels_h + sc.gap + traces_h + sc.gap).top(wall_h),
        .footer = rest.belowTop(panels_h + sc.gap + traces_h + sc.gap + wall_h + sc.gap).top(sc.footer_h),
    };
}

// ── drawing ─────────────────────────────────────────────────────────────────────

/// Draw the whole display over `screen`. `sheet_tex` is the baked typeface.
pub fn draw(
    p: *kgl.Painter,
    sheet_tex: u32,
    screen: rects.Rect,
    s: *const Snapshot,
    tr: Traces,
    opts: Options,
) void {
    if (!typeface.ready()) return;
    p.fillRect(screen.x, screen.y, screen.w, screen.h, SCRIM);

    const sc = scaleFor(screen);
    const l = layout(screen, sc, demandOf(s, sc));
    drawVitals(p, sheet_tex, l.vitals, sc, s, tr, opts);
    drawPanel(p, sheet_tex, l.silicon, sc, s, .silicon);
    drawPanel(p, sheet_tex, l.memory, sc, s, .memory);
    drawPanel(p, sheet_tex, l.io, sc, s, .io);
    drawTraces(p, sheet_tex, l.traces, sc, tr);
    drawCounters(p, sheet_tex, l.counters, sc, s);
    drawFooter(p, sheet_tex, l.footer, sc, s);
}

fn drawVitals(
    p: *kgl.Painter,
    tex: u32,
    r: rects.Rect,
    sc: Scale,
    s: *const Snapshot,
    tr: Traces,
    opts: Options,
) void {
    const strip = r.top(sc.vitals_h);
    p.fillRect(strip.x, strip.y, strip.w, strip.h, theme.GLASS_BG);
    p.rect(strip.x, strip.y, strip.w, strip.h, theme.BORDER);
    p.fillRect(strip.x, strip.y, strip.w, 3, theme.ACCENT);

    const inner = strip.insetXY(sc.chrome.pad * 1.6, sc.chrome.pad);
    var buf: [64]u8 = undefined;

    // Wall clock and uptime (HUD-021, HUD-022, HUD-031).
    const clock_base = inner.y + typeface.metrics(sc.clock).ascent;
    const clock = formatClock(&buf, s.seconds_since_midnight);
    p.glyphText(tex, typeface.sheetFor(sc.clock), clock, inner.x, clock_base, theme.WHITE);

    var ub: [48]u8 = undefined;
    var sb: [96]u8 = undefined;
    const age_ms = opts.now_ms -| s.taken_ms;
    const sub = std.fmt.bufPrint(&sb, "up {s}" ++ SEP ++ "sampled {d}.{d}s ago{s}", .{
        formatUptime(&ub, s.taken_ms),
        age_ms / 1000,
        (age_ms % 1000) / 100,
        if (opts.frozen) SEP ++ "FROZEN" else "",
    }) catch "";
    p.glyphText(
        tex,
        typeface.sheetFor(sc.fine),
        sub,
        inner.x,
        clock_base + typeface.lineHeight(sc.fine) + 4,
        if (opts.frozen) theme.YELLOW else theme.DIM,
    );

    // The four figures meant to be read from across the room (HUD-006, 009, 011,
    // 015), then the machine's state as chips. The chips take the room the
    // figures do not, so the strip carries no dead air.
    const after_clock = inner.afterLeft(typeface.width(sc.clock, clock) + sc.gap * 3);
    const tiles = after_clock.left(@max(0, after_clock.w - sc.chips_w));
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    var b4: [24]u8 = undefined;
    const gap = sc.gap;
    statile.draw(p, tex, rects.column(tiles, 4, 0, gap), sc.tile, "CPU BUSY", std.fmt.bufPrint(&b1, "{d}", .{s.busy_pct}) catch "-", "%", meter.statusOf(s.busy_pct, 100).color(), trendOf(tr.cpu_busy));
    statile.draw(p, tex, rects.column(tiles, 4, 1, gap), sc.tile, "MEMORY", std.fmt.bufPrint(&b2, "{d:.1}", .{gib(s.mem_used)}) catch "-", "GiB", meter.statusOf(s.mem_used, s.mem_total).color(), .none);
    statile.draw(p, tex, rects.column(tiles, 4, 2, gap), sc.tile, "HEAP FREE", std.fmt.bufPrint(&b3, "{d}", .{s.heap_free / (1024 * 1024)}) catch "-", "MiB", meter.statusOf(s.heap_used, s.heap_arena).color(), trendOf(tr.heap_free));
    statile.draw(p, tex, rects.column(tiles, 4, 3, gap), sc.tile, "PRESENT", std.fmt.bufPrint(&b4, "{d}", .{s.fps}) catch "-", "Hz", fpsColor(s.fps), .none);

    drawChips(p, tex, after_clock.afterLeft(@max(0, after_clock.w - sc.chips_w)), sc, s);

    // The alarm band, under the strip and never over it (HUD-028, HUD-029).
    const band = r.belowTop(sc.vitals_h);
    const base = band.y + (band.h + typeface.metrics(sc.body).ascent - typeface.metrics(sc.body).descent) * 0.5;
    if (opts.alarm) {
        p.fillRect(band.x, band.y, band.w, band.h, 0x40E74C3C);
        p.rect(band.x, band.y, band.w, band.h, theme.RED);
        var ab: [128]u8 = undefined;
        const txt = std.fmt.bufPrint(&ab, "! {d} fault counter(s) above zero" ++ SEP ++ "press A to acknowledge", .{s.faults}) catch "!";
        p.glyphText(tex, typeface.sheetFor(sc.body), txt, band.x + sc.chrome.pad, base, theme.RED);
    } else {
        // Silence is a state: the band stays, saying so, rather than the page
        // reflowing the moment something goes wrong.
        p.glyphText(tex, typeface.sheetFor(sc.fine), "no faults recorded", band.x + sc.chrome.pad, base, theme.DIM);
    }
}

/// The machine's binary states, as chips: a dot plus a word. Each one is a thing
/// that is either working or not, where a number would say less than a colour and
/// a name together.
fn drawChips(p: *kgl.Painter, tex: u32, r: rects.Rect, sc: Scale, s: *const Snapshot) void {
    const Chip = struct { on: bool, label: []const u8 };
    var gb: [24]u8 = undefined;
    const chips = [_]Chip{
        .{ .on = s.link_up, .label = if (s.link_up) "net up" else "net down" },
        .{ .on = s.kbd and s.mouse, .label = "hid" },
        .{ .on = s.usbdisk, .label = "usbdisk" },
        .{ .on = s.vt_available, .label = "vt-x" },
        .{ .on = s.guests_running > 0, .label = std.fmt.bufPrint(&gb, "{d} guest(s)", .{s.guests_running}) catch "guests" },
        .{ .on = s.fps >= 58, .label = "present locked" },
    };
    const cols: usize = 2;
    const line_h = typeface.lineHeight(sc.fine);
    const dot = @round(line_h * 0.5);
    for (chips, 0..) |c, i| {
        const col = rects.column(r, cols, i % cols, sc.gap);
        const base = r.y + typeface.metrics(sc.fine).ascent + line_h * @as(f32, @floatFromInt(i / cols));
        p.fillRect(col.x, base - dot, dot, dot, if (c.on) theme.GREEN else theme.DIM);
        p.glyphText(tex, typeface.sheetFor(sc.fine), c.label, col.x + dot + 6, base, if (c.on) theme.TEXT else theme.DIM);
    }
}

/// The three panels of the middle band. One entry point so the frame, the body
/// cursor, the spread of spare room and the dropped-row note are written once and
/// cannot differ between them — the fill is the only thing that changes.
pub const Section = enum {
    silicon,
    memory,
    io,

    /// Whether the panel's own content grows into spare room. The core matrix
    /// does — its tiles take it. A panel of fixed rows cannot, so its spare room
    /// is spread between its groups instead; a panel must not do both, or the
    /// gaps would eat the room the tiles were about to grow into.
    pub fn grows(self: Section) bool {
        return self == .silicon;
    }

    /// What this panel calls the things it had no room for.
    pub fn dropped(self: Section) []const u8 {
        return if (self == .silicon) "more cores" else "not shown";
    }
};

fn fill(rows: *panel.Rows, sc: Scale, s: *const Snapshot, which: Section) void {
    switch (which) {
        .silicon => fillSilicon(rows, sc, s),
        .memory => fillMemory(rows, sc, s),
        .io => fillIo(rows, sc, s),
    }
}

fn drawPanel(p: *kgl.Painter, tex: u32, r: rects.Rect, sc: Scale, s: *const Snapshot, which: Section) void {
    var nb: [48]u8 = undefined;
    const title = switch (which) {
        .silicon => "SILICON",
        .memory => "MEMORY",
        .io => "DISPLAY / IO",
    };
    const note = switch (which) {
        .silicon => std.fmt.bufPrint(&nb, "{d} cores", .{s.cores_online}) catch "",
        .memory => std.fmt.bufPrint(&nb, "{d:.1} / {d:.0} GiB", .{ gib(s.mem_used), gib(s.mem_total) }) catch "",
        .io => if (s.link_up) "link up" else "link down",
    };
    const body = panel.draw(p, tex, r, sc.chrome, title, note);
    var rows = panel.Rows.over(p, tex, body, sc.body);
    if (!which.grows()) {
        // The band is as tall as the tallest of the three panels, so the other
        // two are handed room they did not ask for. Spread between their groups
        // it reads as leading; left at the end it reads as an empty panel.
        var measure = panel.Rows.measuring(sc.body);
        fill(&measure, sc, s, which);
        if (measure.gaps > 0) {
            rows.stretch = @max(0, body.h - measure.used) / @as(f32, @floatFromInt(measure.gaps));
        }
    }
    fill(&rows, sc, s, which);
    rows.note(which.dropped());
}

/// What the page would have to hide on this screen: readings the panels have no
/// room for, and counters the wall has no room for. Zero is the display working
/// as designed — the type scale exists to keep it there — and a host test says so
/// at every shape kudos ships for. Found by walking the very fills that draw,
/// bounded by the very rectangles they draw into.
pub fn hiddenBy(s: *const Snapshot, sc: Scale, l: Layout) usize {
    var total: usize = 0;
    for ([_]Section{ .silicon, .memory, .io }, [_]rects.Rect{ l.silicon, l.memory, l.io }) |which, r| {
        var probe = panel.Rows.probing(panel.bodyOf(r, sc.chrome), sc.body);
        fill(&probe, sc, s, which);
        total += probe.dropped;
    }
    for (Group.ALL, 0..) |g, gi| {
        const col = rects.column(l.counters, Group.ALL.len, gi, sc.gap);
        var probe = panel.Rows.probing(panel.bodyOf(col, sc.chrome), sc.fine);
        fillWall(&probe, sc, s, g);
        total += probe.dropped;
    }
    return total;
}

fn fillSilicon(rows: *panel.Rows, sc: Scale, s: *const Snapshot) void {
    var buf: [64]u8 = undefined;
    rows.row("vendor", &s.vendor, theme.WHITE);
    rows.row("tsc", std.fmt.bufPrint(&buf, "{d}.{d:0>3} GHz", .{
        s.tsc_hz / 1_000_000_000,
        (s.tsc_hz % 1_000_000_000) / 1_000_000,
    }) catch "-", theme.WHITE);
    rows.space(sc.core_gap);

    // The core matrix (HUD-006, HUD-007, HUD-008).
    const grid = coreGrid(s);
    if (grid.cores == 0) return;

    // How many rows of tiles the panel has room for is settled at the smallest
    // tile, and only then are the tiles grown to fill what is there: deciding
    // both at once would let a tile grow until it cost the panel the row it was
    // sitting in. Measuring asks for the smallest — the extra height is worth
    // having, but not worth taking off the counter wall to have.
    const span = rows.room() + sc.core_gap + panel.Rows.TOLERANCE;
    const fits = @min(grid.rows, @as(usize, @intFromFloat(@max(0, span / (sc.core_min_h + sc.core_gap)))));
    if (fits == 0) {
        rows.drop(grid.cores);
        return;
    }
    const tile_h = if (rows.unbounded)
        sc.core_min_h
    else
        // Floored: a fraction of a pixel per tile is what would cost the last row
        // of the matrix its place.
        std.math.clamp(@floor(span / @as(f32, @floatFromInt(fits)) - sc.core_gap), sc.core_min_h, sc.core_max_h);

    var placed: usize = 0;
    var row: usize = 0;
    while (row < fits) : (row += 1) {
        const band = rows.take(tile_h) orelse break;
        var col: usize = 0;
        while (col < grid.cols and placed < grid.cores) : (col += 1) {
            drawCore(rows, sc, rects.column(band, grid.cols, col, sc.core_gap), &s.cores[placed], placed);
            placed += 1;
        }
        if (row + 1 < fits) rows.space(sc.core_gap);
    }
    // Never truncate in silence: a machine with more cores than the panel can
    // show says how many it is not showing.
    rows.drop(grid.cores - placed);
}

/// How a matrix of core tiles is divided: the cores it places, the columns
/// they sit in and the rows that takes.
pub const CoreGrid = struct { cores: usize, cols: usize, rows: usize };

/// The matrix a machine with `n` cores online divides into: two columns while
/// the tiles can carry the task label in its aligned column, three while a
/// label started at the core id still fits, four only past twelve cores — where
/// the count itself is the story and `ps` carries the names. One home for the
/// division, because the panel draws it, the page's demand is measured from it,
/// and the type step is chosen against it.
pub fn gridFor(n_online: usize) CoreGrid {
    const n = @min(n_online, MAX_CORES);
    const cols: usize = if (n <= 8) 2 else if (n <= 12) 3 else 4;
    return .{ .cores = n, .cols = cols, .rows = (n + cols - 1) / cols };
}

/// The matrix this machine divides into.
pub fn coreGrid(s: *const Snapshot) CoreGrid {
    return gridFor(@as(usize, s.cores_online));
}

fn drawCore(rows: *panel.Rows, sc: Scale, r: rects.Rect, c: *const CoreLine, i: usize) void {
    const p = rows.painter orelse return;
    if (r.isEmpty()) return;
    p.fillRect(r.x, r.y, r.w, r.h, theme.CONTENT_BG);
    p.rect(r.x, r.y, r.w, r.h, theme.BORDER);

    const in = r.insetXY(sc.chrome.pad * 0.8, sc.chrome.pad * 0.5);
    const fine_h = typeface.lineHeight(sc.fine);
    var idb: [16]u8 = undefined;
    const id = std.fmt.bufPrint(&idb, "c{d:0>2}{s}", .{ i, if (c.is_bsp) " BSP" else "" }) catch "c?";
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), id, in.x, in.y + typeface.metrics(sc.fine).ascent, theme.DIM);

    var pb: [8]u8 = undefined;
    const pct = std.fmt.bufPrint(&pb, "{d}", .{c.busy_pct}) catch "0";
    const pct_base = in.y + fine_h + typeface.metrics(sc.value).ascent;
    p.glyphText(rows.tex, typeface.sheetFor(sc.value), pct, in.x, pct_base, meter.statusOf(c.busy_pct, 100).color());
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), "%", in.x + typeface.width(sc.value, pct) + 3, pct_base, theme.DIM);

    // Task and occupancy sit right of the figure, so the bar is never the only
    // statement of the reading. The figure's column is as wide as the widest
    // reading it can hold, so the task labels of a matrix line up.
    const fig_w = typeface.width(sc.value, "100") + typeface.advance(sc.fine) + sc.core_gap;
    const right: rects.Rect = .{ .x = in.x + fig_w, .y = in.y, .w = @max(0, in.w - fig_w), .h = in.h };
    if (right.w <= 0) return;

    var rq: [16]u8 = undefined;
    const rq_txt = std.fmt.bufPrint(&rq, "rq {d}", .{c.runnable}) catch "";
    const rq_w = typeface.width(sc.fine, rq_txt);
    const label_base = right.y + typeface.metrics(sc.fine).ascent;

    // The task is what the core is, the activity is what it is doing: two inks on
    // one line say that without spending a separator on it. The label sits in
    // the figure column so a matrix of labels lines up; a tile too narrow for
    // that column (the three-column matrix, or the BSP tile's long id) anchors
    // it at the id instead and, when the run queue is empty, spends the "rq 0"
    // figure's room on the name — the task IS the reading a narrow matrix
    // exists to carry, and an empty queue says nothing a 0% bar does not.
    const id_end = in.x + typeface.width(sc.fine, id) + typeface.advance(sc.fine);
    var label_x = @max(right.x, id_end);
    // A character's clearance before the queue depth, so a long activity name
    // never reads as one word with the figure beside it.
    var limit = right.right() - rq_w - 2 * typeface.advance(sc.fine);
    var rq_shown = true;
    if (limit - label_x < 4 * typeface.advance(sc.fine)) {
        label_x = id_end;
        if (c.runnable == 0) {
            rq_shown = false;
            limit = right.right();
        }
    }
    if (rq_shown) p.glyphText(rows.tex, typeface.sheetFor(sc.fine), rq_txt, right.right() - rq_w, label_base, theme.DIM);
    var tb: [TASK_LABEL + 4]u8 = undefined;
    const task = elide(&tb, sc.fine, c.taskName(), @max(0, limit - label_x));
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), task, label_x, label_base, theme.ACCENT);
    const act_x = label_x + typeface.width(sc.fine, task) + typeface.advance(sc.fine);
    var ab: [TASK_LABEL + 4]u8 = undefined;
    const act = elide(&ab, sc.fine, c.activityName(), @max(0, limit - act_x));
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), act, act_x, label_base, theme.DIM);

    const bar: rects.Rect = .{ .x = right.x, .y = pct_base - sc.bar_h, .w = right.w, .h = sc.bar_h };
    meter.draw(p, bar, c.busy_pct, 100);
}

fn fillMemory(rows: *panel.Rows, sc: Scale, s: *const Snapshot) void {
    // Where physical memory went (HUD-010): the pools the kernel can account
    // for, with everything else named as such rather than folded into one.
    const attributed = @min(s.mem_used, s.heap_arena);
    const other = s.mem_used -| attributed;
    const segs = [_]stackbar.Segment{
        .{ .label = "heap arena", .value = attributed, .color = POOL_HEAP },
        .{ .label = "other", .value = other, .color = POOL_OTHER },
    };
    if (rows.take(sc.ribbon_h)) |ribbon| {
        if (rows.painter) |p| stackbar.drawOfWhole(p, ribbon, &segs, s.mem_total);
    }
    rows.space(sc.core_gap);
    legend(rows, sc, POOL_HEAP, "heap arena", attributed);
    legend(rows, sc, POOL_OTHER, "kernel" ++ SEP ++ "GPU" ++ SEP ++ "stacks", other);
    legend(rows, sc, theme.CONTENT_BG, "free", s.mem_total -| s.mem_used);

    // The heap itself (HUD-011, HUD-012).
    rows.space(sc.core_gap);
    var buf: [48]u8 = undefined;
    rows.row("heap used", std.fmt.bufPrint(&buf, "{d} / {d} MiB", .{
        s.heap_used / (1024 * 1024),
        s.heap_arena / (1024 * 1024),
    }) catch "-", theme.WHITE);
    if (rows.take(sc.bar_h)) |bar| {
        if (rows.painter) |p| meter.draw(p, bar, s.heap_used, s.heap_arena);
    }
    rows.space(sc.core_gap);
    rows.row("largest block", std.fmt.bufPrint(&buf, "{d} MiB", .{s.heap_largest / (1024 * 1024)}) catch "-", theme.WHITE);
    rows.row("free blocks", std.fmt.bufPrint(&buf, "{d}", .{s.heap_blocks}) catch "-", theme.WHITE);
    rows.row("ramdisk", std.fmt.bufPrint(&buf, "{d} files" ++ SEP ++ "{d} KiB", .{
        s.ramdisk_files,
        s.ramdisk_bytes / 1024,
    }) catch "-", theme.WHITE);
}

/// A legend line: swatch, name, size.
fn legend(rows: *panel.Rows, sc: Scale, color: u32, name: []const u8, bytes: u64) void {
    const r = rows.take(typeface.lineHeight(sc.fine)) orelse return;
    const p = rows.painter orelse return;
    const base = r.y + typeface.metrics(sc.fine).ascent;
    const sw = @round(typeface.lineHeight(sc.fine) * 0.65);
    p.fillRect(r.x, base - sw, sw, sw, color);
    if (color == theme.CONTENT_BG) p.rect(r.x, base - sw, sw, sw, theme.BORDER);
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), name, r.x + sw + 6, base, theme.DIM);
    var buf: [24]u8 = undefined;
    const size = std.fmt.bufPrint(&buf, "{d:.1} GiB", .{gib(bytes)}) catch "-";
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), size, r.right() - typeface.width(sc.fine, size), base, theme.WHITE);
}

fn fillIo(rows: *panel.Rows, sc: Scale, s: *const Snapshot) void {
    var buf: [64]u8 = undefined;
    rows.row("present", std.fmt.bufPrint(&buf, "{d} Hz", .{s.fps}) catch "-", fpsColor(s.fps));
    rows.row("frames", std.fmt.bufPrint(&buf, "{d}", .{s.presents}) catch "-", theme.WHITE);
    rows.row("build avg / max", std.fmt.bufPrint(&buf, "{d:.1} / {d:.1} ms", .{
        @as(f64, @floatFromInt(s.pump_avg_us)) / 1000.0,
        @as(f64, @floatFromInt(s.pump_max_us)) / 1000.0,
    }) catch "-", budgetColor(s.pump_max_us));
    rows.row("refresh", std.fmt.bufPrint(&buf, "{d} us", .{s.refresh_us}) catch "-", theme.WHITE);

    rows.space(sc.core_gap);
    rows.row("address", std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{
        s.ip[0], s.ip[1], s.ip[2], s.ip[3],
    }) catch "-", if (s.link_up) theme.WHITE else theme.DIM);
    rows.row(
        "tx dropped",
        if (s.tx_dropped_known) std.fmt.bufPrint(&buf, "{d}", .{s.tx_dropped}) catch "-" else "not reported",
        if (!s.tx_dropped_known) theme.DIM else if (s.tx_dropped > 0) theme.YELLOW else theme.WHITE,
    );
    rows.row("usb devices", std.fmt.bufPrint(&buf, "{d}", .{s.usb_devices}) catch "-", theme.WHITE);
    rows.row("kbd / mouse / disk", std.fmt.bufPrint(&buf, "{s} / {s} / {s}", .{
        yesNo(s.kbd),
        yesNo(s.mouse),
        yesNo(s.usbdisk),
    }) catch "-", theme.WHITE);
    rows.row("hid reports", std.fmt.bufPrint(&buf, "{d} / {d}", .{
        s.kbd_reports,
        s.mouse_reports,
    }) catch "-", theme.WHITE);

    rows.space(sc.core_gap);
    rows.row("vt-x", if (s.vt_available) "present" else "absent", if (s.vt_available) theme.WHITE else theme.DIM);
    rows.row("guests", std.fmt.bufPrint(&buf, "{d} / {d}", .{
        s.guests_running,
        s.guest_capacity,
    }) catch "-", if (s.guests_running > 0) theme.GREEN else theme.DIM);
    rows.row("guest exits", std.fmt.bufPrint(&buf, "{d}", .{s.guest_exits}) catch "-", theme.WHITE);
}

fn drawTraces(p: *kgl.Painter, tex: u32, r: rects.Rect, sc: Scale, tr: Traces) void {
    drawTrace(p, tex, rects.column(r, 4, 0, sc.gap), sc, "FRAME TIME", "ms", tr.frame_ms, .{ .min = 0, .max = FRAME_TRACE_MAX_MS }, theme.GREEN, FRAME_BUDGET_MS);
    drawTrace(p, tex, rects.column(r, 4, 1, sc.gap), sc, "CPU BUSY", "%", tr.cpu_busy, .{ .min = 0, .max = 100 }, POOL_CPU, null);
    drawTrace(p, tex, rects.column(r, 4, 2, sc.gap), sc, "HEAP FREE", "MiB", tr.heap_free, autoOf(tr.heap_free), POOL_HEAP, null);
    drawTrace(p, tex, rects.column(r, 4, 3, sc.gap), sc, "NET RX", "frames/s", tr.net_rx, autoOf(tr.net_rx), POOL_NET, null);
}

fn drawTrace(
    p: *kgl.Painter,
    tex: u32,
    r: rects.Rect,
    sc: Scale,
    title: []const u8,
    unit: []const u8,
    series: *const Series,
    range: sparkline.Range,
    color: u32,
    budget: ?f64,
) void {
    var nb: [16]u8 = undefined;
    const body = panel.draw(p, tex, r, sc.chrome, title, std.fmt.bufPrint(&nb, "{d} s", .{HISTORY * SAMPLE_MS / 1000}) catch "");
    if (body.isEmpty()) return;

    var vb: [24]u8 = undefined;
    const value = std.fmt.bufPrint(&vb, "{d:.1}", .{series.latest() orelse 0}) catch "-";
    const base = body.y + typeface.metrics(sc.value).ascent;
    p.glyphText(tex, typeface.sheetFor(sc.value), value, body.x, base, theme.WHITE);
    p.glyphText(tex, typeface.sheetFor(sc.fine), unit, body.x + typeface.width(sc.value, value) + 5, base, theme.DIM);

    const plot = body.belowTop(typeface.lineHeight(sc.value));
    sparkline.floor(p, plot);
    if (budget) |b| sparkline.budgetLine(p, plot, range, b, theme.RED);
    sparkline.draw(p, plot, series.len, series, sampleAt, range, color);
}

/// Read sample `i` of a series through the trace's context pointer.
fn sampleAt(ctx: *const anyopaque, i: usize) f64 {
    const s: *const Series = @ptrCast(@alignCast(ctx));
    return s.at(i) orelse 0;
}

/// Counters in the fullest group — what the wall must be tall enough for.
pub fn tallestGroup(s: *const Snapshot) usize {
    var most: usize = 0;
    for (Group.ALL) |g| most = @max(most, countIn(s, g));
    return most;
}

fn drawCounters(p: *kgl.Painter, tex: u32, r: rects.Rect, sc: Scale, s: *const Snapshot) void {
    for (Group.ALL, 0..) |g, gi| {
        const col = rects.column(r, Group.ALL.len, gi, sc.gap);
        var nb: [24]u8 = undefined;
        const body = panel.draw(p, tex, col, sc.chrome, g.title(), std.fmt.bufPrint(&nb, "{d}", .{countIn(s, g)}) catch "");
        var rows = panel.Rows.over(p, tex, body, sc.fine);
        fillWall(&rows, sc, s, g);
        // The last line is spent saying what was dropped, never on one more
        // counter: a wall that silently truncates reads as a complete wall.
        rows.note("not shown");
    }
}

/// One column of the counter wall: every counter tagged with this group, in
/// registration order (HUD-019, HUD-020).
fn fillWall(rows: *panel.Rows, sc: Scale, s: *const Snapshot, g: Group) void {
    var i: usize = 0;
    while (i < s.counter_count) : (i += 1) {
        if (s.counters[i].group != g) continue;
        drawCounterRow(rows, sc, s.counters[i]);
    }
}

/// Counters tagged with `g`.
fn countIn(s: *const Snapshot, g: Group) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.counter_count) : (i += 1) {
        if (s.counters[i].group == g) n += 1;
    }
    return n;
}

fn drawCounterRow(rows: *panel.Rows, sc: Scale, c: CounterLine) void {
    const r = rows.take(rows.lineHeight()) orelse return;
    const p = rows.painter orelse return;
    const fault = isFault(c.name) and c.value > 0;
    const name_color = if (fault) theme.RED else theme.DIM;
    const value_color = if (fault) theme.RED else if (c.value > 0) theme.WHITE else theme.DIM;

    var vb: [24]u8 = undefined;
    const val = std.fmt.bufPrint(&vb, "{d}", .{c.value}) catch "-";
    var rb: [16]u8 = undefined;
    const rate = if (c.per_second >= 0.05)
        std.fmt.bufPrint(&rb, "{d:.0}/s", .{c.per_second}) catch ""
    else
        "";

    const base = r.y + typeface.metrics(sc.fine).ascent;
    const rate_w = typeface.width(sc.fine, rate);
    const val_w = typeface.width(sc.fine, val);
    const val_x = r.right() - rate_w - typeface.advance(sc.fine) - val_w;

    // A name is cut to the room the figures leave it: a counter wall whose names
    // ran under their own values would be two readings, both wrong.
    var nb: [40]u8 = undefined;
    const name = elide(&nb, sc.fine, c.name, @max(0, val_x - r.x - typeface.advance(sc.fine)));
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), name, r.x, base, name_color);
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), val, val_x, base, value_color);
    p.glyphText(rows.tex, typeface.sheetFor(sc.fine), rate, r.right() - rate_w, base, theme.DIM);
}

fn drawFooter(p: *kgl.Painter, tex: u32, r: rects.Rect, sc: Scale, s: *const Snapshot) void {
    p.line(r.x, r.y, r.right(), r.y, 1, theme.BORDER);
    const base = r.y + sc.chrome.pad * 0.6 + typeface.metrics(sc.fine).ascent;
    p.glyphText(tex, typeface.sheetFor(sc.fine), "F1 close" ++ SEP ++ "F freeze" ++ SEP ++ "A acknowledge", r.x, base, theme.DIM);

    var buf: [96]u8 = undefined;
    const right = std.fmt.bufPrint(&buf, "sampled every {d} ms" ++ SEP ++ "{d} counters" ++ SEP ++ "{d} s of history", .{
        SAMPLE_MS,
        s.counter_count,
        HISTORY * SAMPLE_MS / 1000,
    }) catch "";
    p.glyphText(tex, typeface.sheetFor(sc.fine), right, r.right() - typeface.width(sc.fine, right), base, theme.DIM);
}

// ── small helpers ───────────────────────────────────────────────────────────────

fn gib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

/// `str` cut to what fits in `px`, ending in `CUT` when it had to be cut. A label
/// that does not fit is shortened where a reader can see it was shortened —
/// never drawn over its neighbour, and never dropped without a mark.
pub fn elide(buf: []u8, role: typeface.Role, str: []const u8, px: f32) []const u8 {
    const room = typeface.fitChars(role, px);
    if (str.len <= room) return str;
    if (room <= CUT.len or buf.len < room) return "";
    const keep = room - CUT.len;
    @memcpy(buf[0..keep], str[0..keep]);
    @memcpy(buf[keep..room], CUT);
    return buf[0..room];
}

/// A present rate that is not the panel's is a fault in the making, not a detail.
fn fpsColor(fps: u32) u32 {
    if (fps == 0) return theme.DIM;
    return if (fps >= 58) theme.GREEN else theme.YELLOW;
}

/// Frame-build time against the 60 Hz budget.
fn budgetColor(us: u32) u32 {
    const ms = @as(f64, @floatFromInt(us)) / 1000.0;
    if (ms >= FRAME_BUDGET_MS) return theme.RED;
    if (ms >= FRAME_BUDGET_MS * 0.8) return theme.YELLOW;
    return theme.WHITE;
}

fn trendOf(s: *const Series) statile.Trend {
    return switch (s.trend()) {
        1 => .rising,
        -1 => .falling,
        else => .none,
    };
}

fn autoOf(s: *const Series) sparkline.Range {
    const r = s.range() orelse return .{ .min = 0, .max = 1 };
    return sparkline.autoRange(r.min, r.max, true);
}

/// "HH:MM:SS", or "--:--:--" when the clock has not been read.
pub fn formatClock(buf: []u8, secs: ?u64) []const u8 {
    const s = secs orelse return "--:--:--";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        (s / 3600) % 24,
        (s / 60) % 60,
        s % 60,
    }) catch "--:--:--";
}

/// "4h 17m 36s" from milliseconds since boot.
pub fn formatUptime(buf: []u8, ms: u64) []const u8 {
    const s = ms / 1000;
    return std.fmt.bufPrint(buf, "{d}h {d}m {d}s", .{ s / 3600, (s / 60) % 60, s % 60 }) catch "";
}
