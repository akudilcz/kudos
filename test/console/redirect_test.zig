//! Host tests of src/console/redirect.zig — the redirection grammar (APP-028,
//! APP-029), the `;` command list, the quote rules, and the capture budget
//! (APP-030).

const std = @import("std");
const redirect = @import("redirect");

test "`;` splits a line into commands, spaces optional" {
    var out: [redirect.MAX_LIST][]const u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 2), redirect.splitList("echo a; echo b", &out));
    try std.testing.expectEqualStrings("echo a", out[0]);
    try std.testing.expectEqualStrings("echo b", out[1]);
    try std.testing.expectEqual(@as(?usize, 2), redirect.splitList("cd /x;ls", &out));
}

test "empty `;` items drop: trailing and doubled semicolons run what is there" {
    var out: [redirect.MAX_LIST][]const u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 1), redirect.splitList("echo a;", &out));
    try std.testing.expectEqual(@as(?usize, 2), redirect.splitList("a;;b", &out));
    try std.testing.expectEqual(@as(?usize, 0), redirect.splitList(";;;", &out));
    try std.testing.expectEqual(@as(?usize, 1), redirect.splitList("just one", &out));
}

test "a quoted `;` is text — the line that types Zig into a file stays whole" {
    var out: [redirect.MAX_LIST][]const u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 1), redirect.splitList("echo 'const a = 1;' >> f.zig", &out));
    try std.testing.expectEqualStrings("echo 'const a = 1;' >> f.zig", out[0]);
    try std.testing.expectEqual(@as(?usize, 2), redirect.splitList("echo \"a;b\"; echo c", &out));
}

test "past MAX_LIST is a refusal, not a truncation" {
    var out: [redirect.MAX_LIST][]const u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), redirect.splitList("a;b;c;d;e;f;g;h;i", &out));
}

test "a quoted `>` or `|` is text to the redirect and pipe grammar" {
    try std.testing.expect(redirect.parse("echo 'a > b' ") == null);
    const r = redirect.parse("echo 'a > b' > out.txt").?;
    try std.testing.expectEqualStrings("echo 'a > b'", r.command);
    try std.testing.expectEqualStrings("out.txt", r.path);

    var stages: [redirect.MAX_STAGES][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), redirect.splitPipes("echo 'a | b'", &stages));
    try std.testing.expectEqual(@as(usize, 2), redirect.splitPipes("echo 'a | b' | wc", &stages));
}

test "a line with no redirection is not one (APP-028)" {
    try std.testing.expect(redirect.parse("echo hello") == null);
    try std.testing.expect(redirect.parse("") == null);
    // Not space-delimited, so it is text: this is what lets source code carrying
    // comparisons be typed at the shell at all.
    try std.testing.expect(redirect.parse("echo a>b") == null);
    try std.testing.expect(redirect.parse("echo if (a>b) {") == null);
}

test "`>` splits the command from its file (APP-028)" {
    const r = redirect.parse("echo hello > out.txt").?;
    try std.testing.expectEqualStrings("echo hello", r.command);
    try std.testing.expectEqualStrings("out.txt", r.path);
    try std.testing.expectEqual(redirect.Mode.replace, r.mode);
}

test "`>>` appends instead of replacing (APP-029)" {
    const r = redirect.parse("echo more >> out.txt").?;
    try std.testing.expectEqualStrings("echo more", r.command);
    try std.testing.expectEqualStrings("out.txt", r.path);
    try std.testing.expectEqual(redirect.Mode.append, r.mode);
}

test "the LAST redirection wins, so a comparison in the text survives (APP-028)" {
    const r = redirect.parse("echo if (a > b) { >> guard.zig").?;
    try std.testing.expectEqualStrings("echo if (a > b) {", r.command);
    try std.testing.expectEqualStrings("guard.zig", r.path);
    try std.testing.expectEqual(redirect.Mode.append, r.mode);
}

