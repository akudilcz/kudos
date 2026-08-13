//! Host tests of src/console/linediff.zig — the walk `diff` prints from.
//!
//! Two properties matter more than the exact edit script. First, SOUNDNESS: a
//! step is `same` only for lines that really are in both texts, so `diff -q`
//! never calls two different files identical. Second, RE-SYNCHRONISATION: after
//! a changed line the walk lines the texts up again, instead of reporting every
//! following line as changed — the failure that makes a diff useless.

const std = @import("std");
const linediff = @import("linediff");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// Count the steps of each kind over a whole walk.
fn tally(a: []const u8, b: []const u8) struct { same: usize, removed: usize, added: usize, resynced: bool } {
    var w = linediff.Walk{ .a = a, .b = b };
    var s: usize = 0;
    var r: usize = 0;
    var ad: usize = 0;
    while (w.next()) |step| switch (step) {
        .same => s += 1,
        .removed => r += 1,
        .added => ad += 1,
    };
    return .{ .same = s, .removed = r, .added = ad, .resynced = w.resynced };
}

test "identical texts are all same steps" {
    const t = tally("a\nb\nc\n", "a\nb\nc\n");
    try expectEqual(@as(usize, 3), t.same);
    try expectEqual(@as(usize, 0), t.removed);
    try expectEqual(@as(usize, 0), t.added);
    try expect(linediff.same("a\nb\nc\n", "a\nb\nc\n"));
}

test "a changed line is one removal and one addition, and the rest lines up" {
    // The failure this guards: reporting c and d as changed too, because the
    // walk never re-synchronised after b.
    const t = tally("a\nb\nc\nd\n", "a\nB\nc\nd\n");
    try expectEqual(@as(usize, 3), t.same); // a, c, d
    try expectEqual(@as(usize, 1), t.removed);
    try expectEqual(@as(usize, 1), t.added);
    try expect(t.resynced);
    try expect(!linediff.same("a\nb\nc\nd\n", "a\nB\nc\nd\n"));
}

test "an inserted line is an addition only" {
    const t = tally("a\nb\n", "a\nx\nb\n");
    try expectEqual(@as(usize, 2), t.same);
    try expectEqual(@as(usize, 0), t.removed);
    try expectEqual(@as(usize, 1), t.added);
}

test "a deleted line is a removal only" {
    const t = tally("a\nx\nb\n", "a\nb\n");
    try expectEqual(@as(usize, 2), t.same);
    try expectEqual(@as(usize, 1), t.removed);
    try expectEqual(@as(usize, 0), t.added);
}

test "a longer text reports its extra lines as additions" {
    const t = tally("a\n", "a\nb\nc\n");
    try expectEqual(@as(usize, 1), t.same);
    try expectEqual(@as(usize, 2), t.added);
}

test "the removed and added steps carry the lines themselves" {
    var w = linediff.Walk{ .a = "keep\ngone\n", .b = "keep\nnew\n" };
    try expectEqualStrings("keep", w.next().?.same.text);
    try expectEqualStrings("gone", w.next().?.removed.text);
    try expectEqualStrings("new", w.next().?.added.text);
    try expect(w.next() == null);
}

test "texts that never line up again say so" {
    // Wholly different texts, longer than the look-ahead: every line differs and
    // `resynced` reports that the comparison ran out of search rather than
    // finding a real alignment.
    var a: [8 * (linediff.LOOKAHEAD + 4)]u8 = undefined;
    var b: [8 * (linediff.LOOKAHEAD + 4)]u8 = undefined;
    var alen: usize = 0;
    var blen: usize = 0;
    for (0..linediff.LOOKAHEAD + 4) |i| {
        alen += (std.fmt.bufPrint(a[alen..], "a{d}\n", .{i}) catch unreachable).len;
        blen += (std.fmt.bufPrint(b[blen..], "b{d}\n", .{i}) catch unreachable).len;
    }
    const t = tally(a[0..alen], b[0..blen]);
    try expectEqual(@as(usize, 0), t.same);
    try expect(!t.resynced);
}

test "an empty text against a filled one is all additions" {
    const t = tally("", "a\nb\n");
    try expectEqual(@as(usize, 0), t.same);
    try expectEqual(@as(usize, 2), t.added);
    try expect(!linediff.same("", "a\n"));
}

test "a trailing newline is not an extra empty line" {
    try expect(linediff.same("a\nb\n", "a\nb"));
    try expectEqual(@as(usize, 2), linediff.count("a\nb\n"));
    try expectEqual(@as(usize, 2), linediff.count("a\nb"));
}
