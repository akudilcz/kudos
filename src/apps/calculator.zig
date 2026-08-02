//! The scientific graphing calculator app (TI-82 style): a HOME screen — an
//! entry line plus a history of evaluated expressions — and a GRAPH screen —
//! one Y= function plotted over an x-range with axes and nice ticks. All
//! maths is pure and host-tested elsewhere: parsing/evaluation in
//! apps/expr.zig, sampling/ranging/ticks in widgets/plot.zig; this file owns
//! the window, the two screens' state, and the pixel mapping.
//!
//! Keyboard only (no mouse reaches app content): printable keys edit the
//! entry line, Enter evaluates (home) or re-plots (graph), Tab flips
//! screens, and in graph mode '+'/'-' zoom the x-range about its centre.
//! Samples are recomputed only when the function or range changes — never
//! per frame.

const std = @import("std");
const kgl = @import("kgl"); // the 2D toolkit the unified GL desktop draws through
const Window = @import("../ui/wm/window.zig").Window;
const theme = @import("theme");
const font = @import("../ui/screen/font.zig"); // the glyph atlas the entry text draws with
const keymap = @import("keymap"); // key codes; the pure half of the keyboard driver
const expr = @import("expr.zig");
const calchistory = @import("calchistory.zig");
const plot = @import("../widgets/plot.zig");

const Mode = enum { home, graph };

// Entry sizing; the visible history ledger lives in calchistory.zig.
const LINE_CAP: usize = 64;

// Graph sampling resolution: one sample per plot column at the default window
// width; wider windows re-use the same samples spread across more pixels.
const GRAPH_SAMPLES: usize = 480;
const DEFAULT_X_HALF_RANGE: f64 = 10; // boot range: -10..10, the TI default
const ZOOM_FACTOR: f64 = 2;
const AXIS_TICK_TARGET: u32 = 8; // aim for about this many ticks per axis
const TICK_LEN: f32 = 4; // pixels each axis tick extends from the axis

// Layout, in pixels of content space.
const PAD: f32 = 10;
const ENTRY_H: f32 = 24;
const ROW_H: f32 = 18;
const CHAR_W: f32 = @floatFromInt(font.WIDTH); // monospace atlas cell