test "a redirection with no path, and one with several, are reported as shapes" {
    // parse stays total: it reports what it found and the shell owns the wording.
    const none = redirect.parse("echo hi >").?;
    try std.testing.expectEqualStrings("echo hi", none.command);
    try std.testing.expectEqualStrings("", none.path);

    const many = redirect.parse("echo hi > a.txt b.txt").?;
    try std.testing.expectEqualStrings("a.txt b.txt", many.path);
    try std.testing.expect(std.mem.indexOfScalar(u8, many.path, ' ') != null);

    const nocmd = redirect.parse("> a.txt").?;
    try std.testing.expectEqualStrings("", nocmd.command);
    try std.testing.expectEqualStrings("a.txt", nocmd.path);
}

test "a sink takes output up to its budget and counts what it lost (APP-030)" {
    var buf: [4]u8 = undefined;
    var sink = redirect.Sink{ .buf = &buf };
    for ("abcdef") |ch| sink.put(ch);
    try std.testing.expectEqualStrings("abcd", sink.bytes());
    try std.testing.expectEqual(@as(usize, 2), sink.lost);
    try std.testing.expect(sink.overflowed());
}

test "a sink under budget reports no loss (APP-030)" {
    var buf: [8]u8 = undefined;
    var sink = redirect.Sink{ .buf = &buf };
    sink.put('h');
    sink.put('i');
    try std.testing.expectEqualStrings("hi", sink.bytes());
    try std.testing.expect(!sink.overflowed());
}

test "prefill puts the existing file in front of new output (APP-029)" {
    var buf: [16]u8 = undefined;
    var sink = redirect.Sink{ .buf = &buf };
    try std.testing.expect(sink.prefill("old\n"));
    for ("new\n") |ch| sink.put(ch);
    try std.testing.expectEqualStrings("old\nnew\n", sink.bytes());
    try std.testing.expect(!sink.overflowed());
}

test "prefill refuses a file that already exceeds the budget (APP-030)" {
    var buf: [4]u8 = undefined;
    var sink = redirect.Sink{ .buf = &buf };
    // Refused, not truncated: the caller writes nothing rather than shortening
    // the file it was asked to append to.
    try std.testing.expect(!sink.prefill("too long for four"));
    try std.testing.expectEqual(@as(usize, 0), sink.len);
    // And only ever the first act on a sink — a second prefill cannot splice
    // content into the middle of captured output.
    try std.testing.expect(sink.prefill("ab"));
    try std.testing.expect(!sink.prefill("cd"));
}

test "the budget is a stated size, not an accident (APP-030)" {
    // A source file typed a line at a time must fit with room to spare; the
    // constant is the contract the shell reports when a redirection overflows.
    try std.testing.expect(redirect.MAX_BYTES >= 4 << 10);
}

test "a line without a spaced pipe token is one stage" {
    var s: [redirect.MAX_STAGES][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), redirect.splitPipes("ls", &s));
    try std.testing.expectEqualStrings("ls", s[0]);
    // Not space-delimited on both sides, so it is text — the same rule that
    // lets `a>b` be typed.
    try std.testing.expectEqual(@as(usize, 1), redirect.splitPipes("echo a|b", &s));
    try std.testing.expectEqual(@as(usize, 1), redirect.splitPipes("echo a ||", &s));
}

test "spaced pipes split into trimmed stages, left to right" {
    var s: [redirect.MAX_STAGES][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), redirect.splitPipes("ps | grep term | wc", &s));
    try std.testing.expectEqualStrings("ps", s[0]);
    try std.testing.expectEqualStrings("grep term", s[1]);
    try std.testing.expectEqualStrings("wc", s[2]);
}

test "an empty stage is preserved for the shell to refuse" {
    var s: [redirect.MAX_STAGES][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), redirect.splitPipes("ls | ", &s));
    try std.testing.expectEqualStrings("", s[1]);
}

test "past MAX_STAGES the split refuses rather than truncates" {
    var s: [redirect.MAX_STAGES][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), redirect.splitPipes(
        "a | b | c | d | e | f | g | h | i",
        &s,
    ));
}
