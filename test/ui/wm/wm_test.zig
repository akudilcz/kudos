//! Host tests of src/ui/wm/wm.zig (reached through the ui_wm module-root shim).

const std = @import("std");
const wm = @import("ui_wm").wm;
const chrome = @import("ui_wm").chrome;
const MAX_DIRTY = wm.MAX_DIRTY;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// A WM over a fixed 800x600 test screen with a deterministic seed.
fn testWm(a: std.mem.Allocator) wm.Wm {
    return wm.Wm.init(a, 800, 600, 0);
}

fn freeAll(w: *wm.Wm) void {
    for (w.windows.items) |win| w.a.destroy(win);
    w.windows.deinit();
}

test "addWindow stacks on top and takes focus" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 200, 150, "one");
    const a2 = try w.addWindow(50, 50, 200, 150, "two");
    try expect(w.focused == a2);
    try expect(w.topmost() == a2);
    try expect(a2.focused and !a1.focused);
}

// DSK-015: clicking a window focuses AND raises it.
test "a body click focuses and raises the window under the cursor" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 200, 150, "one");
    _ = try w.addWindow(300, 300, 200, 150, "two");
    // Press + release in a1's body (below its title bar).
    _ = w.onMouse(100, 100, 1);
    _ = w.onMouse(100, 100, 0);
    try expect(w.focused == a1);
    try expect(w.topmost() == a1);
}

test "a close-box click records a pending close, not a focus change" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 200, 150, "one");
    const a2 = try w.addWindow(300, 300, 200, 150, "two");
    // Fresh press exactly on a1's close button (chrome geometry, window-local).
    _ = w.onMouse(10 + @as(i32, @intFromFloat(chrome.buttonX(.close))), 10 + @as(i32, @intFromFloat(chrome.TL_Y)), 1);
    switch (w.pending.?) {
        .close => |win| try expect(win == a1),
        else => return error.TestUnexpectedResult,
    }
    try expect(w.focused == a2); // the click consumed — no focus move
}

// DSK-011: windows are moved by dragging their title bar (the live closed-loop
// half is boot-1's injected drag).
test "a title drag moves the window and marks old + new damage" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 200, 150, "one");
    _ = w.takeSceneDamage(); // clear the initial full
    _ = w.onMouse(100, 15, 1); // press in the title bar
    _ = w.onMouse(140, 55, 1); // drag
    try expectEqual(@as(i32, 50), a1.x);
    try expectEqual(@as(i32, 50), a1.y);
    const dm = w.takeSceneDamage().?;
    // The damage box covers the union of the old and new footprints.
    try expect(!dm.full);
    try expect(dm.x <= 10 and dm.y <= 10);
    try expect(dm.x + @as(i32, @intCast(dm.w)) >= 50 + 200);
    try expect(dm.y + @as(i32, @intCast(dm.h)) >= 50 + 150);
}

test "takeSceneDamage: null when clean, box when dirty, clears on read" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    try expect(w.takeSceneDamage().?.full); // first frame: everything
    try expect(w.takeSceneDamage() == null); // clean: skip the frame
    w.markRect(20, 30, 40, 50);
    const dm = w.takeSceneDamage().?;
    try expect(!dm.full);
    try expectEqual(@as(i32, 20), dm.x);
    try expectEqual(@as(u32, 40), dm.w);
    try expect(w.takeSceneDamage() == null); // report-and-clear
}

test "overlapping damage coalesces; overflow falls back to full" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    _ = w.takeSceneDamage();
    // Overlapping marks collapse into one rect, not MAX_DIRTY slots.
    var i: i32 = 0;
    while (i < 100) : (i += 1) w.markRect(10 + i, 10, 50, 50);
    try expect(w.ndirty == 1);
    // Distant tiny rects refuse to unite; enough of them overflow to full.
    i = 0;
    while (i < MAX_DIRTY + 1) : (i += 1) w.markRect(@rem(i, 8) * 100, @divTrunc(i, 8) * 140, 2, 2);
    try expect(w.full);
}

