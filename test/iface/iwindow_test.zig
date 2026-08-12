//! Host tests of src/iface/iwindow.zig — the module-window slot table
//! (MOD-012, MOD-013, MOD-014). Single-threaded: the release/acquire ordering is
//! a no-op without contention, but every transition is exercised.

const std = @import("std");
const abi = @import("abi");
const iw = @import("iwindow");

/// create → take → provide, the whole handshake.
fn open(w: u32, h: u32, mode: iw.Mode, title: []const u8) u32 {
    const handle = iw.requestCreate(w, h, mode, title);
    const req = iw.takeCreateRequest().?;
    iw.provide(req.handle);
    return handle;
}

test "create is a handshake, and the handle names the window afterwards (MOD-012)" {
    iw.reset();
    try std.testing.expectEqual(@as(?iw.CreateReq, null), iw.takeCreateRequest());

    const h = iw.requestCreate(320, 240, .pixels, "plot");
    try std.testing.expect(h != 0);
    // Not live until the desktop provides it.
    try std.testing.expect(!iw.live(h));
    const req = iw.takeCreateRequest().?;
    try std.testing.expectEqual(@as(u32, 320), req.w);
    try std.testing.expectEqual(@as(u32, 240), req.h);
    try std.testing.expectEqualStrings("plot", req.title);
    try std.testing.expectEqual(h, req.handle);
    iw.provide(req.handle);
    try std.testing.expect(iw.live(h));
    try std.testing.expect(!iw.closed(h));
    iw.reset();
}

test "several windows coexist, and the module can enumerate them (MOD-012)" {
    iw.reset();
    var handles: [abi.WINDOW_MAX_COUNT]u32 = undefined;
    for (&handles, 0..) |*slot, i| {
        slot.* = open(64, 64, .pixels, "w");
        try std.testing.expect(slot.* != 0);
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), iw.count());
    }
    // Full: one more is refused rather than evicting a live window.
    try std.testing.expectEqual(@as(u32, 0), iw.requestCreate(64, 64, .pixels, "extra"));

    // `at` walks exactly the live handles.
    var seen: u32 = 0;
    var i: u32 = 0;
    while (i < iw.count()) : (i += 1) {
        const h = iw.at(i);
        try std.testing.expect(iw.live(h));
        for (handles) |k| {
            if (k == h) seen += 1;
        }
    }
    try std.testing.expectEqual(abi.WINDOW_MAX_COUNT, seen);
    iw.reset();
}

test "a closed window frees its slot; a stale handle names nothing (MOD-014)" {
    iw.reset();
    const a = open(64, 64, .pixels, "a");
    iw.requestClose(a);
    // The producer sees it going before the desktop drains it.
    try std.testing.expect(iw.closed(a));
    try std.testing.expectEqual(a, iw.takeClose().?);
    try std.testing.expect(iw.takeClose() == null);
    try std.testing.expect(!iw.live(a));

    // The slot is reused, and the OLD handle must not name the new window.
    const b = open(64, 64, .pixels, "b");
    try std.testing.expect(iw.live(b));
    try std.testing.expect(!iw.live(a));
    try std.testing.expect(iw.closed(a));
    try std.testing.expect(a != b);
    iw.reset();
}

test "requestCreate clamps the size and refuses zero" {
    iw.reset();
    _ = iw.requestCreate(abi.WINDOW_MAX_W + 1000, abi.WINDOW_MAX_H + 1000, .pixels, "big");
    const big = iw.takeCreateRequest().?;
    try std.testing.expectEqual(abi.WINDOW_MAX_W, big.w);
    try std.testing.expectEqual(abi.WINDOW_MAX_H, big.h);
    iw.reset();
    _ = iw.requestCreate(0, 0, .pixels, "zero");
    const zero = iw.takeCreateRequest().?;
    try std.testing.expectEqual(@as(u32, 1), zero.w);
    try std.testing.expectEqual(@as(u32, 1), zero.h);
    iw.reset();
}

