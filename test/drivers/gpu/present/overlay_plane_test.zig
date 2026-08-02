//! Host tests of src/drivers/gpu/present/overlay_plane.zig.

const std = @import("std");
const overlay_plane = @import("overlay_plane");
const Plane = overlay_plane.Plane;
const expect = std.testing.expect;
const step = overlay_plane.step;

test "idle with nothing routed: no overlay touch" {
    const a = step(.{ .showing_content = false }, false);
    try expect(!a.do_overlay and !a.blank and !a.swap and !a.next.showing_content);
}

test "arm content: co-flip + swap + now showing content" {
    const a = step(.{ .showing_content = false }, true);
    try expect(a.do_overlay and !a.blank and a.swap and a.next.showing_content);
}

test "routed→unrouted edge: ONE blank, no swap, stops showing content" {
    // The exact bug class: content was latched, route stops → must blank once.
    const a = step(.{ .showing_content = true }, false);
    try expect(a.do_overlay and a.blank and !a.swap and !a.next.showing_content);
}

test "blank is ONE-SHOT: the frame after a blank does nothing" {
    // Frame 1: unroute edge → blank, next.showing_content=false.
    const after_blank = step(.{ .showing_content = true }, false).next;
    // Frame 2: still unrouted → no re-blank.
    const a = step(after_blank, false);
    try expect(!a.do_overlay and !a.blank);
}

test "content held across frames: re-arm each frame, never blanks while routed" {
    var st = Plane{};
    // Route for three consecutive frames.
    var f: u32 = 0;
    while (f < 3) : (f += 1) {
        const a = step(st, true);
        try expect(a.do_overlay and !a.blank and a.swap);
        st = a.next;
        try expect(st.showing_content);
    }
}

test "route → stop → route(different): blank between, then content again" {
    var st = Plane{};
    const a1 = step(st, true); // content
    st = a1.next;
    const a2 = step(st, false); // unroute → blank
    try expect(a2.blank);
    st = a2.next;
    try expect(!st.showing_content);
    const a3 = step(st, true); // route a new window → content, NOT a blank
    try expect(a3.do_overlay and !a3.blank and a3.swap);
    st = a3.next;
    const a4 = step(st, false); // stop again → blank again
    try expect(a4.blank);
}

test "unroute WITHOUT prior content is a no-op (never armed → nothing to blank)" {
    const a = step(.{ .showing_content = false }, false);
    try expect(!a.do_overlay);
}
