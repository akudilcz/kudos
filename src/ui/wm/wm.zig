//! The window-manager MODEL: stacking order, focus, drag/resize/close mouse
//! handling, and screen damage tracking. No pixels — rendering is the GL
//! desktop's job (ui/desktop/desktop.zig renders the whole scene through
//! kgl → gles → idraw); this module owns only the state every frame reads.
//!
//! Damage here is a RENDER GATE, not a compositing plan: every visual change
//! funnels through markRect/markWindow/markFull, and takeSceneDamage hands the
//! renderer one verdict per frame — nothing changed (skip), a bounding box (the
//! software rasteriser scissors its redraw to it), or everything. The hardware
//! device redraws every frame regardless and consumes the verdict only to reset
//! the accumulation.

const std = @import("std");
const window = @import("window.zig");
const square = @import("square.zig");
const Window = window.Window;

// A screen-space rectangle. A Rect may extend past the screen (a window dragged
// against an edge); the renderer clips.
const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,

    /// Smallest rect covering both `self` and `o` (the bounding box). Used by
    /// markRect to COALESCE overlapping/adjacent damage into one rect instead of
    /// filling the dirty set — a fast-mouse window drag marks the same window's
    /// old+new frame dozens of times per frame, which would otherwise overflow to
    /// a full-screen redraw every frame (draw on damage).
    fn unite(self: Rect, o: Rect) Rect {
        const x0 = @min(self.x, o.x);
        const y0 = @min(self.y, o.y);
        const x1 = @max(self.x + self.w, o.x + o.w);
        const y1 = @max(self.y + self.h, o.y + o.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// True if the two rects overlap or touch (share an edge) — the threshold for
    /// coalescing. Adjacent rects are merged too: redrawing their union costs
    /// about the same as two abutting rects but keeps the dirty set small.
    fn touches(self: Rect, o: Rect) bool {
        return self.x <= o.x + o.w and o.x <= self.x + self.w and
            self.y <= o.y + o.h and o.y <= self.y + self.h;
    }
};

/// Area of a Rect (u128 so w*h can't overflow at any screen size).
fn rectArea(r: Rect) u128 {
    return @as(u128, r.w) * @as(u128, r.h);
}

/// Whether uniting two touching rects is worth it: the bounding box must not add
/// much dead area (union ≤ COALESCE_SLACK × summed area). True for adjacent drag
/// rects (union ≈ sum); false for two distant small rects that would union into a
/// screen-spanning box.
fn mergeWorthwhile(a: Rect, b: Rect) bool {
    return rectArea(a.unite(b)) <= COALESCE_SLACK * (rectArea(a) + rectArea(b));
}

/// Union-vs-sum slack factor for damage coalescing (see mergeWorthwhile).
const COALESCE_SLACK = 4;

/// Dirty-rect capacity: must fit a DRAG's live rects — the dragged window
/// (old+new) + the bouncing square (old+new) marked across several input samples
/// per frame — or the set overflows to a full-screen redraw.
pub const MAX_DIRTY = 32;

/// Hard cap on live windows. The list's capacity is reserved ONCE at init so
/// an append never reallocates the backing array — on the SMP build the
/// desktop's system task iterates this list while the command worker (a
/// separate preemptible core-0 task) appends to it, and a realloc mid-iteration
/// is a use-after-free of the iterator's slice.
pub const MAX_WINDOWS = 32;

// Drag clamp margins: a dragged window's origin may go no further right/down
// than screen size minus these, so at least this many pixels of its top-left
// corner (title bar included) stay on-screen and grabbable.
const DRAG_MIN_VISIBLE_X: usize = 40;
const DRAG_MIN_VISIBLE_Y: usize = 20;

// A pending resize: the target window and its new outer size. The desktop
// performs the app re-layout.
pub const ResizeReq = struct { win: *Window, w: usize, h: usize };

// A window action a mouse click requested that only the desktop can carry out (it
// owns the apps + allocator): close, maximise-toggle, or resize. The WM records
// ONE of these per onMouse; the desktop drains it with a single switch and clears
// it. A single slot is enough because each is the product of one click and is
// consumed on the very next tick.
pub const PendingAction = union(enum) {
    close: *Window,
    minimise: *Window,
    maximise: *Window,
    resize: ResizeReq,
};

pub const Wm = struct {
    a: std.mem.Allocator,
    // The logical screen size — clamps drags/resizes and bounds full damage. The
    // desktop updates it on a logical resize (the GPU display path raises it).
    screen_w: usize,
    screen_h: usize,
    windows: std.array_list.Managed(*Window),
    next_id: u32 = 1,
    focused: ?*Window = null,
    dragging: ?*Window = null,
    drag_dx: i32 = 0,
    drag_dy: i32 = 0,
    prev_buttons: u8 = 0,
    // A resize-grip drag: the window being resized + the cursor-to-corner offset
    // captured on press, so the far corner tracks the cursor. The WM records
    // the desired new outer size in `pending`; the desktop applies it (it owns
    // the apps) and clears it.
    resizing: ?*Window = null,
    resize_dx: i32 = 0, // cursor.x - (win.x + win.w) at grab
    resize_dy: i32 = 0, // cursor.y - (win.y + win.h) at grab
    // The one window action a click requested (close / maximise / resize) for the
    // desktop to carry out and clear after onMouse.
    pending: ?PendingAction = null,

    // Dirty tracking: rects changed since the last frame. `full` forces a
    // whole-screen redraw (first frame, resize, dirty-set overflow).
    dirty: [MAX_DIRTY]Rect = undefined,
    ndirty: usize = 0,
    full: bool = true, // first render paints everything
    // The screensaver cube's pure motion — drawn by the GL desktop above the
    // wallpaper, below every window, inside this SIZE box. The desktop drives
    // it via tickSquare beside its app ticks.
    square: square.Motion,

    /// The WM model for a `screen_w`×`screen_h` desktop with an empty window
    /// list. The first frame is a full redraw (`full` defaults true). `seed`
    /// seeds the screensaver's initial drift direction (the kernel passes
    /// `tsc.rdtsc()`; host tests pass any value).
    pub fn init(a: std.mem.Allocator, screen_w: usize, screen_h: usize, seed: u64) Wm {
        return .{
            .a = a,
            .screen_w = screen_w,
            .screen_h = screen_h,
            .windows = std.array_list.Managed(*Window).initCapacity(a, MAX_WINDOWS) catch
                @panic("wm: window-list reservation failed at init"),
            .square = square.Motion.init(seed),
        };
    }

    /// The screen size changed (the GPU display path raised the logical mode):
    /// adopt it and force a full redraw.
    pub fn resizeScreen(self: *Wm, w: usize, h: usize) void {
        self.screen_w = w;
        self.screen_h = h;
        self.markFull();
    }

    /// Mark a screen-space rectangle dirty. COALESCES: a new rect that overlaps
    /// or touches an existing dirty rect is merged into its bounding box rather
    /// than taking a new slot — this is what keeps a window drag cheap (a 1000 Hz
    /// mouse marks the dragged window's old+new frame dozens of times per frame).
    /// On overflow, fall back to a full-screen redraw (always correct).
    pub fn markRect(self: *Wm, x: i32, y: i32, w: usize, h: usize) void {
        if (self.full) return;
        // Clamp the origin to the screen; the renderer clips the far edge. When
        // the origin is clamped (negative x/y), shrink w/h by the clamped amount
        // so the rect still ends at the same place.
        const clx: usize = @intCast(@max(0, -x));
        const cly: usize = @intCast(@max(0, -y));
        var r = Rect{
            .x = @intCast(@max(x, 0)),
            .y = @intCast(@max(y, 0)),
            .w = w -| clx,
            .h = h -| cly,
        };
        if (r.w == 0 or r.h == 0) return;

        // Merge into the first existing rect it touches AND is worth uniting with,
        // then re-merge any other rects the grown union now touches (a merge can
        // bridge two previously disjoint rects), compacting the set. Bounded by
        // MAX_DIRTY, so O(n²) with tiny n — trivial.
        var i: usize = 0;
        while (i < self.ndirty) : (i += 1) {
            if (self.dirty[i].touches(r) and mergeWorthwhile(self.dirty[i], r)) {
                r = self.dirty[i].unite(r);
                self.ndirty -= 1;
                self.dirty[i] = self.dirty[self.ndirty];
                i = 0;
                continue;
            }
        }
        if (self.ndirty == MAX_DIRTY) {
            self.full = true;
            return;
        }
        self.dirty[self.ndirty] = r;
        self.ndirty += 1;
    }

    /// Mark a whole window's frame dirty (its outer rect in screen space).
    pub fn markWindow(self: *Wm, win: *const Window) void {
        self.markRect(win.x, win.y, win.w, win.h);
    }

    /// Force a full-screen redraw next frame.
    pub fn markFull(self: *Wm) void {
        self.full = true;
    }

    /// Advance the screensaver cube's box for `phase` (the desktop's `timer.now() /
    /// square.STEP_TICKS`) and, if it moved, mark its old + new rects dirty — the
    /// same move-and-damage primitive a window drag uses. Returns true iff it
    /// moved (the desktop ORs this into `changed` to trigger a render).
    pub fn tickSquare(self: *Wm, phase: u64) bool {
        const sz: usize = @intCast(square.SIZE);
        self.markRect(self.square.x, self.square.y, sz, sz); // old
        const moved = self.square.tick(phase, @intCast(self.screen_w), @intCast(self.screen_h));
        if (moved) self.markRect(self.square.x, self.square.y, sz, sz); // new
        return moved;
    }

    /// What the renderer must redraw this frame, report-and-clear: null when
    /// nothing marked damage (the frame can be skipped outright), otherwise
    /// either "everything" or the bounding box of the marked rects.
    pub const SceneDamage = struct { full: bool, x: i32, y: i32, w: u32, h: u32 };
    pub fn takeSceneDamage(self: *Wm) ?SceneDamage {
        defer {
            self.full = false;
            self.ndirty = 0;
        }
        if (self.full) return .{ .full = true, .x = 0, .y = 0, .w = 0, .h = 0 };
        if (self.ndirty == 0) return null;
        var x0 = self.dirty[0].x;
        var y0 = self.dirty[0].y;
        var x1 = self.dirty[0].x + self.dirty[0].w;
        var y1 = self.dirty[0].y + self.dirty[0].h;
        for (self.dirty[1..self.ndirty]) |r| {
            x0 = @min(x0, r.x);
            y0 = @min(y0, r.y);
            x1 = @max(x1, r.x + r.w);
            y1 = @max(y1, r.y + r.h);
        }
        // Any animating window the box TOUCHES is swallowed whole (DSK-021).
        // Its pixels come from the clock, so repainting part of it mixes two
        // instants in one frame — a band of the model at this angle inside the
        // model at an older one. Repeated as it turns, that reads as the image
        // tearing and healing rather than as anything to do with damage.
        for (self.windows.items) |w| {
            if (!w.animates or w.minimized) continue;
            // The window's rect in the same clamped screen space the dirty set
            // uses: a window may be dragged past the left or top edge, damage
            // cannot follow it there (markRect clamps the same way).
            const wx0: usize = @intCast(@max(w.x, 0));
            const wy0: usize = @intCast(@max(w.y, 0));
            const wx1: usize = @intCast(@max(w.x + @as(i32, @intCast(w.w)), 0));
            const wy1: usize = @intCast(@max(w.y + @as(i32, @intCast(w.h)), 0));
            if (x0 >= wx1 or wx0 >= x1) continue;
            if (y0 >= wy1 or wy0 >= y1) continue;
            x0 = @min(x0, wx0);
            y0 = @min(y0, wy0);
            x1 = @max(x1, wx1);
            y1 = @max(y1, wy1);
        }
        return .{ .full = false, .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
    }

    // The `windows` list IS the stacking order: index 0 is the bottom-most window,
    // the last element is the front-most (top of the z-order). Focus moves a window
    // to the end; hit-testing scans from the end. No separate z field or per-frame
    // sort.

    /// Create a window, append it to the top of the stacking order, focus it, and
    /// return it. IDs are assigned monotonically from `next_id`.
    pub fn addWindow(self: *Wm, x: i32, y: i32, w: usize, h: usize, title: []const u8) !*Window {
        if (self.windows.items.len >= MAX_WINDOWS) return error.OutOfMemory;
        const win = try window.create(self.a, self.next_id, x, y, w, h, title);
        self.next_id += 1;
        // Capacity was reserved at init: this never reallocates (see MAX_WINDOWS).
        self.windows.appendAssumeCapacity(win);
        self.focus(win);
        return win;
    }

    /// Remove a window from the list (the desktop frees it). Clears the drag/
    /// resize pointers if they referenced this window; the caller is responsible
    /// for repointing `focused` and repainting the vacated area.
    pub fn removeWindow(self: *Wm, win: *Window) void {
        if (self.dragging == win) self.dragging = null;
        if (self.resizing == win) self.resizing = null;
        for (self.windows.items, 0..) |w, idx| {
            if (w == win) {
                _ = self.windows.orderedRemove(idx); // preserve stacking order
                return;
            }
        }
    }

    /// The front-most window (top of the stacking order = last in the list), or
    /// null if there are none.
    pub fn topmost(self: *Wm) ?*Window {
        return self.windows.getLastOrNull();
    }

    /// Move `win` to the front of the stacking order (the end of the list).
    fn raise(self: *Wm, win: *Window) void {
        for (self.windows.items, 0..) |w, idx| {
            if (w == win) {
                _ = self.windows.orderedRemove(idx);
                self.windows.appendAssumeCapacity(win); // capacity held the removed slot
                return;
            }
        }
    }

    /// Make `win` the focused, front-most window and mark both the old and new
    /// frames dirty (focus colours change). Re-raising the already-focused window
    /// just bumps it to the top with no repaint.
    /// Hide `win` (spec R26): drop focus to the front-most remaining visible
    /// window and repaint the vacated region. Geometry/app state stay intact.
    pub fn minimise(self: *Wm, win: *Window) void {
        win.minimized = true;
        self.markFull();
        if (self.focused == win) {
            self.focused = null;
            win.focused = false;
            var i: usize = self.windows.items.len;
            while (i > 0) {
                i -= 1;
                const cand = self.windows.items[i];
                if (!cand.minimized) {
                    self.focus(cand);
                    break;
                }
            }
        }
    }

    /// Bring a minimised window back: visible, focused, front-most.
    pub fn unminimise(self: *Wm, win: *Window) void {
        win.minimized = false;
        self.markFull();
        self.focus(win);
    }

    /// Focus the front-most visible window whose title CONTAINS `needle`, and
    /// return it; null when nothing matches (focus is then left alone).
    ///
    /// Substring, not equality: titles carry decoration a caller should not have
    /// to reproduce exactly ("linux #0", "terminal 2"). Front-most first, so
    /// "terminal" with three of them open picks the one the user last used
    /// rather than the oldest. Minimised windows are skipped — focusing a hidden
    /// window would route keystrokes somewhere invisible, which is worse than
    /// not matching at all.
    ///
    /// Idempotent by construction: focusing the already-focused window is the
    /// no-op `focus` already implements, so a caller may repeat the request
    /// without checking first.
    pub fn focusByTitle(self: *Wm, needle: []const u8) ?*Window {
        if (needle.len == 0) return null;
        var i: usize = self.windows.items.len;
        while (i > 0) {
            i -= 1;
            const cand = self.windows.items[i];
            if (cand.minimized) continue;
            if (std.mem.indexOf(u8, cand.title, needle) == null) continue;
            self.focus(cand);
            return cand;
        }
        return null;
    }

    /// The focused window's title, or an empty slice when nothing is focused.
    /// The answer to "where would a keystroke go right now" — which is what a
    /// remote injector has to know before it types.
    pub fn focusedTitle(self: *const Wm) []const u8 {
        const f = self.focused orelse return "";
        return f.title;
    }

    pub fn focus(self: *Wm, win: *Window) void {
        if (self.focused == win) {
            self.raise(win);
            return;
        }
        if (self.focused) |f| {
            f.focused = false;
            self.markWindow(f); // defocused frame repaints
        }
        win.focused = true;
        self.raise(win);
        self.markWindow(win); // newly-focused frame repaints
        self.focused = win;
    }

    /// The front-most window under (px,py): scan from the top of the stacking
    /// order (end of the list) and take the first hit. Null if none.
    fn windowAt(self: *Wm, px: i32, py: i32) ?*Window {
        var i: usize = self.windows.items.len;
        while (i > 0) {
            i -= 1;
            const w = self.windows.items[i];
            if (w.minimized) continue; // hidden: clicks fall through
            if (w.hit(px, py)) return w;
        }
        return null;
    }

    /// Clamp a window origin coordinate to [0, hi], guarding `hi` against going
    /// negative (a window wider/taller than the screen pins to 0).
    fn clampPos(x: i32, hi: i32) i32 {
        return std.math.clamp(x, 0, @max(0, hi));
    }

    /// Handle a mouse sample. Returns true if anything visible changed.
    pub fn onMouse(self: *Wm, px: i32, py: i32, buttons: u8) bool {
        var changed = false;
        const down = (buttons & 1) != 0;
        const was_down = (self.prev_buttons & 1) != 0;

        if (down and !was_down) {
            if (self.windowAt(px, py)) |win| {
                // Hit-test order on a fresh press: close box first (it sits inside
                // both title bar and body and tears the window down — no
                // focus/drag), then maximise box, then the bottom-right resize
                // grip, then the title bar (drag-move), else the body (focus
                // only). The close + maximise boxes consume the click.
                if (win.closeHit(px, py)) {
                    self.pending = .{ .close = win };
                    self.prev_buttons = buttons; // onMouse sets this only at its tail
                    return true;
                }
                if (win.minHit(px, py)) {
                    self.pending = .{ .minimise = win };
                    self.prev_buttons = buttons;
                    return true;
                }
                if (win.maxHit(px, py)) {
                    self.pending = .{ .maximise = win };
                    self.prev_buttons = buttons;
                    return true;
                }
                self.focus(win);
                changed = true;
                if (win.resizeHit(px, py)) {
                    self.resizing = win;
                    self.resize_dx = px - (win.x + @as(i32, @intCast(win.w)));
                    self.resize_dy = py - (win.y + @as(i32, @intCast(win.h)));
                } else if (win.titleHit(px, py)) {
                    self.dragging = win;
                    self.drag_dx = px - win.x;
                    self.drag_dy = py - win.y;
                }
            }
        } else if (!down and was_down) {
            self.dragging = null;
            self.resizing = null;
        } else if (self.dragging) |win| {
            const nx = clampPos(px - self.drag_dx, @as(i32, @intCast(self.screen_w - DRAG_MIN_VISIBLE_X)));
            const ny = clampPos(py - self.drag_dy, @as(i32, @intCast(self.screen_h - DRAG_MIN_VISIBLE_Y)));
            if (nx != win.x or ny != win.y) {
                self.markWindow(win); // old position: repaint the vacated area
                win.x = nx;
                win.y = ny;
                self.markWindow(win); // new position
                changed = true;
            }
        } else if (self.resizing) |win| {
            // The grabbed far corner tracks the cursor; new outer size = corner -
            // origin. Floor at MIN_W/MIN_H and cap so the window stays on-screen
            // (far edge within the screen). Record the request; the desktop does
            // the apply + app re-layout after onMouse (it owns the apps).
            const corner_x = px - self.resize_dx;
            const corner_y = py - self.resize_dy;
            const sw: i32 = @intCast(self.screen_w);
            const sh: i32 = @intCast(self.screen_h);
            const max_w: i32 = sw - win.x;
            const max_h: i32 = sh - win.y;
            const nw: usize = @intCast(std.math.clamp(corner_x - win.x, @as(i32, @intCast(window.MIN_W)), @max(@as(i32, @intCast(window.MIN_W)), max_w)));
            const nh: usize = @intCast(std.math.clamp(corner_y - win.y, @as(i32, @intCast(window.MIN_H)), @max(@as(i32, @intCast(window.MIN_H)), max_h)));
            if (nw != win.w or nh != win.h) {
                self.pending = .{ .resize = .{ .win = win, .w = nw, .h = nh } };
                changed = true;
            }
        }
        self.prev_buttons = buttons;
        return changed;
    }
};
