//! Host tests of src/console/complete.zig.

const std = @import("std");
const complete = @import("complete");

/// The in-memory tree completion is exercised against, keyed by the absolute
/// directory path the core asks for — the whole fake `Dirs` seam.
const FakeTree = struct {
    fn list(_: ?*anyopaque, abs: []const u8, cb: complete.ifilesys.ListFn, ctx: ?*anyopaque) complete.ifilesys.Error!void {
        if (std.mem.eql(u8, abs, "/ramdisk")) {
            cb(ctx, .{ .name = "Bunny.glb", .kind = .file, .size = 3 });
            cb(ctx, .{ .name = "duck.glb", .kind = .file, .size = 3 });
            cb(ctx, .{ .name = "team1.txt", .kind = .file, .size = 1 });
            cb(ctx, .{ .name = "team2.txt", .kind = .file, .size = 1 });
            cb(ctx, .{ .name = "models", .kind = .dir, .size = 0 });
            return;
        }
        if (std.mem.eql(u8, abs, "/ramdisk/models")) {
            cb(ctx, .{ .name = "rabbit.glb", .kind = .file, .size = 3 });
            cb(ctx, .{ .name = "racer.glb", .kind = .file, .size = 3 });
            return;
        }
        if (std.mem.eql(u8, abs, "/usbdisk")) {
            cb(ctx, .{ .name = "photos", .kind = .dir, .size = 0 });
            return;
        }
        if (std.mem.eql(u8, abs, "/")) {
            cb(ctx, .{ .name = "ramdisk", .kind = .dir, .size = 0 });
            cb(ctx, .{ .name = "usbdisk", .kind = .dir, .size = 0 });
            return;
        }
        return complete.ifilesys.Error.NotFound;
    }
};

const DIRS = complete.Dirs{ .ctx = null, .listFn = FakeTree.list };

/// The command words the first token completes against here — the terminal
/// passes the shell's own tables (shell.NAMES ++ localcmd.NAMES).
const CMDS = [_][]const u8{ "cat", "cd", "clear", "show", "shutdown" };

/// One Tab press over the fake tree: complete `text` (cursor at end) against
/// `cwd` and return the resulting line (a view of a static scratch buffer).
fn tab(text: []const u8, cwd: []const u8) []const u8 {
    return tabResult(text, cwd).line;
}

/// The same press, keeping the core's own account of it — how many entries
/// matched and how much of what was typed got rewritten.
fn tabResult(text: []const u8, cwd: []const u8) struct { line: []const u8, r: complete.Result } {
    const S = struct {
        var buf: [96]u8 = undefined;
    };
    @memcpy(S.buf[0..text.len], text);
    const r = complete.line(&S.buf, text.len, cwd, DIRS, &CMDS);
    return .{ .line = S.buf[0..r.len], .r = r };
}

/// Every candidate a press would offer, joined — what the terminal prints
/// below the line when the word stays ambiguous.
fn candidates(text: []const u8, cwd: []const u8) []const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        fn emit(_: ?*anyopaque, name: []const u8, kind: complete.ifilesys.Kind) void {
            @memcpy(buf[len..][0..name.len], name);
            len += name.len;
            if (kind == .dir) {
                buf[len] = '/';
                len += 1;
            }
            buf[len] = ' ';
            len += 1;
        }
    };
    S.len = 0;
    complete.eachMatch(text, cwd, DIRS, &CMDS, .{ .ctx = null, .entryFn = S.emit });
    return S.buf[0..S.len];
}

/// A line typed across several Tab presses, the way a user builds a long path:
/// type a segment, press Tab, type the next. Unlike `tab` it KEEPS its buffer
/// between presses, so the presses compose.
const Line = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn typed(self: *Line, keys: []const u8) void {
        @memcpy(self.buf[self.len..][0..keys.len], keys);
        self.len += keys.len;
    }
    fn press(self: *Line) void {
        self.len = complete.line(&self.buf, self.len, "/ramdisk", DIRS, &CMDS).len;
    }
    fn text(self: *const Line) []const u8 {
        return self.buf[0..self.len];
    }
};

test "APP-022: a long path completes one segment at a time" {
    var l = Line{};
    l.typed("show /ram");
    l.press();
    try std.testing.expectEqualStrings("show /ramdisk/", l.text());
    l.typed("mod");
    l.press();
    try std.testing.expectEqualStrings("show /ramdisk/models/", l.text());
    l.typed("rab");
    l.press();
    // Nine typed characters produced a thirty-one character line.
    try std.testing.expectEqualStrings("show /ramdisk/models/rabbit.glb", l.text());
}

test "APP-023: a unique match completes the token in full" {
    try std.testing.expectEqualStrings("show Bunny.glb", tab("show Bun", "/ramdisk"));
}

test "APP-024: several matches extend to the longest common prefix" {
    try std.testing.expectEqualStrings("cat team", tab("cat te", "/ramdisk"));
    // The token already IS the common prefix: nothing to extend.
    try std.testing.expectEqualStrings("cat team", tab("cat team", "/ramdisk"));
}

test "no match leaves the line unchanged" {
    try std.testing.expectEqualStrings("show zzz", tab("show zzz", "/ramdisk"));
}

test "a unique directory match gains a trailing '/'" {
    try std.testing.expectEqualStrings("cd models/", tab("cd mod", "/ramdisk"));
}

