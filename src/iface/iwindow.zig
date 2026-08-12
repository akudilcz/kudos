//! Module windows — the cross-task contract between a sandboxed module (the
//! producer, on a session core) and the desktop compositor (the consumer, the
//! system task). Peer groups that must not import each other share only this
//! leaf: the module parks create/close requests, blits pixels and pops its
//! input; the desktop fulfils, composites and feeds.
//!
//! MANY WINDOWS: `MAX_WINDOWS` slots addressed by handle (MOD-012). A handle is
//! `(slot index + 1) | generation`, so a stale handle names a dead window rather
//! than the live one that reused its slot.
//!
//! Pixels live HERE, statically, sized to the ceiling: a module's `blit` may be
//! mid-copy on another core when the desktop tears the window down, and a heap
//! buffer freed then would be a use-after-free written from sandboxed code. The
//! worst a late blit can do is colour pixels nobody composites.
//!
//! LOCK-FREE: producer and consumer touch shared state only in thread context.
//! `state` orders a slot's publication, `dirty` orders a blitted frame. A frame
//! read mid-copy tears, which is cosmetic, and never reads out of bounds because
//! a slot's size is fixed for its life.

const abi = @import("abi");
const ring = @import("ring");

/// Windows one module may own; the ABI states the same number.
pub const MAX_WINDOWS: usize = abi.WINDOW_MAX_COUNT;

/// Keystrokes buffered for a focused window. Matches the session editors' ring:
/// a burst of injected text must not drop bytes.
pub const KEY_RING_CAP = 128;

/// How a slot's content arrives, fixed at create.
pub const Mode = enum(u8) { pixels, scene };

/// A slot's life. `requested` and `closing` are the two handshakes: the desktop
/// takes the first and the module observes the second.
const State = enum(u8) { free, requested, live, closing };

const Slot = struct {
    state: State = .free,
    /// Bumped on every create so a stale handle cannot match a reused slot.
    generation: u16 = 0,
    mode: Mode = .pixels,
    /// Requested at create; the published content size after that.
    w: u32 = 0,
    h: u32 = 0,
    title: [abi.WINDOW_TITLE_MAX]u8 = undefined,
    title_len: usize = 0,
    /// Set by the desktop when the user resizes; the module reads it via `size`.
    focused: bool = false,
    dirty: bool = false,
    keys: ring.Ring(u8, KEY_RING_CAP) = .{},
    keys_dropped: u64 = 0,
    ptr_x: i32 = 0,
    ptr_y: i32 = 0,
    ptr_buttons: u8 = 0,
    ptr_valid: bool = false,
};

var slots: [MAX_WINDOWS]Slot = @splat(.{});

/// One content buffer per slot, BGRA at the slot's width.
var framebufs: [MAX_WINDOWS][@as(usize, abi.WINDOW_MAX_W) * abi.WINDOW_MAX_H]u32 = undefined;

fn handleOf(i: usize, gen: u16) u32 {
    return (@as(u32, @intCast(i)) + 1) | (@as(u32, gen) << 16);
}

/// The live slot a handle names, or null (stale, or never valid).
fn slotOf(h: u32) ?*Slot {
    if (h == 0) return null;
    const idx = (h & 0xFFFF);
    if (idx == 0 or idx > MAX_WINDOWS) return null;
    const s = &slots[idx - 1];
    if (@atomicLoad(State, &s.state, .acquire) != .live) return null;
    if (@as(u16, @intCast(h >> 16)) != s.generation) return null;
    return s;
}

// ── producer (the module, on its own core) ───────────────────────────────────

/// Park a create request for a `w`x`h` window (clamped) and return the handle
/// the desktop will publish, or 0 when every slot is taken. The handle is valid
/// only once `live(h)` says so — the module waits on that.
pub fn requestCreate(w: u32, h: u32, want: Mode, title: []const u8) u32 {
    for (&slots, 0..) |*s, i| {
        if (@atomicLoad(State, &s.state, .acquire) != .free) continue;
        s.generation +%= 1;
        s.mode = want;
        s.w = @min(@max(w, 1), abi.WINDOW_MAX_W);
        s.h = @min(@max(h, 1), abi.WINDOW_MAX_H);
        s.title_len = @min(title.len, s.title.len);
        @memcpy(s.title[0..s.title_len], title[0..s.title_len]);
        s.focused = false;
        s.dirty = false;
        s.ptr_valid = false;
        s.keys = .{};
        s.keys_dropped = 0;
        @atomicStore(State, &s.state, .requested, .release);
        return handleOf(i, s.generation);
    }
    return 0;
}