test "blit copies for a live pixels window; wrong handle, oversize and scene no-op" {
    iw.reset();
    const h = open(2, 2, .pixels, "px");
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty(h));

    const px = [_]u32{ 0x11, 0x22, 0x33, 0x44 };
    iw.blit(h ^ 0x0F00, &px, 2, 2); // stale generation
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty(h));
    iw.blit(h, &px, 4, 4); // bigger than the content
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty(h));

    iw.blit(h, &px, 2, 2);
    const f = iw.takeDirty(h) orelse return error.NotDirty;
    try std.testing.expectEqual(@as(u32, 2), f.w);
    try std.testing.expectEqualSlices(u32, &px, f.buf[0..4]);
    // Dirty is one-shot.
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty(h));

    // A scene window takes no pixels: its content comes from the recorder.
    const s = open(2, 2, .scene, "scene");
    iw.blit(s, &px, 2, 2);
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty(s));
    iw.reset();
}

test "each window has its own key ring, fed only while focused (MOD-013)" {
    iw.reset();
    const a = open(64, 64, .pixels, "a");
    const b = open(64, 64, .pixels, "b");
    iw.pushKey(a, 'x');
    iw.pushKey(b, 'y');
    try std.testing.expectEqual(@as(?u8, 'x'), iw.popKey(a));
    try std.testing.expectEqual(@as(?u8, 'y'), iw.popKey(b));
    try std.testing.expectEqual(@as(?u8, null), iw.popKey(a));

    // Focus is per window and the desktop owns it.
    try std.testing.expect(!iw.focused(a));
    iw.setFocused(a, true);
    try std.testing.expect(iw.focused(a));
    try std.testing.expect(!iw.focused(b));
    iw.reset();
}

test "a reused slot never inherits the last window's keys (MOD-013)" {
    iw.reset();
    const a = open(8, 8, .pixels, "a");
    iw.pushKey(a, 'z'); // never drained
    iw.requestClose(a);
    _ = iw.takeClose();

    const b = open(8, 8, .pixels, "b");
    try std.testing.expectEqual(@as(?u8, null), iw.popKey(b));
    iw.reset();
}

test "a full key ring counts the loss (MOD-013)" {
    iw.reset();
    const h = open(8, 8, .pixels, "a");
    try std.testing.expectEqual(@as(u64, 0), iw.keysDropped(h));
    var i: usize = 0;
    while (i < iw.KEY_RING_CAP + 5) : (i += 1) iw.pushKey(h, 'k');
    try std.testing.expect(iw.keysDropped(h) > 0);
    iw.reset();
}

test "the pointer is sampled state, per window, cleared when it leaves" {
    iw.reset();
    const h = open(64, 64, .pixels, "a");
    try std.testing.expectEqual(@as(?iw.Pointer, null), iw.pointer(h));
    iw.pushPointer(h, 10, 20, 0b001);
    const p = iw.pointer(h) orelse return error.NoSample;
    try std.testing.expectEqual(@as(i32, 10), p.x);
    try std.testing.expectEqual(@as(u8, 1), p.buttons);
    // Newest sample wins: a position is not a queue.
    iw.pushPointer(h, 11, 21, 0);
    try std.testing.expectEqual(@as(i32, 11), iw.pointer(h).?.x);
    iw.clearPointer(h);
    try std.testing.expectEqual(@as(?iw.Pointer, null), iw.pointer(h));
    iw.reset();
}

test "size follows the desktop's resize, and retitle takes" {
    iw.reset();
    const h = open(100, 80, .pixels, "a");
    var w: u32 = 0;
    var hgt: u32 = 0;
    try std.testing.expect(iw.size(h, &w, &hgt));
    try std.testing.expectEqual(@as(u32, 100), w);
    try std.testing.expectEqual(@as(u32, 80), hgt);
    iw.setSize(h, 200, 150);
    try std.testing.expect(iw.size(h, &w, &hgt));
    try std.testing.expectEqual(@as(u32, 200), w);
    try std.testing.expectEqual(@as(u32, 150), hgt);
    try std.testing.expect(iw.retitle(h, "renamed"));
    iw.reset();
    // Everything refuses a dead handle rather than answering for slot 0.
    try std.testing.expect(!iw.size(h, &w, &hgt));
    try std.testing.expect(!iw.retitle(h, "no"));
    try std.testing.expect(iw.indexOf(h) == null);
}
