//! Host tests of src/console/editline.zig — scripted editor sessions over a
//! fake screen and a fake directory tree. The script helper plays the HOST's
//! half of the editor contract (serving .complete with an injected
//! enumeration), so a keystroke that stops reaching completion — the SMP
//! session editor once dropped Tab in its printable filter — fails here.

const std = @import("std");
const editline = @import("editline");
const keymap = @import("keymap");

/// The screen the editor drives, modeled as one row of text with a cursor:
/// echo writes at the cursor and advances (extending the text at its end),
/// erase blanks the cell left of it (dropping it at the end), move slides it —
/// after any script `text()` IS what the user would see on the edit line.
const FakeScreen = struct {
    buf: [2 * editline.LINE_MAX]u8 = undefined,
    len: usize = 0,
    cur: usize = 0,

    fn echo(ctx: ?*anyopaque, ch: u8) void {
        const s: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        s.buf[s.cur] = ch;
        s.cur += 1;
        if (s.cur > s.len) s.len = s.cur;
    }
    fn erase(ctx: ?*anyopaque) void {
        const s: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        s.cur -= 1;
        if (s.cur + 1 == s.len) s.len -= 1 else s.buf[s.cur] = ' ';
    }
    fn move(ctx: ?*anyopaque, delta: i32) void {
        const s: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        s.cur = @intCast(@as(i32, @intCast(s.cur)) + delta);
    }
    fn screen(self: *FakeScreen) editline.Screen {
        return .{ .ctx = self, .echoFn = echo, .eraseFn = erase, .moveFn = move };
    }
    /// The visible text. A mid-line delete leaves a blanked cell past the end
    /// of the line, exactly as the grid does — trimmed here because the grid
    /// shows a blank cell as nothing.
    fn text(self: *const FakeScreen) []const u8 {
        return std.mem.trimEnd(u8, self.buf[0..self.len], " ");
    }
};

/// The injected directory enumeration completion runs against.
fn fakeList(_: ?*anyopaque, abs: []const u8, cb: editline.complete.ifilesys.ListFn, ctx: ?*anyopaque) editline.complete.ifilesys.Error!void {
    if (std.mem.eql(u8, abs, "/ramdisk")) {
        cb(ctx, .{ .name = "cat.txt", .kind = .file, .size = 1 });
        cb(ctx, .{ .name = "docs", .kind = .dir, .size = 0 });
        return;
    }
    return editline.complete.ifilesys.Error.NotFound;
}
const FAKE_DIRS = editline.complete.Dirs{ .ctx = null, .listFn = fakeList };

/// The command words a first-word completion may offer here — the terminal
/// passes the shell's own tables; a suite passes what it wants to assert.
const FAKE_CMDS = [_][]const u8{ "show", "shutdown", "cat" };

/// The group word a second word may complete under — empty here: the grammar
/// is complete_test's subject, and this suite only routes the keystroke.
const FAKE_GROUP = editline.complete.Group{ .word = "kudos", .names = &.{} };

/// Feed `keys` one at a time and serve the editor's host actions the way both
/// terminal editors do: .complete runs completion against the fake tree and
/// /ramdisk as the cwd; .commit clears the line (as the host does after
/// running it). Returns the LAST action, so a script can end on the key under
/// test and assert what the editor asked for.
fn play(ed: *editline.Editor, scr: *FakeScreen, keys: []const u8) editline.Action {
    var last: editline.Action = .none;
    for (keys) |k| {
        last = ed.key(k, scr.screen());
        switch (last) {
            .complete => _ = ed.completeLine("/ramdisk", FAKE_DIRS, &FAKE_CMDS, FAKE_GROUP, scr.screen()),
            .commit => ed.clearLine(),
            else => {},
        }
    }
    return last;
}

test "Tab completes the last token and echoes exactly the appended bytes" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    // The regression this file exists for: Tab (ASCII 0x09) must reach
    // completion, not die in the printable filter as any other control byte.
    try std.testing.expectEqual(editline.Action.complete, play(&ed, &scr, "show ca\t"));
    try std.testing.expectEqualStrings("show cat.txt", ed.text());
    // Everything on screen arrived by echo — typed bytes, then the completion.
    try std.testing.expectEqualStrings("show cat.txt", scr.text());
}

