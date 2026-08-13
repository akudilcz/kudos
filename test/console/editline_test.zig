//! Host tests of src/console/editline.zig — scripted editor sessions over a
//! fake screen and a fake directory tree. The script helper plays the HOST's
//! half of the editor contract (serving .complete with an injected
//! enumeration), so a keystroke that stops reaching completion — the SMP
//! session editor once dropped Tab in its printable filter — fails here.

const std = @import("std");
const editline = @import("editline");
const keymap = @import("keymap");

/// The screen the editor drives, modeled as text: echo appends a byte, erase
/// drops the last one — after any script this IS what the user would see on
/// the edit line.
const FakeScreen = struct {
    buf: [2 * editline.LINE_MAX]u8 = undefined,
    len: usize = 0,

    fn echo(ctx: ?*anyopaque, ch: u8) void {
        const s: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        s.buf[s.len] = ch;
        s.len += 1;
    }
    fn erase(ctx: ?*anyopaque) void {
        const s: *FakeScreen = @ptrCast(@alignCast(ctx.?));
        s.len -= 1;
    }
    fn screen(self: *FakeScreen) editline.Screen {
        return .{ .ctx = self, .echoFn = echo, .eraseFn = erase };
    }
    fn text(self: *const FakeScreen) []const u8 {
        return self.buf[0..self.len];
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
            .commit => ed.len = 0,
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
    ed.len = 0;
    ed.forgetRecall();
    try std.testing.expectEqual(editline.Action.recall_empty, ed.key(keymap.KEY_UP, scr.screen()));
    try std.testing.expectEqualStrings("", ed.text());
}