// DSK-014: minimise really hides — including from hit-testing, so a click in
// the hidden window's old rect falls through to the window behind.
test "minimise hides the window from hit-testing and hands focus down" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const back = try w.addWindow(300, 300, 200, 150, "back");
    const front = try w.addWindow(10, 10, 200, 150, "front");
    try expect(w.focused == front);

    w.minimise(front);
    // Focus fell to the remaining visible window.
    try expect(w.focused == back);
    try expect(front.minimized and !front.focused);
    // A click inside the HIDDEN window's rect (nothing else is there) must
    // fall through to the desktop — a minimised window is pointer-transparent.
    _ = w.onMouse(100, 100, 1);
    _ = w.onMouse(100, 100, 0);
    try expect(w.focused == back);
}

test "unminimise restores visibility, focus, and the stacking top" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 200, 150, "one");
    _ = try w.addWindow(300, 300, 200, 150, "two");
    w.minimise(a1);
    w.unminimise(a1);
    try expect(!a1.minimized);
    try expect(w.focused == a1);
    // And it hit-tests again.
    _ = w.onMouse(100, 100, 1);
    _ = w.onMouse(100, 100, 0);
    try expect(w.focused == a1);
}

test "every traffic light hit-tests at its own centre: close, minimise, zoom" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 200, 150, "one");
    inline for (.{ chrome.Button.close, chrome.Button.minimise, chrome.Button.zoom }) |b| {
        const px: i32 = 10 + @as(i32, @intFromFloat(chrome.buttonX(b)));
        const py: i32 = 10 + @as(i32, @intFromFloat(chrome.TL_Y));
        try expectEqual(b == .minimise, a1.minHit(px, py));
        try expectEqual(b == .zoom, a1.maxHit(px, py));
    }
}

test "a too-small window request clamps up to the minimum, loudly" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 1, 1, "tiny");
    try expect(a1.w >= 1 and a1.h >= 1);
    try expect(a1.contentW() > 0 and a1.contentH() > 0); // no unsigned wrap
}

test "traffic-light presses record minimise and maximise pendings" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 200, 150, "one");
    _ = w.onMouse(10 + @as(i32, @intFromFloat(chrome.buttonX(.minimise))), 10 + @as(i32, @intFromFloat(chrome.TL_Y)), 1);
    switch (w.pending.?) {
        .minimise => |win| try expect(win == a1),
        else => return error.WrongPending,
    }
    w.pending = null;
    _ = w.onMouse(10, 10, 0);
    _ = w.onMouse(10 + @as(i32, @intFromFloat(chrome.buttonX(.zoom))), 10 + @as(i32, @intFromFloat(chrome.TL_Y)), 1);
    switch (w.pending.?) {
        .maximise => |win| try expect(win == a1),
        else => return error.WrongPending,
    }
}

test "a grip drag records a clamped resize request; separate drags coalesce damage" {
    var w = testWm(std.testing.allocator);
    defer freeAll(&w);
    const a1 = try w.addWindow(10, 10, 200, 150, "one");
    // Press on the grip corner, drag outward, and the request grows the window.
    _ = w.onMouse(10 + 200 - 2, 10 + 150 - 2, 1);
    _ = w.onMouse(10 + 200 + 40, 10 + 150 + 30, 1);
    switch (w.pending.?) {
        .resize => |r| {
            try expect(r.win == a1);
            try expect(r.w > 200 and r.h > 150);
        },
        else => return error.WrongPending,
    }
    _ = w.onMouse(10 + 200 + 40, 10 + 150 + 30, 0);
    // Two windows dragged in turn: their separate dirty boxes coalesce into one
    // scene box (never a false "clean").
    const a2 = try w.addWindow(400, 300, 120, 100, "two");
    _ = w.takeSceneDamage();
    _ = w.onMouse(10 + 150, 10 + 4, 1); // a1 title, clear of the lights
    _ = w.onMouse(10 + 170, 10 + 24, 1);
    _ = w.onMouse(10 + 170, 10 + 24, 0);
    _ = w.onMouse(400 + 90, 300 + 4, 1); // a2 title
    _ = w.onMouse(400 + 110, 300 + 24, 1);
    _ = w.onMouse(400 + 110, 300 + 24, 0);
    _ = a2;
    try expect(w.takeSceneDamage() != null);
}
