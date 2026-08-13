//! `sort [-rnuf] [FILE]` — the lines of a file or the pipe, in order.
//!
//! Sorting needs the lines held at once, and a command has no allocator of its
//! own, so the order is produced by SELECTION over the input instead: each pass
//! finds the next line to print. That is quadratic in the line count and
//! bounded by MAX_LINES, which is the honest trade — a file bigger than that is
//! refused with its size rather than sorted in part.

const std = @import("std");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");

/// Most lines one `sort` will order. Beyond it the command refuses: a partial
/// sort is a wrong answer that looks like a right one.
pub const MAX_LINES: usize = 4096;

const USAGE = "usage: sort [-rnuf] [-k FIELD] [-t SEP] [FILE]\n";
const SPEC = "rnufk:t:";

const Order = struct {
    numeric: bool = false,
    reverse: bool = false,
    fold_case: bool = false,
    unique: bool = false,
    /// `-k N`: compare the Nth field of each line rather than the whole line.
    /// One field, not sort(1)'s `F[.C][,F[.C]]` key syntax — the shape that
    /// covers `sort -k2 -n` and refuses the rest by name.
    field: ?usize = null,
    /// `-t SEP`: what separates the fields. sort(1)'s default is a run of
    /// blanks, which is what an unset separator means here.
    sep: ?u8 = null,
};

/// The text `-k` compares on: the chosen field of `line`, or the whole line
/// when no field was named (and when the line has no such field, as sort has
/// it — a short line sorts as an empty key).
fn key(line: []const u8, o: Order) []const u8 {
    const want = o.field orelse return line;
    if (want == 0) return line;
    var n: usize = 0;
    if (o.sep) |s| {
        var it = std.mem.splitScalar(u8, line, s);
        while (it.next()) |f| {
            n += 1;
            if (n == want) return f;
        }
        return "";
    }
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |f| {
        n += 1;
        if (n == want) return f;
    }
    return "";
}

pub fn run(c: console.Console, args: []const u8) void {
    var o: Order = .{};
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |op| switch (op) {
        .flag => |ch| switch (ch) {
            'r' => o.reverse = true,
            'n' => o.numeric = true,
            'u' => o.unique = true,
            'f' => o.fold_case = true,
            else => return opt.refuse(c, "sort", op, USAGE),
        },
        .val => |v| switch (v.letter) {
            'k' => o.field = std.fmt.parseInt(usize, v.arg, 10) catch return c.write("sort: -k takes a field number\n"),
            't' => {
                if (v.arg.len != 1) return c.write("sort: -t takes one character\n");
                o.sep = v.arg[0];
            },
            else => return opt.refuse(c, "sort", op, USAGE),
        },
        else => return opt.refuse(c, "sort", op, USAGE),
    };

    // One input: ordering the lines of several files at once would need them
    // all held, which is the very thing this cannot do (see MAX_LINES).
    var in = filter.Inputs.init(c, "sort", SPEC, args);
    const src = in.next() orelse return;
    if (in.next() != null) return c.write("sort: one file at a time (pipe them together with `cat a b | sort`)\n");
    const data = src.data;

    const total = filter.lineCount(data);
    if (total > MAX_LINES) {
        var buf: [80]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "sort: {d} lines is more than the {d} this sorts — not run\n", .{ total, MAX_LINES }) catch "sort: too many lines\n");
        return;
    }

    // Selection order: print the smallest line not yet printed, tracking the
    // last printed line by (value, index) so equal lines each come out once.
    var printed: usize = 0;
    var prev: ?usize = null;
    while (printed < total) : (printed += 1) {
        var best: ?usize = null;
        var i: usize = 0;
        while (i < total) : (i += 1) {
            if (!after(data, i, prev, o)) continue;
            if (best) |b| {
                if (!before(lineAt(data, i), lineAt(data, b), o)) continue;
            }
            best = i;
        }
        const pick = best orelse break;
        if (!(o.unique and prev != null and eq(lineAt(data, pick), lineAt(data, prev.?), o))) {
            filter.line(c, lineAt(data, pick));
        }
        prev = pick;
    }
}

/// Whether line `i` is still to come, given the last one printed: strictly
/// greater, or equal but later in the input (which is what keeps duplicate
/// lines from being printed by the same pass twice).
fn after(data: []const u8, i: usize, prev: ?usize, o: Order) bool {
    const p = prev orelse return true;
    if (before(lineAt(data, i), lineAt(data, p), o)) return false;
    if (eq(lineAt(data, i), lineAt(data, p), o)) return i > p;
    return true;
}

fn before(a: []const u8, b: []const u8, o: Order) bool {
    const ka = key(a, o);
    const kb = key(b, o);
    if (o.numeric) {
        const na = numOf(ka);
        const nb = numOf(kb);
        if (na != nb) return if (o.reverse) na > nb else na < nb;
        return false;
    }
    const cmp = compare(ka, kb, o.fold_case);
    if (cmp == 0) return false;
    return if (o.reverse) cmp > 0 else cmp < 0;
}

fn eq(a: []const u8, b: []const u8, o: Order) bool {
    const ka = key(a, o);
    const kb = key(b, o);
    if (o.numeric) return numOf(ka) == numOf(kb);
    return compare(ka, kb, o.fold_case) == 0;
}

fn compare(a: []const u8, b: []const u8, fold_case: bool) i8 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = if (fold_case) std.ascii.toLower(a[i]) else a[i];
        const cb = if (fold_case) std.ascii.toLower(b[i]) else b[i];
        if (ca < cb) return -1;
        if (ca > cb) return 1;
    }
    if (a.len == b.len) return 0;
    return if (a.len < b.len) -1 else 1;
}

/// The leading integer of a line, or 0 — `sort -n`'s reading of a line that
/// does not start with a number, as coreutils has it.
fn numOf(line: []const u8) i64 {
    const t = std.mem.trimStart(u8, line, " \t");
    var end: usize = 0;
    if (end < t.len and (t[end] == '-' or t[end] == '+')) end += 1;
    while (end < t.len and std.ascii.isDigit(t[end])) end += 1;
    if (end == 0) return 0;
    return std.fmt.parseInt(i64, t[0..end], 10) catch 0;
}

fn lineAt(data: []const u8, want: usize) []const u8 {
    var it = filter.lines(data);
    var i: usize = 0;
    while (it.next()) |l| : (i += 1) {
        if (i == want) return l;
    }
    return "";
}
