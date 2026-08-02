//! Host tests of src/ui/wm/chrome.zig.

const std = @import("std");
const chrome = @import("chrome");
const TITLE_H = chrome.TITLE_H;
const TL_Y = chrome.TL_Y;
const buttonAt = chrome.buttonAt;
const buttonX = chrome.buttonX;
const expect = std.testing.expect;
const onTitleBar = chrome.onTitleBar;

// DSK-004/DSK-005: window chrome carries a title bar and its three controls;
// DSK-006: their order is close, minimise, zoom from the bar's left.
test "each traffic light is hit at its own centre, in macOS order" {
    try expect(buttonAt(buttonX(.close), TL_Y).? == .close);
    try expect(buttonAt(buttonX(.minimise), TL_Y).? == .minimise);
    try expect(buttonAt(buttonX(.zoom), TL_Y).? == .zoom);
    // Left to right, evenly pitched — close is leftmost, zoom rightmost.
    try expect(buttonX(.close) < buttonX(.minimise));
    try expect(buttonX(.minimise) < buttonX(.zoom));
}

test "the gaps between and beyond the lights are not buttons" {
    // Midway between two lights is outside both click radii (pitch 20 > 2·hit-r 9 leaves a gap).
    const mid = (buttonX(.close) + buttonX(.minimise)) * 0.5;
    try expect(buttonAt(mid, TL_Y) == null);
    // The empty right end of the title bar hits nothing.
    try expect(buttonAt(400, TL_Y) == null);
    // Below the title bar, even in a button's column, is not that button.
    try expect(buttonAt(buttonX(.close), TITLE_H + 10) == null);
}

test "onTitleBar is the drag strip minus the buttons and minus the body" {
    // The clear right end of the bar is a drag handle.
    try expect(onTitleBar(400, TL_Y));
    // A traffic light is NOT a drag handle — buttonAt claims it first.
    try expect(!onTitleBar(buttonX(.close), TL_Y));
    // Below the title bar is the body, not the handle.
    try expect(!onTitleBar(400, TITLE_H + 1));
    // Off the left edge is nothing.
    try expect(!onTitleBar(-1, TL_Y));
}