test "a unique directory match completes with a trailing '/'" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "cd d\t");
    try std.testing.expectEqualStrings("cd docs/", ed.text());
    try std.testing.expectEqualStrings("cd docs/", scr.text());
}

test "printable keys append and echo; backspace erases both" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "ab");
    try std.testing.expectEqual(editline.Action.none, ed.key(keymap.KEY_BACKSPACE, scr.screen()));
    try std.testing.expectEqualStrings("a", ed.text());
    try std.testing.expectEqualStrings("a", scr.text());
    // A control byte that means nothing edits nothing.
    _ = ed.key(0x07, scr.screen());
    try std.testing.expectEqualStrings("a", ed.text());
}

// APP-006: command history — Enter remembers, Up recalls, over a partial edit.
test "Enter commits and remembers the line; Up recalls it over a partial edit" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    try std.testing.expectEqual(editline.Action.commit, play(&ed, &scr, "show cat.txt\r"));
    try std.testing.expectEqual(editline.Action.none, play(&ed, &scr, "xy"));
    try std.testing.expectEqual(editline.Action.recalled, ed.key(keymap.KEY_UP, scr.screen()));
    // The recall erased the partial "xy" and reloaded the committed line.
    try std.testing.expectEqualStrings("show cat.txt", ed.text());
    try std.testing.expectEqualStrings("show cat.txtshow cat.txt", scr.text());
}

test "Up with nothing committed reports recall_empty and edits nothing" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "ab");
    try std.testing.expectEqual(editline.Action.recall_empty, ed.key(keymap.KEY_UP, scr.screen()));
    try std.testing.expectEqualStrings("ab", ed.text());
}

test "forgetRecall drops the committed line: a masked passphrase cannot be replayed" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    try std.testing.expectEqual(editline.Action.commit, play(&ed, &scr, "hunter2\r"));
    ed.forgetRecall();
    try std.testing.expectEqual(editline.Action.recall_empty, ed.key(keymap.KEY_UP, scr.screen()));
    try std.testing.expectEqualStrings("", ed.text());
}

// APP-006: the history RING — Up walks older through every retained commit,
// Down walks newer and past the newest restores the in-progress line.
test "Up walks the ring oldest-ward and parks at the oldest entry" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "one\rtwo\rthree\r");
    try std.testing.expectEqual(editline.Action.recalled, ed.key(keymap.KEY_UP, scr.screen()));
    try std.testing.expectEqualStrings("three", ed.text());
    try std.testing.expectEqual(editline.Action.recalled, ed.key(keymap.KEY_UP, scr.screen()));
    try std.testing.expectEqualStrings("two", ed.text());
    try std.testing.expectEqual(editline.Action.recalled, ed.key(keymap.KEY_UP, scr.screen()));
    try std.testing.expectEqualStrings("one", ed.text());
    // At the oldest entry Up edits nothing — and says so, countably.
    try std.testing.expectEqual(editline.Action.recall_empty, ed.key(keymap.KEY_UP, scr.screen()));
    try std.testing.expectEqualStrings("one", ed.text());
    // The edit line (the screen's tail — commits leave their echo behind,
    // as the recall-over-a-partial-edit test above documents) shows "one".
    try std.testing.expect(std.mem.endsWith(u8, scr.text(), "threeone"));
}

test "Down past the newest entry restores the stashed in-progress line" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "one\rtwo\r");
    _ = play(&ed, &scr, "par"); // the partial line, stashed on the first Up
    _ = ed.key(keymap.KEY_UP, scr.screen()); // "two"
    _ = ed.key(keymap.KEY_UP, scr.screen()); // "one"
    _ = ed.key(keymap.KEY_DOWN, scr.screen()); // back to "two"
    try std.testing.expectEqualStrings("two", ed.text());
    try std.testing.expectEqual(editline.Action.recalled, ed.key(keymap.KEY_DOWN, scr.screen()));
    try std.testing.expectEqualStrings("par", ed.text());
    try std.testing.expect(std.mem.endsWith(u8, scr.text(), "twopar"));
    // Not walking: Down has nothing newer to go to.
    try std.testing.expectEqual(editline.Action.recall_empty, ed.key(keymap.KEY_DOWN, scr.screen()));
}

