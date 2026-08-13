//! `grep [-ivncF] PATTERN [FILE...]` — print lines containing PATTERN, from the
//! named files or from what a pipe fed in. Fixed-string matching always (grep
//! -F, accepted as the no-op it is): this shell has no regex engine, and a
//! substring that quietly behaved as one would surprise in both directions.
//! `-i` ignores case, `-v` inverts, `-n` numbers lines, `-c` counts instead.

const std = @import("std");
const console = @import("../console.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: grep [-ivncF] PATTERN [FILE...]\n";

const Style = struct {
    insensitive: bool = false,
    invert: bool = false,
    numbers: bool = false,
    count: bool = false,
};

pub fn run(c: console.Console, args: []const u8) void {
    var st = Style{};
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'i' => st.insensitive = true,
            'v' => st.invert = true,
            'n' => st.numbers = true,
            'c' => st.count = true,
            'F' => {}, // fixed-string is the only matching there is
            else => return opt.refuse(c, "grep", o, USAGE),
        },
        else => return opt.refuse(c, "grep", o, USAGE),
    };

    var ops = opt.Operands.init("", args);
    const pat = ops.next() orelse {
        c.write(USAGE);
        return;
    };
    // More than one file prints `name:` prefixes, as grep does.
    var counting = ops;
    var nfiles: usize = 0;
    while (counting.next()) |_| nfiles += 1;

    var any_file = false;
    while (ops.next()) |path| {
        any_file = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        const data = vfs.read(abs) orelse {
            c.write("grep: ");
            c.write(path);
            c.write(": no such file\n");
            continue;
        };
        filter(c, st, pat, data, if (nfiles > 1) path else null);
    }
    if (!any_file) {
        const data = c.stdin orelse {
            c.write("grep: no input (pipe something in or name a file)\n");
            return;
        };
        filter(c, st, pat, data, null);
    }
}

fn filter(c: console.Console, st: Style, pat: []const u8, data: []const u8, label: ?[]const u8) void {
    var lines = std.mem.splitScalar(u8, data, '\n');
    var lineno: usize = 0;
    var hits: usize = 0;
    while (lines.next()) |line| {
        lineno += 1;
        // The split yields a final empty slice after a trailing newline; it is
        // not a line of the input.
        if (line.len == 0 and lines.peek() == null and lineno > 1) break;
        const hit = contains(line, pat, st.insensitive);
        if (hit == st.invert) continue;
        hits += 1;
        if (st.count) continue;
        if (label) |l| {
            c.write(l);
            c.put(':');
        }
        if (st.numbers) {
            var nb: [16]u8 = undefined;
            c.write(std.fmt.bufPrint(&nb, "{d}:", .{lineno}) catch "?:");
        }
        c.write(line);
        c.put('\n');
    }
    if (st.count) {
        if (label) |l| {
            c.write(l);
            c.put(':');
        }
        var nb: [16]u8 = undefined;
        c.write(std.fmt.bufPrint(&nb, "{d}\n", .{hits}) catch "?\n");
    }
}

/// Substring test, case-folded when asked — ASCII folding, which is all the
/// terminal can type.
fn contains(line: []const u8, pat: []const u8, insensitive: bool) bool {
    if (!insensitive) return std.mem.indexOf(u8, line, pat) != null;
    if (pat.len == 0) return true;
    if (pat.len > line.len) return false;
    var i: usize = 0;
    while (i + pat.len <= line.len) : (i += 1) {
        var k: usize = 0;
        while (k < pat.len) : (k += 1) {
            if (std.ascii.toLower(line[i + k]) != std.ascii.toLower(pat[k])) break;
        }
        if (k == pat.len) return true;
    }
    return false;
}
