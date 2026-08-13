//! `find [PATH] [-name|-iname PATTERN] [-type f|d] [-maxdepth N]` — the paths
//! under a directory, filtered. The subset an agent actually types to find one;
//! the expression grammar find(1) grew (`-o`, `-a`, parentheses, `-exec`) is not
//! here, and an unknown predicate is refused by name rather than ignored, which
//! would silently widen the answer.

const std = @import("std");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const fstree = @import("../fstree.zig");
const glob = @import("../glob.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: find [PATH] [-name|-iname PATTERN] [-type f|d] [-maxdepth N]\n";

/// The predicates one `find` applies, and where its output goes. Shared with
/// the walk through an opaque context, as every vfs callback is.
const Query = struct {
    c: console.Console,
    pattern: ?[]const u8 = null,
    /// `-iname` rather than `-name`: the same pattern, letter case ignored.
    fold_case: bool = false,
    want: ?vfs.ifilesys.Kind = null,
    max_depth: usize = fstree.MAX_DEPTH,
    matches: usize = 0,

    fn visit(ctx: ?*anyopaque, e: fstree.Seen) void {
        const q: *Query = @ptrCast(@alignCast(ctx.?));
        if (e.depth > q.max_depth) return;
        if (q.want) |k| {
            if (e.kind != k) return;
        }
        if (q.pattern) |p| {
            const name = e.abs[(std.mem.lastIndexOfScalar(u8, e.abs, '/') orelse 0) + 1 ..];
            const hit = if (q.fold_case) glob.matchIgnoringCase(p, name) else glob.match(p, name);
            if (!hit) return;
        }
        q.matches += 1;
        filter.line(q.c, e.abs);
    }
};

pub fn run(c: console.Console, args: []const u8) void {
    var q = Query{ .c = c };
    // find's predicates are `-word VALUE`, not getopt clusters, so the words are
    // read straight — `opt` would read `-name` as `-n -a -m -e`.
    var words = opt.Words{ .s = args };
    var start: []const u8 = ".";
    var have_start = false;
    while (words.next()) |raw| {
        const w = opt.strip(raw);
        if (w.len == 0) continue;
        if (w[0] != '-') {
            if (have_start) {
                c.write("find: one starting path at a time: ");
                c.write(w);
                c.put('\n');
                return;
            }
            start = w;
            have_start = true;
            continue;
        }
        const value = blk: {
            const v = words.next() orelse {
                c.write("find: ");
                c.write(w);
                c.write(" needs a value\n");
                return c.write(USAGE);
            };
            break :blk opt.strip(v);
        };
        if (std.mem.eql(u8, w, "-name") or std.mem.eql(u8, w, "-iname")) {
            q.pattern = value;
            q.fold_case = w[1] == 'i';
        } else if (std.mem.eql(u8, w, "-type")) {
            if (value.len != 1 or (value[0] != 'f' and value[0] != 'd')) return c.write("find: -type takes f or d\n");
            q.want = if (value[0] == 'f') .file else .dir;
        } else if (std.mem.eql(u8, w, "-maxdepth")) {
            q.max_depth = std.fmt.parseInt(usize, value, 10) catch return c.write("find: -maxdepth takes a number\n");
        } else {
            c.write("find: unknown predicate: ");
            c.write(w);
            c.put('\n');
            return c.write(USAGE);
        }
    }

    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, start, &buf) orelse return;
    switch (vfs.kind(abs) orelse {
        c.write("find: ");
        c.write(start);
        c.write(": no such file or directory\n");
        return;
    }) {
        // A file as the starting path is its own whole answer, as find has it.
        .file => return filter.line(c, abs),
        .dir => {},
    }
    if (!fstree.walk(abs, &q, Query.visit)) {
        var msg: [80]u8 = undefined;
        c.write(std.fmt.bufPrint(&msg, "find: stopped at {d} levels down — deeper entries not listed\n", .{fstree.MAX_DEPTH}) catch "find: tree too deep\n");
    }
}