/// Whether the desktop has created this window and it is still open.
pub fn live(h: u32) bool {
    return slotOf(h) != null;
}

/// Whether the window is gone or going — the module's cue to stop drawing.
pub fn closed(h: u32) bool {
    if (h == 0) return true;
    const idx = h & 0xFFFF;
    if (idx == 0 or idx > MAX_WINDOWS) return true;
    const s = &slots[idx - 1];
    if (@as(u16, @intCast(h >> 16)) != s.generation) return true;
    return @atomicLoad(State, &s.state, .acquire) != .live;
}

/// The window's current content size.
pub fn size(h: u32, out_w: *u32, out_h: *u32) bool {
    const s = slotOf(h) orelse return false;
    out_w.* = s.w;
    out_h.* = s.h;
    return true;
}

pub fn focused(h: u32) bool {
    const s = slotOf(h) orelse return false;
    return @atomicLoad(bool, &s.focused, .acquire);
}

pub fn mode(h: u32) ?Mode {
    const s = slotOf(h) orelse return null;
    return s.mode;
}

/// The slot index a live handle names — how a caller keying per-window state
/// (the scene mailboxes) addresses it. Null for a stale handle.
pub fn indexOf(h: u32) ?usize {
    if (slotOf(h) == null) return null;
    return (h & 0xFFFF) - 1;
}

/// Rename a live window; the desktop picks it up on its next pass.
pub fn retitle(h: u32, title: []const u8) bool {
    const s = slotOf(h) orelse return false;
    const n = @min(title.len, s.title.len);
    @memcpy(s.title[0..n], title[0..n]);
    s.title_len = n;
    return true;
}

/// Ask the desktop to close this window.
pub fn requestClose(h: u32) void {
    const s = slotOf(h) orelse return;
    @atomicStore(State, &s.state, .closing, .release);
}

/// Copy `w`x`h` BGRA pixels into a pixels-mode window and mark it dirty.
pub fn blit(h: u32, pixels: [*]const u32, w: u32, hgt: u32) void {
    const s = slotOf(h) orelse return;
    if (s.mode != .pixels) return;
    if (w > s.w or hgt > s.h) return;
    const idx = (h & 0xFFFF) - 1;
    const dst = &framebufs[idx];
    var row: u32 = 0;
    while (row < hgt) : (row += 1) {
        const src = pixels + row * w;
        const d = dst[row * s.w ..];
        var col: u32 = 0;
        while (col < w) : (col += 1) d[col] = src[col];
    }
    @atomicStore(bool, &s.dirty, true, .release); // barrier: publishes the pixels
}

/// The next keystroke for this window, or null.
pub fn popKey(h: u32) ?u8 {
    const s = slotOf(h) orelse return null;
    return s.keys.pop();
}

pub const Pointer = struct { x: i32, y: i32, buttons: u8 };

/// The latest pointer sample, or null when the pointer is elsewhere or the
/// window is unfocused. Sampled state, not a queue: a position's newest value
/// is the only useful one.
pub fn pointer(h: u32) ?Pointer {
    const s = slotOf(h) orelse return null;
    if (!@atomicLoad(bool, &s.ptr_valid, .acquire)) return null;
    return .{ .x = s.ptr_x, .y = s.ptr_y, .buttons = s.ptr_buttons };
}

/// Windows a module owns right now, and their handles by index — how a module
/// enumerates what it has without tracking handles itself.
pub fn count() u32 {
    var n: u32 = 0;
    for (&slots) |*s| {
        if (@atomicLoad(State, &s.state, .acquire) == .live) n += 1;
    }
    return n;
}

pub fn at(i: u32) u32 {
    var n: u32 = 0;
    for (&slots, 0..) |*s, idx| {
        if (@atomicLoad(State, &s.state, .acquire) != .live) continue;
        if (n == i) return handleOf(idx, s.generation);
        n += 1;
    }
    return 0;
}