test "a token with a directory part completes inside that directory" {
    try std.testing.expectEqualStrings("show models/rabbit.glb", tab("show models/rab", "/ramdisk"));
    // Several matches inside the directory: common prefix, no trailing '/'.
    try std.testing.expectEqualStrings("show models/ra", tab("show models/r", "/ramdisk"));
    // An absolute token resolves independently of the cwd.
    try std.testing.expectEqualStrings("show /ramdisk/duck.glb", tab("show /ramdisk/du", "/usbdisk"));
}

test "bare name missing from the cwd falls back to the fixed mounts" {
    // Not in /usbdisk; found on the first fallback root, /ramdisk.
    try std.testing.expectEqualStrings("show Bunny.glb", tab("show Bun", "/usbdisk"));
    // Not in /ramdisk (nor on /ramdisk again); found on /usbdisk.
    try std.testing.expectEqualStrings("cd photos/", tab("cd pho", "/ramdisk"));
    // A cwd match wins without ever consulting the fallback roots.
    try std.testing.expectEqualStrings("show models/", tab("show mod", "/ramdisk"));
}

test "APP-025: the first word completes against the command names" {
    // A unique command gains the space that starts its arguments.
    try std.testing.expectEqualStrings("show ", tab("sho", "/ramdisk"));
    // Several commands share the typed text: it grows to what they share.
    try std.testing.expectEqualStrings("sh", tab("sh", "/ramdisk"));
    try std.testing.expectEqualStrings("c", tab("c", "/ramdisk"));
    // A word no command starts with is left alone, and so is an empty line.
    try std.testing.expectEqualStrings("zz", tab("zz", "/ramdisk"));
    try std.testing.expectEqualStrings("", tab("", "/ramdisk"));
    // Leading spaces do not turn the first word into an argument: `Bun` names
    // a file in the cwd, and command completion still refuses it.
    try std.testing.expectEqualStrings("  Bun", tab("  Bun", "/ramdisk"));
}

test "APP-026: a press that cannot finish the word says how many entries matched" {
    // Ambiguous: the line already holds every shared character, so the host
    // has nothing to echo — this count is what makes it show the candidates
    // instead of looking dead.
    const ambiguous = tabResult("cat team", "/ramdisk");
    try std.testing.expectEqual(@as(usize, 2), ambiguous.r.matches);
    try std.testing.expectEqual(@as(usize, 8), ambiguous.r.len);
    // Unique and unmatched are the other two answers.
    try std.testing.expectEqual(@as(usize, 1), tabResult("show Bun", "/ramdisk").r.matches);
    try std.testing.expectEqual(@as(usize, 0), tabResult("show zzz", "/ramdisk").r.matches);
}

test "APP-026: the candidates offered are exactly the entries that matched" {
    try std.testing.expectEqualStrings("team1.txt team2.txt ", candidates("cat team", "/ramdisk"));
    // A directory is shown as one — the same mark completion would append.
    try std.testing.expectEqualStrings("models/ ", candidates("show mod", "/ramdisk"));
    // An empty argument offers the whole directory, which is how a user asks
    // "what is here?" without typing a command.
    try std.testing.expectEqualStrings(
        "Bunny.glb duck.glb team1.txt team2.txt models/ ",
        candidates("cat ", "/ramdisk"),
    );
    // The first word offers commands, not files.
    try std.testing.expectEqualStrings("show shutdown ", candidates("sh", "/ramdisk"));
}

test "APP-027: a lower-case guess still finds a name spelled with capitals" {
    // Nothing matches `bun` exactly, so the press retries without regard to
    // case and REWRITES what was typed to the name that exists — `erased`
    // counts the characters the host must take back off the screen.
    const r = tabResult("show bun", "/ramdisk");
    try std.testing.expectEqualStrings("show Bunny.glb", r.line);
    try std.testing.expectEqual(@as(usize, 3), r.r.erased);
    // An exact match never rewrites: nothing to erase.
    try std.testing.expectEqual(@as(usize, 0), tabResult("show Bun", "/ramdisk").r.erased);
    // Case folding reaches inside a directory part too.
    try std.testing.expectEqualStrings("show models/rabbit.glb", tab("show models/RAB", "/ramdisk"));
}

test "cd offers directories only — never a file it cannot enter" {
    // `d` matches the file duck.glb and nothing else, so `cd d` completes to
    // nothing at all rather than to a file.
    try std.testing.expectEqualStrings("cd d", tab("cd d", "/ramdisk"));
    try std.testing.expectEqual(@as(usize, 0), tabResult("cd d", "/ramdisk").r.matches);
    try std.testing.expectEqualStrings("", candidates("cd d", "/ramdisk"));
    // The same text under a command that reads files completes fine.
    try std.testing.expectEqualStrings("cat duck.glb", tab("cat d", "/ramdisk"));
    // An empty `cd` argument offers the directories of the cwd, only.
    try std.testing.expectEqualStrings("models/ ", candidates("cd ", "/ramdisk"));
}

test "a completion that cannot fit the line changes nothing" {
    var buf: [16]u8 = undefined;
    const text = "show Bun";
    @memcpy(buf[0..text.len], text);
    // `Bunny.glb` needs 14 characters; the buffer holds 16 but the line would
    // reach 5 + 9 = 14 — one more character of prefix and it would not.
    var small: [13]u8 = undefined;
    @memcpy(small[0..text.len], text);
    const r = complete.line(&small, text.len, "/ramdisk", DIRS, &CMDS);
    try std.testing.expectEqual(@as(usize, text.len), r.len);
    try std.testing.expectEqualStrings("show Bun", small[0..r.len]);
    // The match still stands, so the host can still show what it found.
    try std.testing.expectEqual(@as(usize, 1), r.matches);
}
