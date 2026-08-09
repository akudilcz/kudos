//! Window model: geometry, hit-tests, and the title — no pixels. The GL desktop
//! draws every window's chrome and content into the one whole-desktop frame
//! (ui/wm/glcomp.zig chrome, each app's drawGl/drawInline content); a window
//! here is purely the WM's record of where that happens and what is clickable.

const std = @import("std");
const font = @import("../screen/font.zig");
const ilog = @import("ilog");
const chrome = @import("chrome.zig");

pub const BORDER: usize = 1;
// Title-bar height. Derived from the gles chrome (chrome.zig) so the window's content
// sub-surface begins exactly under the drawn title bar: the gles compositor places the
// content quad at `chrome.TITLE_H`, and the surface's content area starts at
// `BORDER + TITLE_H`, so `BORDER + TITLE_H == chrome.TITLE_H` keeps them pixel-aligned.
pub const TITLE_H: usize = @as(usize, @intFromFloat(chrome.TITLE_H)) - BORDER;
// Resize grip: a square at the bottom-right corner; dragging it resizes the
// window. GRIP px on each side (window-local, inside the frame). Sized large
// enough to grab without pixel-hunting; the GL chrome's drawn affordance and
// the hit-test (resizeHit) both derive from it so the visible mark matches the
// grab area.
pub const GRIP: usize = 20;
// Resize hit band: in addition to the corner square, a press within EDGE_BAND px
// of the bottom OR right edge starts a resize, so the whole bottom/right frame is
// a grab target — not just the corner. Small enough that the title bar (top) and
// the bulk of the body stay drag/focus targets. resizeHit uses it.
pub const EDGE_BAND: usize = 6;
// Minimum outer size so the content area holds at least ONE full glyph cell
// contentW = w - 2*BORDER, contentH = h - 2*BORDER - TITLE_H are
// unsigned and wrap silently under ReleaseFast; sizing the minimums to a whole
// font cell keeps contentW/contentH >= one cell, so the terminal/diag col & row
// counts are >= 1 (and scroll's rows-1 index never underflows). Derived from the
// font cell so it stays correct if the font changes (single source).
pub const MIN_W: usize = 2 * BORDER + font.WIDTH;
pub const MIN_H: usize = 2 * BORDER + TITLE_H + font.HEIGHT;

/// Saved geometry for maximise/restore. Null when the window is not maximised.
pub const Geometry = struct { x: i32, y: i32, w: usize, h: usize };

