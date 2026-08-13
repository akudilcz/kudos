//! Host tests of src/ui/desktop/dock.zig.

const std = @import("std");
const dock = @import("dock");
const DOCK_H = dock.DOCK_H;
const GAP = dock.GAP;
const ICON = dock.ICON;
const MARGIN = dock.MARGIN;
const PAD = dock.PAD;
fn approx(a: f32, b: f32) bool {
    return @abs(a - b) <= 0.001;
}
const expect = std.testing.expect;
const hitAt = dock.hitAt;
const iconRect = dock.iconRect;
const lighten = dock.lighten;
const slabRect = dock.slabRect;
const sepRect = dock.sepRect;
const winRect = dock.winRect;

// DSK-016: a dock of application tiles sits along the bottom of the desktop.
test "the slab is centred along the bottom, sized to its tiles" {
    const s = slabRect(1000, 800, 4, 0);
    // 4 tiles: 4*48 + 3*14 + 2*12 = 192 + 42 + 24 = 258 wide.
    try expect(approx(s.w, 258));
    try expect(approx(s.x, (1000 - 258) * 0.5));
    try expect(approx(s.y, 800 - DOCK_H - MARGIN));
}

test "tiles tile left-to-right inside the padding" {
    const s = slabRect(1000, 800, 3, 0);
    const r0 = iconRect(s, 0);
    const r1 = iconRect(s, 1);
    try expect(approx(r0.x, s.x + PAD));
    try expect(approx(r1.x, s.x + PAD + ICON + GAP));
    try expect(approx(r0.w, ICON));
}

test "hitAt finds the launcher under a point, and misses the gaps and the void" {
    const w = 1000.0;
    const h = 800.0;
    const s = slabRect(w, h, 3, 0);
    const r1 = iconRect(s, 1);
    try expect(hitAt(w, h, 3, 0, r1.x + ICON * 0.5, r1.y + ICON * 0.5).?.launcher == 1);
    try expect(hitAt(w, h, 3, 0, r1.x, s.y - 20) == null);
    try expect(hitAt(w, h, 3, 0, s.x + PAD + ICON + GAP * 0.5, r1.y + 2) == null);
}

// DSK-021: one slot per open window, in its own zone past the separator.
test "the window zone widens the slab and sits past the separator (DSK-021)" {
    const s0 = slabRect(1000, 800, 3, 0);
    const s2 = slabRect(1000, 800, 3, 2);
    // 2 slots add: SEP_GAP + SEP_W + SEP_GAP + 2*ICON + GAP.
    try expect(approx(s2.w - s0.w, dock.SEP_GAP * 2 + dock.SEP_W + 2 * ICON + GAP));
    const sep = sepRect(s2, 3);
    const w0 = winRect(s2, 3, 0);
    try expect(sep.x > iconRect(s2, 2).x + ICON);
    try expect(w0.x > sep.x + dock.SEP_W);
}

test "hitAt maps window slots to their own zone, never a launcher index (DSK-021)" {
    const w = 1000.0;
    const h = 800.0;
    const s = slabRect(w, h, 3, 2);
    const w1 = winRect(s, 3, 1);
    const hit = hitAt(w, h, 3, 2, w1.x + ICON * 0.5, w1.y + ICON * 0.5).?;
    try expect(hit == .window);
    try expect(hit.window == 1);
    // The separator itself hits nothing.
    const sep = sepRect(s, 3);
    try expect(hitAt(w, h, 3, 2, sep.x + dock.SEP_W * 0.5, sep.y + 2) == null);
}

test "lighten moves a colour toward white but keeps alpha" {
    try expect(lighten(0xFF000000, 0.0) == 0xFF000000);
    try expect(lighten(0xFF000000, 1.0) == 0xFFFFFFFF);
    // Half-way from mid-grey is brighter grey, alpha untouched.
    const half = lighten(0xFF808080, 0.5);
    try expect((half >> 24) == 0xFF);
    try expect((half & 0xFF) > 0x80);
}