test "the ring skips consecutive duplicates and empty commits" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "ls\rls\r\r  \r");
    try std.testing.expectEqualStrings("ls", ed.historyAt(0).?);
    try std.testing.expectEqual(@as(?[]const u8, null), ed.historyAt(1));
}

test "forgetRecall drops the NEWEST entry only — older commands stay recallable" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "keep\rhunter2\r");
    ed.forgetRecall(); // the passphrase scrub (setInputMask off)
    try std.testing.expectEqual(editline.Action.recalled, ed.key(keymap.KEY_UP, scr.screen()));
    try std.testing.expectEqualStrings("keep", ed.text());
    try std.testing.expectEqual(@as(?[]const u8, null), ed.historyAt(1));
}

test "a duplicate commit does not arm forgetRecall against an older command" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    // The masked line repeated the previous command, so nothing was stored —
    // the scrub must not eat "keep".
    _ = play(&ed, &scr, "keep\rkeep\r");
    ed.forgetRecall();
    try std.testing.expectEqualStrings("keep", ed.historyAt(0).?);
}

test "the ring holds HISTORY entries: the oldest is evicted, the walk still ends" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    var buf: [8]u8 = undefined;
    for (0..editline.HISTORY + 1) |i| {
        const line = std.fmt.bufPrint(&buf, "c{d}\r", .{i}) catch unreachable;
        _ = play(&ed, &scr, line);
    }
    for (0..editline.HISTORY) |_| _ = ed.key(keymap.KEY_UP, scr.screen());
    try std.testing.expectEqualStrings("c1", ed.text()); // c0 evicted
    try std.testing.expectEqual(editline.Action.recall_empty, ed.key(keymap.KEY_UP, scr.screen()));
}

// The in-line cursor: Left/Right/Home/End move it; insert and delete happen
// at it and the screen ends up showing exactly the buffer.
test "mid-line insert: the tail shifts right and repaints" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "abc");
    _ = ed.key(keymap.KEY_LEFT, scr.screen());
    _ = ed.key(keymap.KEY_LEFT, scr.screen());
    _ = ed.key('X', scr.screen());
    try std.testing.expectEqualStrings("aXbc", ed.text());
    try std.testing.expectEqualStrings("aXbc", scr.text());
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "mid-line backspace: the tail shifts left and the stale last cell blanks" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "abc");
    _ = ed.key(keymap.KEY_LEFT, scr.screen());
    _ = ed.key(keymap.KEY_BACKSPACE, scr.screen()); // deletes 'b'
    try std.testing.expectEqualStrings("ac", ed.text());
    try std.testing.expectEqualStrings("ac", scr.text());
    try std.testing.expectEqual(@as(usize, 1), ed.cursor);
    // At the start of the line there is nothing left of the cursor to delete.
    _ = ed.key(keymap.KEY_LEFT, scr.screen());
    _ = ed.key(keymap.KEY_BACKSPACE, scr.screen());
    try std.testing.expectEqualStrings("ac", ed.text());
}

test "Home and End jump the cursor across the whole line" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "abc");
    _ = ed.key(keymap.KEY_HOME, scr.screen());
    _ = ed.key('X', scr.screen());
    try std.testing.expectEqualStrings("Xabc", ed.text());
    _ = ed.key(keymap.KEY_END, scr.screen());
    _ = ed.key('Y', scr.screen());
    try std.testing.expectEqualStrings("XabcY", ed.text());
    try std.testing.expectEqualStrings("XabcY", scr.text());
}

test "Ctrl-C abandons the line and asks the host to acknowledge" {
    var ed = editline.Editor{};
    var scr = FakeScreen{};
    _ = play(&ed, &scr, "rm -rf");
    try std.testing.expectEqual(editline.Action.interrupt, ed.key(keymap.KEY_CTRL_C, scr.screen()));
    try std.testing.expectEqualStrings("", ed.text());
    // The abandoned text stays on screen (the host prints ^C after it).
    try std.testing.expectEqualStrings("rm -rf", scr.text());
    // The abandoned line was never committed, so Up has nothing to recall.
    try std.testing.expectEqual(editline.Action.recall_empty, ed.key(keymap.KEY_UP, scr.screen()));
}
