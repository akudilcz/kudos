//! Host tests of src/iface/idesk.zig — the desktop-control seam: one window
//! request at a time, and readback that is always the desktop's last word.

const std = @import("std");
const idesk = @import("idesk");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "a window request survives to the desktop, name and all (AGT-023)" {
    idesk.reset();
    defer idesk.reset();

    try expect(idesk.takeAction() == null); // nothing parked, nothing taken
    try expect(idesk.postAction(.maximise, "AI Agent"));

    const req = idesk.takeAction() orelse return error.RequestLost;
    try expect(req.action == .maximise);
    try expectEqualStrings("AI Agent", req.name);
    // Taking it consumes it: a request applied twice would maximise a window and
    // then put it straight back.
    try expect(idesk.takeAction() == null);
}

test "a second request is REFUSED while one is unapplied (AGT-023)" {
    idesk.reset();
    defer idesk.reset();

    try expect(idesk.postAction(.close, "term #1"));
    // Silently overwriting would lose an instruction the caller was told had
    // been taken — the caller must learn that the desktop has not caught up.
    try expect(!idesk.postAction(.focus, "term #2"));

    const req = idesk.takeAction() orelse return error.RequestLost;
    try expect(req.action == .close);
    try expectEqualStrings("term #1", req.name);
    // Applied: the seam takes the next one.
    try expect(idesk.postAction(.focus, "term #2"));
}

test "an over-long window name is truncated, never overruns the buffer (AGT-023)" {
    idesk.reset();
    defer idesk.reset();

    const long = "x" ** (idesk.MAX_NAME * 3);
    try expect(idesk.postAction(.focus, long));
    const req = idesk.takeAction() orelse return error.RequestLost;
    try std.testing.expectEqual(idesk.MAX_NAME, req.name.len);
}

test "the pointer's place-and-press is the mouse's own event path (AGT-026)" {
    // The seam carries no pointer state on purpose: a click is not a desktop
    // REQUEST, it is a mouse event, and it goes through imouse — the single
    // producer path a real mouse, a USB tablet and the remote injector all use.
    // Anything else would be a second pointer the compositor has to reconcile.
    // This test states that contract; imouse_test owns the event algebra.
    try expect(!@hasDecl(idesk, "postPointer"));
    try expect(!@hasDecl(idesk, "pointer"));
}

test "an empty name means the focused window (AGT-023)" {
    idesk.reset();
    defer idesk.reset();

    // "maximise it" with nothing named is a real instruction, not a malformed
    // one: it means the window the user is looking at.
    try expect(idesk.postAction(.minimise, ""));
    const req = idesk.takeAction() orelse return error.RequestLost;
    try expect(req.name.len == 0);
    try expect(req.action == .minimise);
}

test "readback is the desktop's last word, bounded and repeatable (AGT-024, AGT-025)" {
    idesk.reset();
    defer idesk.reset();

    // Before the desktop has drawn there is nothing to report, and saying so is
    // a true answer about a machine with no desktop.
    try expect(idesk.windows().len == 0);
    try expect(idesk.dashboard().len == 0);

    idesk.publishWindows("*term #0  800x600 at 10,20\n");
    idesk.publishDashboard("cores 4 busy 12%\n");
    try expectEqualStrings("*term #0  800x600 at 10,20\n", idesk.windows());
    try expectEqualStrings("cores 4 busy 12%\n", idesk.dashboard());
    // Reading does not consume: two tools asking the same question in one turn
    // must get the same answer.
    try expectEqualStrings("cores 4 busy 12%\n", idesk.dashboard());

    // A later publish REPLACES rather than appends — the list is a snapshot of
    // now, and a reader must never see two samples spliced together.
    idesk.publishWindows("*calc  400x300 at 0,0\n");
    try expectEqualStrings("*calc  400x300 at 0,0\n", idesk.windows());

    // Longer than the buffer: truncated to it, because a partial list is still
    // an answer and a bounded buffer is what makes this seam a leaf.
    const huge = "y" ** (idesk.MAX_WINDOWS_TEXT * 2);
    idesk.publishWindows(huge);
    try std.testing.expectEqual(idesk.MAX_WINDOWS_TEXT, idesk.windows().len);
}
