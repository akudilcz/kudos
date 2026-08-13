//! `du [-hs] [PATH...]` — how many bytes a directory tree holds, per
//! subdirectory (or just the total, with -s). Sizes are BYTES, not disk blocks:
//! the store keeps a file as its exact bytes, so there is no block rounding to
//! report and no `--apparent-size` to distinguish.
//!
//! Each directory is summed by its own walk, so a tree of D directories is
//! walked D times. That is the flat trade for holding no state between visits;
//! at ramdisk scale it is unmeasurable, and the alternative — carrying a stack
//! of running totals through the visitor — is where a subtotal goes wrong
//! silently.

const std = @import("std");
const bytesize = @import("../bytesize.zig");
const console = @import("../console.zig");
const fstree = @import("../fstree.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: du [-hsac] [PATH...]\n";
const SPEC = "hsac";

/// Sums the files of one walk.
const Total = struct {
    bytes: usize = 0,

    fn visit(ctx: ?*anyopaque, e: fstree.Seen) void {
        const t: *Total = @ptrCast(@alignCast(ctx.?));
        if (e.kind == .file) t.bytes += e.size;
    }
};

/// Prints a line per entry found: every directory with its own subtree's total,
/// and (with -a) every file with its size, as du(1) has it.
const PerEntry = struct {
    c: console.Console,
    human: bool,
    all: bool,

    fn visit(ctx: ?*anyopaque, e: fstree.Seen) void {
        const p: *PerEntry = @ptrCast(@alignCast(ctx.?));
        switch (e.kind) {
            .dir => report(p.c, p.human, treeBytes(e.abs), e.abs),
            .file => if (p.all) report(p.c, p.human, e.size, e.abs),
        }
    }
};

/// How du's flags read together.
const Options = struct {
    human: bool = false,
    /// -s: the named tree's total alone, no per-entry lines.
    summary: bool = false,
    /// -a: a line for every file too, not only directories.
    all: bool = false,
    /// -c: a grand total across every path named.
    grand: bool = false,
};

pub fn run(c: console.Console, args: []const u8) void {
    var o = Options{};
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |op| switch (op) {
        .flag => |ch| switch (ch) {
            'h' => o.human = true,
            's' => o.summary = true,
            'a' => o.all = true,
            'c' => o.grand = true,
            else => return opt.refuse(c, "du", op, USAGE),
        },
        else => return opt.refuse(c, "du", op, USAGE),
    };

    var ops = opt.Operands.init(SPEC, args);
    var named = false;
    var total: usize = 0;
    while (ops.next()) |path| {
        named = true;
        total += one(c, path, o);
    }
    if (!named) total = one(c, ".", o);
    if (o.grand) report(c, o.human, total, "total");
}

/// Report one path and return its bytes: a file is its own size; a directory is
/// everything under it, with a line per entry unless -s asked for the total
/// alone.
fn one(c: console.Console, path: []const u8, o: Options) usize {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, path, &buf) orelse return 0;
    switch (vfs.kind(abs) orelse {
        c.write("du: cannot access '");
        c.write(path);
        c.write("': No such file or directory\n");
        return 0;
    }) {
        .file => {
            const data: []const u8 = vfs.read(abs) orelse "";
            report(c, o.human, data.len, abs);
            return data.len;
        },
        .dir => {},
    }
    if (!o.summary) {
        var per = PerEntry{ .c = c, .human = o.human, .all = o.all };
        _ = fstree.walk(abs, &per, PerEntry.visit);
    }
    // The named tree's own total, last — the order du prints it in.
    const bytes = treeBytes(abs);
    report(c, o.human, bytes, abs);
    return bytes;
}

/// Every file byte under directory `abs`.
fn treeBytes(abs: []const u8) usize {
    var t = Total{};
    _ = fstree.walk(abs, &t, Total.visit);
    return t.bytes;
}

/// One `SIZE<tab>PATH` line, in bytes or in the -h shape every tool shares.
fn report(c: console.Console, human: bool, bytes: usize, path: []const u8) void {
    var buf: [bytesize.MAX_TEXT]u8 = undefined;
    var num: [24]u8 = undefined;
    c.write(if (human) bytesize.human(bytes, &buf) else std.fmt.bufPrint(&num, "{d}", .{bytes}) catch "0");
    c.put('\t');
    c.write(path);
    c.put('\n');
}