pub const Calculator = struct {
    win: *Window,
    mode: Mode = .home,

    line: [LINE_CAP]u8 = undefined,
    line_len: usize = 0,

    history: calchistory.History = .{},

    // Graph state: the parsed Y= program and its cached samples.
    y_src: [LINE_CAP]u8 = undefined,
    y_src_len: usize = 0,
    y_prog: ?expr.Program = null,
    y_err: ?expr.ParseError = null,
    xr: plot.Range = .{ .min = -DEFAULT_X_HALF_RANGE, .max = DEFAULT_X_HALF_RANGE },
    samples: [GRAPH_SAMPLES]f64 = undefined,
    yr: plot.Range = .{ .min = -1, .max = 1 },
    plotted: bool = false,
    dirty: bool = true, // content changed since the last draw

    pub fn create(a: std.mem.Allocator, win: *Window) !*Calculator {
        const self = try a.create(Calculator);
        self.* = .{ .win = win };
        return self;
    }

    /// Redraw only when input changed something (the plot is static between edits).
    pub fn tick(self: *Calculator) bool {
        const was = self.dirty;
        self.dirty = false;
        return was;
    }

    pub fn onResize(self: *Calculator) bool {
        self.dirty = true;
        return true;
    }

    pub fn onKey(self: *Calculator, ascii: u8) void {
        self.dirty = true;
        switch (ascii) {
            '\t' => self.mode = if (self.mode == .home) .graph else .home,
            '\r', '\n' => self.enter(),
            keymap.KEY_BACKSPACE => {
                if (self.line_len > 0) self.line_len -= 1;
            },
            '+', '-' => {
                // Graph mode with an empty entry: zoom. Otherwise it's arithmetic input.
                if (self.mode == .graph and self.line_len == 0) {
                    self.zoom(if (ascii == '+') 1.0 / ZOOM_FACTOR else ZOOM_FACTOR);
                } else {
                    self.putChar(ascii);
                }
            },
            else => {
                if (ascii >= ' ' and ascii < 0x7F) self.putChar(ascii);
            },
        }
    }

    fn putChar(self: *Calculator, ch: u8) void {
        if (self.line_len < LINE_CAP) {
            self.line[self.line_len] = ch;
            self.line_len += 1;
        }
    }

    fn zoom(self: *Calculator, factor: f64) void {
        self.xr = self.xr.zoomed(factor);
        self.replot();
    }

    fn enter(self: *Calculator) void {
        const src = std.mem.trim(u8, self.line[0..self.line_len], " ");
        if (src.len == 0) return;
        switch (self.mode) {
            .home => self.evalHome(src),
            .graph => {
                @memcpy(self.y_src[0..src.len], src);
                self.y_src_len = src.len;
                self.replotFromSource();
            },
        }
        self.line_len = 0;
    }

    fn evalHome(self: *Calculator, src: []const u8) void {
        var row: [calchistory.CAP]u8 = undefined;
        const text = switch (expr.parse(src)) {
            .ok => |prog| blk: {
                if (prog.uses_x) break :blk std.fmt.bufPrint(&row, "{s} : use Tab, x plots on the graph screen", .{src}) catch return;
                const v = expr.eval(&prog, 0);
                break :blk std.fmt.bufPrint(&row, "{s} = {d}", .{ src, v }) catch return;
            },
            .err => |e| std.fmt.bufPrint(&row, "{s} : error at {d}: {s}", .{ src, e.pos, e.msg }) catch return,
        };
        self.history.push(text);
    }



    fn replotFromSource(self: *Calculator) void {
        switch (expr.parse(self.y_src[0..self.y_src_len])) {
            .ok => |prog| {
                self.y_prog = prog;
                self.y_err = null;
                self.replot();
            },
            .err => |e| {
                self.y_prog = null;
                self.y_err = e;
                self.plotted = false;
            },
        }
    }

    fn evalAt(ctx: *const anyopaque, x: f64) f64 {
        const prog: *const expr.Program = @ptrCast(@alignCast(ctx));
        return expr.eval(prog, x);
    }

    fn replot(self: *Calculator) void {
        const prog = &(self.y_prog orelse return);
        plot.sample(evalAt, prog, self.xr, &self.samples);
        self.yr = plot.autoY(&self.samples);
        self.plotted = true;
    }

    pub fn drawGl(self: *Calculator, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, cw: usize, ch: usize, focused: bool, blink_on: bool) void {
        const w: f32 = @floatFromInt(cw);
        const h: f32 = @floatFromInt(ch);

        // Entry line, both modes: a sunken field with a caret.
        p.fillRect(PAD, PAD, w - 2 * PAD, ENTRY_H, theme.CONTENT_BG);
        p.rect(PAD, PAD, w - 2 * PAD, ENTRY_H, theme.BORDER);
        p.text(atlas_tex, atlas, self.line[0..self.line_len], PAD + 6, PAD + 5, theme.WHITE);
        if (focused and blink_on) {
            const caret_x = PAD + 6 + @as(f32, @floatFromInt(self.line_len)) * CHAR_W;
            p.fillRect(caret_x, PAD + 4, 2, ENTRY_H - 8, theme.ACCENT);
        }
        const mode_label: []const u8 = switch (self.mode) {
            .home => "HOME  (Tab: graph)",
            .graph => "GRAPH Y=  (Tab: home, +/- zoom)",
        };
        p.text(atlas_tex, atlas, mode_label, PAD, PAD + ENTRY_H + 6, theme.DIM);

        const body_y = PAD + ENTRY_H + 6 + ROW_H;
        switch (self.mode) {
            .home => self.drawHome(p, atlas_tex, atlas, body_y),
            .graph => self.drawGraph(p, atlas_tex, atlas, PAD, body_y, w - 2 * PAD, h - body_y - PAD),
        }
    }

    fn drawHome(self: *Calculator, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, y0: f32) void {
        var i: usize = 0;
        while (i < self.history.count) : (i += 1) {
            p.text(atlas_tex, atlas, self.history.row(i), PAD, y0 + @as(f32, @floatFromInt(i)) * ROW_H, theme.TEXT);
        }
    }

    fn drawGraph(self: *Calculator, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, gx: f32, gy: f32, gw: f32, gh: f32) void {
        if (gw < 40 or gh < 40) return;
        p.fillRect(gx, gy, gw, gh, theme.CONTENT_BG);
        p.rect(gx, gy, gw, gh, theme.BORDER);

        if (self.y_err) |e| {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Y= error at {d}: {s}", .{ e.pos, e.msg }) catch return;
            p.text(atlas_tex, atlas, msg, gx + 8, gy + 8, theme.YELLOW);
            return;
        }
        if (!self.plotted) {
            p.text(atlas_tex, atlas, "type a function of x, then Enter", gx + 8, gy + 8, theme.DIM);
            return;
        }

        const xspan = self.xr.max - self.xr.min;
        const yspan = self.yr.max - self.yr.min;

        // Pixel mapping (y flipped: larger values sit higher on screen).
        const px = struct {
            fn f(v: f64, lo: f64, span: f64, origin: f32, extent: f32) f32 {
                return origin + @as(f32, @floatCast((v - lo) / span)) * extent;
            }
        }.f;

        // Axes with nice ticks, drawn only when 0 is inside the range.
        if (self.yr.min < 0 and self.yr.max > 0) {
            const ay = gy + gh - (px(0, self.yr.min, yspan, 0, gh));
            p.line(gx, ay, gx + gw, ay, 1, theme.DIM);
            const step = plot.niceStep(xspan, AXIS_TICK_TARGET);
            var t = plot.firstTick(self.xr.min, step);
            while (t <= self.xr.max) : (t += step) {
                const tx = px(t, self.xr.min, xspan, gx, gw);
                p.line(tx, ay - TICK_LEN, tx, ay + TICK_LEN, 1, theme.DIM);
            }
        }
        if (self.xr.min < 0 and self.xr.max > 0) {
            const ax = px(0, self.xr.min, xspan, gx, gw);
            p.line(ax, gy, ax, gy + gh, 1, theme.DIM);
            const step = plot.niceStep(yspan, AXIS_TICK_TARGET);
            var t = plot.firstTick(self.yr.min, step);
            while (t <= self.yr.max) : (t += step) {
                const ty = gy + gh - px(t, self.yr.min, yspan, 0, gh);
                p.line(ax - TICK_LEN, ty, ax + TICK_LEN, ty, 1, theme.DIM);
            }
        }

        // The curve: one segment per adjacent finite sample pair; NaN = gap.
        var i: usize = 1;
        while (i < self.samples.len) : (i += 1) {
            const a = self.samples[i - 1];
            const b = self.samples[i];
            if (!std.math.isFinite(a) or !std.math.isFinite(b)) continue;
            const x0 = gx + gw * @as(f32, @floatFromInt(i - 1)) / @as(f32, @floatFromInt(self.samples.len - 1));
            const x1 = gx + gw * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(self.samples.len - 1));
            const y0 = gy + gh - px(a, self.yr.min, yspan, 0, gh);
            const y1 = gy + gh - px(b, self.yr.min, yspan, 0, gh);
            // Clip trivially: skip segments fully outside the viewport.
            if ((y0 < gy and y1 < gy) or (y0 > gy + gh and y1 > gy + gh)) continue;
            p.line(x0, y0, x1, y1, 1.5, theme.ACCENT);
        }

        // Range readout.
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "x: {d:.2} .. {d:.2}", .{ self.xr.min, self.xr.max }) catch return;
        p.text(atlas_tex, atlas, label, gx + 8, gy + gh - ROW_H, theme.DIM);
    }
};
