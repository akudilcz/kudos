//! Host tests of src/console/opt.zig — the getopt-subset option grammar every
//! shell command's flags parse through.

const std = @import("std");
const opt = @import("opt");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// A writer stub with Console's write/put shape, for `refuse`.
const Sink = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    pub fn write(self: *Sink, s: []const u8) void {
        for (s) |ch| self.put(ch);
    }
    pub fn put(self: *Sink, ch: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }
    fn text(self: *const Sink) []const u8 {
        return self.buf[0..self.len];
    }
};

fn flags(spec: []const u8, args: []const u8, out: []u8) usize {
    var sc = opt.Scan.init(spec, args);
    var n: usize = 0;
    while (sc.next()) |o| {
        out[n] = switch (o) {
            .flag => |ch| ch,
            .val => |v| v.letter,
            .missing => |ch| ch,
            .long => 'L',
        };
        n += 1;
    }
    return n;
}

test "a cluster is its letters: -al is -a -l" {
    var buf: [8]u8 = undefined;
    try expect(flags("", "-al", &buf) == 2);
    try expect(buf[0] == 'a' and buf[1] == 'l');
}

test "options and operands interleave; operands do not scan as options" {
    var sc = opt.Scan.init("", "src -l more");
    const o = sc.next().?;
    try expect(o.flag == 'l');
    try expect(sc.next() == null);

    var ops = opt.Operands.init("", "src -l more");
    try expectEqualStrings("src", ops.next().?);
    try expectEqualStrings("more", ops.next().?);
    try expect(ops.next() == null);
}

test "a spec'd letter takes the rest of its word or the next word" {
    var sc = opt.Scan.init("n:", "-n5");
    var o = sc.next().?;
    try expect(o.val.letter == 'n');
    try expectEqualStrings("5", o.val.arg);

    var sc2 = opt.Scan.init("n:", "-n 5 file");
    o = sc2.next().?;
    try expectEqualStrings("5", o.val.arg);
    try expect(sc2.next() == null);

    // The operand pass agrees the 5 was consumed.
    var ops = opt.Operands.init("n:", "-n 5 file");
    try expectEqualStrings("file", ops.next().?);
    try expect(ops.next() == null);
}

test "a spec'd letter with nothing left reports missing" {
    var sc = opt.Scan.init("c:", "-c");
    try expect(sc.next().? == .missing);
}

test "`--` ends the options: what follows is operand however it looks" {
    var sc = opt.Scan.init("", "-a -- -b");
    try expect(sc.next().?.flag == 'a');
    try expect(sc.next() == null);
    var ops = opt.Operands.init("", "-a -- -b");
    try expectEqualStrings("-b", ops.next().?);
}

test "a bare dash is an operand; a --word reports as long" {
    var ops = opt.Operands.init("", "-");
    try expectEqualStrings("-", ops.next().?);
    var sc = opt.Scan.init("", "--help");
    try expect(sc.next().? == .long);
}

test "quotes group a word and strip removes a matching outer pair" {
    var w = opt.Words{ .s = "grep 'a b' file" };
    try expectEqualStrings("grep", w.next().?);
    try expectEqualStrings("'a b'", w.next().?);
    try expectEqualStrings("file", w.next().?);

    try expectEqualStrings("a b", opt.strip("'a b'"));
    try expectEqualStrings("a;b", opt.strip("\"a;b\""));
    // A first quote that closes mid-word is not an outer pair.
    try expectEqualStrings("'a' 'b'", opt.strip("'a' 'b'"));
    try expectEqualStrings("plain", opt.strip("plain"));
}

test "operands come back quote-stripped" {
    var ops = opt.Operands.init("", "'a;b' c");
    try expectEqualStrings("a;b", ops.next().?);
    try expectEqualStrings("c", ops.next().?);
}

test "refuse wording: invalid option, missing argument, unrecognized long" {
    var s = Sink{};
    opt.refuse(&s, "ls", .{ .flag = 'Z' }, "usage: ls\n");
    try expectEqualStrings("ls: invalid option -- 'Z'\nusage: ls\n", s.text());

    var s2 = Sink{};
    opt.refuse(&s2, "head", .{ .missing = 'n' }, "usage: head\n");
    try expectEqualStrings("head: option requires an argument -- 'n'\nusage: head\n", s2.text());

    var s3 = Sink{};
    opt.refuse(&s3, "ls", .{ .long = "--wat" }, "usage: ls\n");
    try expectEqualStrings("ls: unrecognized option '--wat'\nusage: ls\n", s3.text());
}
