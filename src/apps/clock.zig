//! The analog clock app: a dial with twelve hour ticks and three hands,
//! reading wall-clock time (kernel/timer/wallclock.zig, the boot-time RTC
//! read). All trigonometry is in widgets/clockface.zig (pure, host-tested);
//! this file owns only the window, the once-per-second redraw cadence, and
//! the colours. With no stable RTC the face stays dead and says so — honest
//! over decorative.

const std = @import("std");
const kgl = @import("kgl"); // the 2D toolkit the unified GL desktop draws through
const Window = @import("../ui/wm/window.zig").Window;
const theme = @import("theme");
const timer = @import("../kernel/timer/timer.zig");
const wallclock = @import("../kernel/timer/wallclock.zig");
const clockface = @import("../widgets/clockface.zig");

// One redraw per second: the second hand steps, nothing else moves faster.
// 100 ticks = 1 s at the 100 Hz tick timer (same throttle shape as the
// system monitor's REFRESH_TICKS).
const REDRAW_TICKS: u64 = 100;

// Dial styling.
const FACE_MARGIN: f32 = 12; // gap between the dial rim and the content edge
const RIM_COLOR: u32 = theme.BORDER;
const FACE_COLOR: u32 = theme.CONTENT_BG;
const TICK_COLOR: u32 = theme.DIM;
const HOUR_COLOR: u32 = theme.WHITE;
const MINUTE_COLOR: u32 = theme.WHITE;
const SECOND_COLOR: u32 = theme.ACCENT;
const HUB_RADIUS: f32 = 4;
const RIM_WIDTH: f32 = 3;
const TICK_WIDTH: f32 = 2;
const HOUR_WIDTH: f32 = 5;
const MINUTE_WIDTH: f32 = 3;
const SECOND_WIDTH: f32 = 1.5;

pub const Clock = struct {
    win: *Window,
    redraw_phase: u64 = 0,

    pub fn create(a: std.mem.Allocator, win: *Window) !*Clock {
        const self = try a.create(Clock);
        self.* = .{ .win = win };
        return self;
    }

    /// Once per second the second hand moves; between steps the face is static.
    pub fn tick(self: *Clock) bool {
        const phase = timer.now() / REDRAW_TICKS;
        if (phase == self.redraw_phase) return false;
        self.redraw_phase = phase;
        return true;
    }

    /// No key handling: the clock is a passive view.
    pub fn onKey(self: *Clock, ascii: u8) void {
        _ = self;
        _ = ascii;
    }

    /// Every dimension derives from the content size at draw time; just repaint.
    pub fn onResize(self: *Clock) bool {
        _ = self;
        return true;
    }

    pub fn drawGl(self: *Clock, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, cw: usize, ch: usize, focused: bool, blink_on: bool) void {
        _ = self;
        _ = focused;
        _ = blink_on;
        const w: f32 = @floatFromInt(cw);
        const h: f32 = @floatFromInt(ch);
        const cx = w / 2;
        const cy = h / 2;
        const r = @max(@min(w, h) / 2 - FACE_MARGIN, 1);

        // Dial: rim disc, then the face inset by the rim width.
        p.disc(cx, cy, r + RIM_WIDTH, RIM_COLOR);
        p.disc(cx, cy, r, FACE_COLOR);
        var i: u32 = 0;
        while (i < clockface.TICK_COUNT) : (i += 1) {
            const seg = clockface.tick(i, cx, cy, r);
            p.line(seg.x0, seg.y0, seg.x1, seg.y1, TICK_WIDTH, TICK_COLOR);
        }

        const now = wallclock.secondsSinceMidnight() orelse {
            // No RTC: a dead face with a plain statement of why (R59: never silent).
            p.text(atlas_tex, atlas, "no RTC", cx - 30, cy + r / 2, theme.DIM);
            return;
        };

        const hh = clockface.hourHand(now, cx, cy, r);
        const mh = clockface.minuteHand(now, cx, cy, r);
        const sh = clockface.secondHand(now, cx, cy, r);
        p.line(hh.x0, hh.y0, hh.x1, hh.y1, HOUR_WIDTH, HOUR_COLOR);
        p.line(mh.x0, mh.y0, mh.x1, mh.y1, MINUTE_WIDTH, MINUTE_COLOR);
        p.line(sh.x0, sh.y0, sh.x1, sh.y1, SECOND_WIDTH, SECOND_COLOR);
        p.disc(cx, cy, HUB_RADIUS, SECOND_COLOR);
    }
};
