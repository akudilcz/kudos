//! Host tests of src/iface/iwindow.zig — the blob-window cross-core mailbox.
//! Drives the producer/consumer handshake single-threaded (the release/acquire
//! ordering is a no-op without contention, but every state transition is exercised).

const std = @import("std");
const abi = @import("abi");
const iw = @import("iwindow");

test "open handshake: request -> fulfil -> handle published" {
    iw.reset();
    try std.testing.expectEqual(@as(u32, 0), iw.handle());
    try std.testing.expectEqual(@as(?iw.OpenReq, null), iw.takeOpenRequest());

    iw.requestOpen(320, 240);
    const req = iw.takeOpenRequest() orelse return error.NoRequest;
    try std.testing.expectEqual(@as(u32, 320), req.w);
    try std.testing.expectEqual(@as(u32, 240), req.h);
    // The consumer allocates the buffer and publishes the handle.
    var buf: [320 * 240]u32 = undefined;
    iw.provide(7, &buf, 320, 240);
    try std.testing.expectEqual(@as(u32, 7), iw.handle());
    iw.reset();
}

test "requestOpen clamps to the draw ceiling and rejects zero" {
    iw.reset();
    iw.requestOpen(abi.DRAW_MAX_W + 1000, abi.DRAW_MAX_H + 1000);
    const req = iw.takeOpenRequest().?;
    try std.testing.expectEqual(abi.DRAW_MAX_W, req.w);
    try std.testing.expectEqual(abi.DRAW_MAX_H, req.h);
    iw.reset();
    iw.requestOpen(0, 0);
    const r2 = iw.takeOpenRequest().?;
    try std.testing.expectEqual(@as(u32, 1), r2.w); // zero -> 1, never a 0-size window
    try std.testing.expectEqual(@as(u32, 1), r2.h);
    iw.reset();
}

test "one window at a time: a second open is refused while one is live" {
    iw.reset();
    iw.requestOpen(64, 64);
    _ = iw.takeOpenRequest();
    var buf: [64 * 64]u32 = undefined;
    iw.provide(1, &buf, 64, 64);
    // A second request while live is ignored — no pending request appears.
    iw.requestOpen(64, 64);
    try std.testing.expectEqual(@as(?iw.OpenReq, null), iw.takeOpenRequest());
    iw.reset();
}

test "blit copies pixels for the live handle and marks dirty; wrong handle/oversize no-op" {
    iw.reset();
    iw.requestOpen(2, 2);
    _ = iw.takeOpenRequest();
    var buf = [_]u32{0} ** 4;
    iw.provide(9, &buf, 2, 2);
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty()); // clean at first

    const px = [_]u32{ 0x11, 0x22, 0x33, 0x44 };
    iw.blit(999, &px, 2, 2); // wrong handle -> ignored
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty());
    iw.blit(9, &px, 4, 4); // oversize -> ignored
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty());

    iw.blit(9, &px, 2, 2); // valid -> copied + dirty
    const f = iw.takeDirty() orelse return error.NotDirty;
    try std.testing.expectEqual(@as(u32, 2), f.w);
    try std.testing.expectEqualSlices(u32, &px, buf[0..4]);
    // Dirty is one-shot: a second take with no new blit is clean.
    try std.testing.expectEqual(@as(?iw.Frame, null), iw.takeDirty());
    iw.reset();
}

test "close resets the mailbox so a new window can open" {
    iw.reset();
    iw.requestOpen(8, 8);
    _ = iw.takeOpenRequest();
    var buf: [64]u32 = undefined;
    iw.provide(3, &buf, 8, 8);
    iw.requestClose();
    try std.testing.expect(iw.takeClose());
    try std.testing.expectEqual(@as(u32, 0), iw.handle()); // window gone
    try std.testing.expect(!iw.takeClose()); // one-shot
    // A fresh window opens after close.
    iw.requestOpen(16, 16);
    try std.testing.expect(iw.takeOpenRequest() != null);
    iw.reset();
}