pub const Window = struct {
    id: u32,
    x: i32,
    y: i32,
    w: usize,
    h: usize,
    title: []const u8,
    focused: bool,
    // Pre-maximise geometry, set when the window is maximised and restored from
    // (then cleared) on un-maximise. Null = not maximised.
    restore: ?Geometry = null,
    // Minimised: hidden from rendering and hit-testing until restored from the
    // dock (spec R26). Geometry and app state are untouched while hidden.
    minimized: bool = false,
    /// This window's content is a function of the CLOCK, not of anything that
    /// marks damage — a spinning model redraws at whatever angle the time says
    /// when the pixel is shaded (spec DSK-021).
    ///
    /// Such a window cannot take a partial repaint. Damage is a bounding box and
    /// the rasteriser scissors to it, so an unrelated rect that merely overlaps
    /// this window repaints a STRIP of it at the current angle while the rest
    /// still holds a strip from an older one — the frame tears into bands that
    /// heal and re-tear as it turns. The window manager expands damage to cover
    /// the whole of any animating window it touches; the flag is what tells it
    /// which windows those are.
    animates: bool = false,

    /// Width of the app content area (outer width minus the two side borders).
    pub fn contentW(self: *const Window) usize {
        return self.w - 2 * BORDER;
    }
    /// Height of the app content area (outer height minus borders and title bar).
    pub fn contentH(self: *const Window) usize {
        return self.h - 2 * BORDER - TITLE_H;
    }

    /// Screen x of the content area's left edge (inside the left border).
    pub fn contentX(self: *const Window) i32 {
        return self.x + @as(i32, @intCast(BORDER));
    }
    /// Screen y of the content area's top edge (below the border and title bar).
    pub fn contentY(self: *const Window) i32 {
        return self.y + @as(i32, @intCast(BORDER + TITLE_H));
    }

    // A screen click in this window's own coordinates (origin at the window's top-left,
    // y down) — the frame the gles chrome's pure hit-tests take.
    fn localX(self: *const Window, px: i32) f32 {
        return @floatFromInt(px - self.x);
    }
    fn localY(self: *const Window, py: i32) f32 {
        return @floatFromInt(py - self.y);
    }

    /// Hit-test the maximise (zoom) traffic light — the green one, rightmost of the three.
    pub fn maxHit(self: *const Window, px: i32, py: i32) bool {
        const b = chrome.buttonAt(self.localX(px), self.localY(py)) orelse return false;
        return b == .zoom;
    }

    /// Hit-test the resize area: the bottom-right GRIP corner square OR a thin
    /// EDGE_BAND along the bottom / right edge. The edge bands are restricted to
    /// BELOW the title bar so a press on the right edge at the title-bar row still
    /// starts a title drag (hit-test order is close → max → resize → title, so an
    /// unrestricted right band would steal the title's right end). The band spans
    /// the whole bottom/right frame so the grip is easy to grab. All offsets derive
    /// from GRIP/EDGE_BAND so the drawn affordance matches the grab area.
    pub fn resizeHit(self: *const Window, px: i32, py: i32) bool {
        const right = self.x + @as(i32, @intCast(self.w));
        const bottom = self.y + @as(i32, @intCast(self.h));
        // The corner square (bottom-right).
        const gx = right - @as(i32, @intCast(BORDER + GRIP));
        const gy = bottom - @as(i32, @intCast(BORDER + GRIP));
        if (px >= gx and px < right and py >= gy and py < bottom) return true;
        // Edge bands apply only below the title bar (the body region).
        const body_top = self.y + @as(i32, @intCast(BORDER + TITLE_H));
        if (py < body_top or py >= bottom or px < self.x or px >= right) return false;
        const near_bottom = py >= bottom - @as(i32, @intCast(BORDER + EDGE_BAND));
        const near_right = px >= right - @as(i32, @intCast(BORDER + EDGE_BAND));
        return near_bottom or near_right;
    }

    /// Resize to a new LOGICAL outer size, clamped up to MIN_W/MIN_H (same
    /// invariant as `create`, so contentW/contentH — unsigned subtractions —
    /// never wrap and the content area holds at least one glyph cell). Geometry
    /// only: the GL desktop redraws the chrome and content at the new size on
    /// the next frame. The caller re-lays-out the hosted app (App.onResize) and
    /// marks the screen dirty.
    pub fn resize(self: *Window, new_w: usize, new_h: usize) void {
        self.w = @max(new_w, MIN_W);
        self.h = @max(new_h, MIN_H);
    }

    /// Hit-test the whole window frame (any pixel of its outer rect).
    pub fn hit(self: *const Window, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + @as(i32, @intCast(self.w)) and
            py >= self.y and py < self.y + @as(i32, @intCast(self.h));
    }

    /// Hit-test the title bar (the drag-move handle): the top strip minus the traffic
    /// lights, which `chrome.onTitleBar` already excludes so a button press never drags.
    pub fn titleHit(self: *const Window, px: i32, py: i32) bool {
        return chrome.onTitleBar(self.localX(px), self.localY(py));
    }

    /// Hit-test the close traffic light — the red one, leftmost of the three.
    pub fn closeHit(self: *const Window, px: i32, py: i32) bool {
        const b = chrome.buttonAt(self.localX(px), self.localY(py)) orelse return false;
        return b == .close;
    }

    /// Hit-test the minimise traffic light — the amber one, middle of the three.
    pub fn minHit(self: *const Window, px: i32, py: i32) bool {
        const b = chrome.buttonAt(self.localX(px), self.localY(py)) orelse return false;
        return b == .minimise;
    }
};

/// Allocate a window record. The outer size is clamped up to MIN_W/MIN_H so
/// contentW/contentH (unsigned subtractions) never wrap and the content area
/// holds at least one glyph cell. The caller owns freeing the struct and the
/// (heap-owned) title. Returns error on allocation failure.
pub fn create(a: std.mem.Allocator, id: u32, x: i32, y: i32, w: usize, h: usize, title: []const u8) !*Window {
    // Clamp up to the minimum; warn so a too-small request surfaces the caller.
    var cw = w;
    var ch = h;
    if (cw < MIN_W or ch < MIN_H) {
        ilog.puts("wm.window.create: too-small window requested w=");
        ilog.putHex(w);
        ilog.puts(" h=");
        ilog.putHex(h);
        ilog.puts(" clamped\n");
        if (cw < MIN_W) cw = MIN_W;
        if (ch < MIN_H) ch = MIN_H;
    }
    const win = try a.create(Window);
    win.* = .{
        .id = id,
        .x = x,
        .y = y,
        .w = cw,
        .h = ch,
        .title = title,
        .focused = false,
    };
    return win;
}
