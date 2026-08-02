//! Blob window — the cross-task contract between a sandboxed app that renders its
//! OWN window (abi `Interface.draw`, the producer, running in a session task)
//! and the desktop compositor (the consumer, the system task). The two peer groups — the
//! console app-runtime and the ui desktop — must not import each other, so they
//! share ONLY this leaf: the app parks an open request and blits pixels; the
//! desktop fulfils the request, OWNS the pixel buffer, and reads dirty frames to
//! composite.
//!
//! LEAF under src/iface/ — holds no ui types, so the kernel and the host tests
//! both compile it. ONE window at a time (v1): a second open request while one is
//! live is refused (`open` returns handle 0 to that app).
//!
//! LOCK-FREE by construction, like `imouse`: producer and consumer touch shared
//! state only in thread context, and the two hazards are ordered by release/
//! acquire, not a spinlock (which would stall the compositor across a full-frame
//! copy). `win_handle` orders the buffer publish (consumer writes buf_* then
//! releases the handle; producer acquires the handle then reads buf_*). `dirty`
//! orders a blitted frame (producer copies pixels then releases dirty; consumer
//! acquires dirty then reads the buffer). A frame read mid-copy tears — cosmetic
//! for a display, like screen tearing — and never reads out of bounds because the
//! buffer size is fixed for the window's life.

const abi = @import("abi");

/// The open handshake. `req_*` are written before `open_pending` is released and
/// read after it is acquired, so no separate atomics are needed for them.
var open_pending: bool = false;
var req_w: u32 = 0;
var req_h: u32 = 0;

/// The live window. `win_handle` (0 = none) is the publish barrier for `buf_*`.
var win_handle: u32 = 0;
var buf_ptr: ?[*]u32 = null;
var buf_w: u32 = 0;
var buf_h: u32 = 0;

/// A blitted frame awaits upload.
var dirty: bool = false;

/// A close was requested (by the app returning, or the desktop closing the window).
var close_pending: bool = false;

/// PRODUCER (app, application core): park a request to open one window, sized
/// `w`x`h` clamped to the draw-interface ceiling. Ignored (no-op) when a window
/// is already live or a request is already pending — the app's `open` then reads
/// handle 0 and reports failure.
pub fn requestOpen(w: u32, h: u32) void {
    if (@atomicLoad(u32, &win_handle, .acquire) != 0) return;
    if (@atomicLoad(bool, &open_pending, .acquire)) return;
    req_w = @min(@max(w, 1), abi.DRAW_MAX_W);
    req_h = @min(@max(h, 1), abi.DRAW_MAX_H);
    @atomicStore(bool, &open_pending, true, .release);
}

pub const OpenReq = struct { w: u32, h: u32 };

/// CONSUMER (the desktop's system task): take the pending open request, if any.
pub fn takeOpenRequest() ?OpenReq {
    if (!@atomicLoad(bool, &open_pending, .acquire)) return null;
    const r = OpenReq{ .w = req_w, .h = req_h };
    @atomicStore(bool, &open_pending, false, .release);
    return r;
}

/// CONSUMER: publish the created window's non-zero handle and its desktop-owned
/// pixel buffer (`buf` must hold at least `w*h` u32 BGRA pixels, tightly packed).
pub fn provide(new_handle: u32, buf: [*]u32, w: u32, h: u32) void {
    buf_ptr = buf;
    buf_w = w;
    buf_h = h;
    dirty = false;
    @atomicStore(u32, &win_handle, new_handle, .release); // barrier: publishes buf_*
}

/// PRODUCER: the handle the desktop published, or 0 while the open is unfulfilled
/// (or was refused). The acquire pairs with `provide`'s release.
pub fn handle() u32 {
    return @atomicLoad(u32, &win_handle, .acquire);
}

/// PRODUCER: copy a `w`x`h` block of tightly-packed BGRA pixels into the window
/// buffer and mark it dirty. No-op unless `h_handle` is the live window and the
/// block fits the buffer.
pub fn blit(h_handle: u32, pixels: [*]const u32, w: u32, h: u32) void {
    if (@atomicLoad(u32, &win_handle, .acquire) != h_handle or h_handle == 0) return;
    const dst = buf_ptr orelse return;
    if (w > buf_w or h > buf_h) return;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const s = pixels + row * w;
        const d = dst + row * buf_w;
        var col: u32 = 0;
        while (col < w) : (col += 1) d[col] = s[col];
    }
    @atomicStore(bool, &dirty, true, .release); // barrier: publishes the pixels
}

pub const Frame = struct { buf: [*]u32, w: u32, h: u32 };

/// CONSUMER: if the buffer changed since the last take, return it and clear dirty;
/// else null (nothing to re-upload this frame).
pub fn takeDirty() ?Frame {
    if (!@atomicLoad(bool, &dirty, .acquire)) return null;
    @atomicStore(bool, &dirty, false, .monotonic);
    const b = buf_ptr orelse return null;
    return .{ .buf = b, .w = buf_w, .h = buf_h };
}

/// PRODUCER or CONSUMER: request the window close (the app returned, or the user
/// closed it). The consumer drains it with `takeClose`.
pub fn requestClose() void {
    @atomicStore(bool, &close_pending, true, .release);
}

/// CONSUMER: whether a close is pending. `true` also RESETS the whole mailbox so a
/// new window can open — the caller must have already dropped its buffer.
pub fn takeClose() bool {
    if (!@atomicLoad(bool, &close_pending, .acquire)) return false;
    reset();
    return true;
}

/// CONSUMER: clear all state (window gone; the buffer it owned is freed by the
/// caller). A subsequent `requestOpen` starts fresh.
pub fn reset() void {
    buf_ptr = null;
    buf_w = 0;
    buf_h = 0;
    @atomicStore(bool, &dirty, false, .release);
    @atomicStore(bool, &open_pending, false, .release);
    @atomicStore(bool, &close_pending, false, .release);
    @atomicStore(u32, &win_handle, 0, .release);
}
