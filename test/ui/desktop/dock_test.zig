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
const iconAt = dock.iconAt;
const iconRect = dock.iconRect;
const lighten = dock.lighten;
const slabRect = dock.slabRect;

// DSK-016: a dock of application tiles sits along the bottom of the desktop.
test "the slab is centred along the bottom, sized to its tiles" {
    const s = slabRect(1000, 800, 4);
    // 4 tiles: 4*48 + 3*14 + 2*12 = 192 + 42 + 24 = 258 wide.
    try expect(approx(s.w, 258));
    try expect(approx(s.x, (1000 - 258) * 0.5));
    try expect(approx(s.y, 800 - DOCK_H - MARGIN));
}

test "tiles tile left-to-right inside the padding" {
    const s = slabRect(1000, 800, 3);
    const r0 = iconRect(s, 0);
    const r1 = iconRect(s, 1);
    try expect(approx(r0.x, s.x + PAD));
    try expect(approx(r1.x, s.x + PAD + ICON + GAP));
    try expect(approx(r0.w, ICON));
}

test "iconAt finds the tile under a point, and misses the gaps and the void" {
    const w = 1000.0;
    const h = 800.0;
    const s = slabRect(w, h, 3);
    const r1 = iconRect(s, 1);
    try expect(iconAt(w, h, 3, r1.x + ICON * 0.5, r1.y + ICON * 0.5).? == 1);
    try expect(iconAt(w, h, 3, r1.x, s.y - 20) == null);
    try expect(iconAt(w, h, 3, s.x + PAD + ICON + GAP * 0.5, r1.y + 2) == null);
}

test "lighten moves a colour toward white but keeps alpha" {
    try expect(lighten(0xFF000000, 0.0) == 0xFF000000);
    try expect(lighten(0xFF000000, 1.0) == 0xFFFFFFFF);
    // Half-way from mid-grey is brighter grey, alpha untouched.
    const half = lighten(0xFF808080, 0.5);
    try expect((half >> 24) == 0xFF);
    try expect((half & 0xFF) > 0x80);
}