// ── consumer (the desktop, system task) ──────────────────────────────────────

pub const CreateReq = struct { handle: u32, w: u32, h: u32, mode: Mode, title: []const u8 };

/// Take one pending create request, if any.
pub fn takeCreateRequest() ?CreateReq {
    for (&slots, 0..) |*s, i| {
        if (@atomicLoad(State, &s.state, .acquire) != .requested) continue;
        return .{
            .handle = handleOf(i, s.generation),
            .w = s.w,
            .h = s.h,
            .mode = s.mode,
            .title = s.title[0..s.title_len],
        };
    }
    return null;
}

/// Publish the created window: the request becomes live.
pub fn provide(h: u32) void {
    const idx = h & 0xFFFF;
    if (idx == 0 or idx > MAX_WINDOWS) return;
    const s = &slots[idx - 1];
    @atomicStore(State, &s.state, .live, .release);
}

/// Take one pending close, if any, freeing the slot. The caller has already
/// dropped whatever it held for the window.
pub fn takeClose() ?u32 {
    for (&slots, 0..) |*s, i| {
        if (@atomicLoad(State, &s.state, .acquire) != .closing) continue;
        const h = handleOf(i, s.generation);
        @atomicStore(State, &s.state, .free, .release);
        return h;
    }
    return null;
}

/// Tear a window down from the desktop's side (its close box, or the module's
/// run ending).
pub fn destroy(h: u32) void {
    const idx = h & 0xFFFF;
    if (idx == 0 or idx > MAX_WINDOWS) return;
    const s = &slots[idx - 1];
    @atomicStore(bool, &s.dirty, false, .release);
    @atomicStore(bool, &s.ptr_valid, false, .release);
    @atomicStore(State, &s.state, .free, .release);
}

/// Free every slot (a module's run ended). A late blit from its core then finds
/// no live window.
pub fn reset() void {
    for (&slots) |*s| {
        @atomicStore(bool, &s.dirty, false, .release);
        @atomicStore(bool, &s.ptr_valid, false, .release);
        @atomicStore(State, &s.state, .free, .release);
    }
}

pub const Frame = struct { buf: [*]const u32, w: u32, h: u32 };

/// A blitted frame awaiting upload, or null.
pub fn takeDirty(h: u32) ?Frame {
    const s = slotOf(h) orelse return null;
    if (!@atomicLoad(bool, &s.dirty, .acquire)) return null;
    @atomicStore(bool, &s.dirty, false, .monotonic);
    return .{ .buf = &framebufs[(h & 0xFFFF) - 1], .w = s.w, .h = s.h };
}

/// Publish the window's content size after a resize.
pub fn setSize(h: u32, w: u32, hgt: u32) void {
    const s = slotOf(h) orelse return;
    s.w = @min(w, abi.WINDOW_MAX_W);
    s.h = @min(hgt, abi.WINDOW_MAX_H);
}

pub fn setFocused(h: u32, on: bool) void {
    const s = slotOf(h) orelse return;
    @atomicStore(bool, &s.focused, on, .release);
}

/// One keystroke for a focused window. A full ring counts the loss: a dropped
/// byte turns a typed line into a different line.
pub fn pushKey(h: u32, ascii: u8) void {
    const s = slotOf(h) orelse return;
    if (!s.keys.push(ascii)) s.keys_dropped += 1;
}

pub fn keysDropped(h: u32) u64 {
    const s = slotOf(h) orelse return 0;
    return s.keys_dropped;
}

/// The pointer is over this window at content-local `x`,`y`.
pub fn pushPointer(h: u32, x: i32, y: i32, buttons: u8) void {
    const s = slotOf(h) orelse return;
    s.ptr_x = x;
    s.ptr_y = y;
    s.ptr_buttons = buttons;
    @atomicStore(bool, &s.ptr_valid, true, .release);
}

/// The pointer left this window (or focus did).
pub fn clearPointer(h: u32) void {
    const s = slotOf(h) orelse return;
    @atomicStore(bool, &s.ptr_valid, false, .release);
}
