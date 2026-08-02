//! Host tests of src/drivers/net/debug/lineasm.zig — trace line assembly.
//! This logic lived inside the netdebug sink, reachable only from a running
//! kernel, and it is where a garbled trace comes from: a split record, an
//! over-long line, or two cores sharing one buffer all produce output that
//! reads plausibly and describes something that never happened.

const std = @import("std");
const lineasm = @import("lineasm");

const Sink = struct {
    lines: [16][64]u8 = undefined,
    lens: [16]usize = @splat(0),
    n: usize = 0,

    fn take(self: *Sink, line: []const u8) void {
        const k = @min(line.len, self.lines[0].len);
        @memcpy(self.lines[self.n][0..k], line[0..k]);
        self.lens[self.n] = k;
        self.n += 1;
    }
    fn get(self: *const Sink, i: usize) []const u8 {
        return self.lines[i][0..self.lens[i]];
    }
};

fn emit(s: *Sink, line: []const u8) void {
    s.take(line);
}

const A = lineasm.Assembler(32);

test "a record split across spans reassembles into one line" {
    var a = A{};
    var s = Sink{};
    a.feed("hello ", &s, emit);
    try std.testing.expectEqual(@as(usize, 0), s.n); // nothing complete yet
    try std.testing.expectEqual(@as(usize, 6), a.pending());
    a.feed("world\n", &s, emit);
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expectEqualStrings("hello world\n", s.get(0));
    try std.testing.expectEqual(@as(usize, 0), a.pending());
}

test "several lines in one span emit separately, in order" {
    var a = A{};
    var s = Sink{};
    a.feed("one\ntwo\nthree\n", &s, emit);
    try std.testing.expectEqual(@as(usize, 3), s.n);
    try std.testing.expectEqualStrings("one\n", s.get(0));
    try std.testing.expectEqualStrings("two\n", s.get(1));
    try std.testing.expectEqualStrings("three\n", s.get(2));
}

test "a trailing partial line waits rather than emitting half a record" {
    var a = A{};
    var s = Sink{};
    a.feed("done\nstill going", &s, emit);
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expectEqualStrings("done\n", s.get(0));
    try std.testing.expectEqual(@as(usize, 11), a.pending());
}

test "an over-long line is truncated, terminated, and COUNTED" {
    var a = A{};
    var s = Sink{};
    const long = "0123456789" ** 5 ++ "\n"; // 51 bytes into a 32-byte buffer
    a.feed(long, &s, emit);
    try std.testing.expectEqual(@as(usize, 1), s.n);
    const got = s.get(0);
    try std.testing.expectEqual(@as(usize, 32), got.len);
    // Still ends like a line, or downstream's framing breaks on it.
    try std.testing.expectEqual(@as(u8, '\n'), got[got.len - 1]);
    // And the loss is on the record, not silent.
    try std.testing.expectEqual(@as(u64, 1), a.truncated);
}

test "two assemblers interleaved keep their records whole — the reason there is one per writer" {
    // THE invariant. Feed two records a fragment at a time, alternating, the
    // way two cores tracing at once would. With one shared buffer this splices
    // half of each into the other; with one assembler per writer it cannot.
    var a1 = A{};
    var a2 = A{};
    var s1 = Sink{};
    var s2 = Sink{};
    a1.feed("core-one ", &s1, emit);
    a2.feed("core-two ", &s2, emit);
    a1.feed("first", &s1, emit);
    a2.feed("second", &s2, emit);
    a2.feed("\n", &s2, emit);
    a1.feed("\n", &s1, emit);

    try std.testing.expectEqualStrings("core-one first\n", s1.get(0));
    try std.testing.expectEqualStrings("core-two second\n", s2.get(0));
}

test "an empty feed changes nothing" {
    var a = A{};
    var s = Sink{};
    a.feed("", &s, emit);
    try std.testing.expectEqual(@as(usize, 0), s.n);
    try std.testing.expectEqual(@as(usize, 0), a.pending());
}

test "a bare newline is a complete (empty) line, not a dropped one" {
    var a = A{};
    var s = Sink{};
    a.feed("\n", &s, emit);
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expectEqualStrings("\n", s.get(0));
}
