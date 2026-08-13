//! Recursive filesystem operations over the VFS — the one tree walk `rm -r`,
//! `cp -r` and a directory `mv` share, so all three agree on depth limits and
//! failure wording. Deletion re-lists after every removal instead of iterating
//! a directory it is mutating; the store's enumeration order is not a contract
//! this walk relies on.

const std = @import("std");
const vfs = @import("vfs");
const ifilesys = @import("ifilesys");
const console = @import("console.zig");

/// How deep a tree these walks follow. Deeper is refused, not truncated: the
/// recursion carries a MAX_PATH buffer per level on the worker's stack, and a
/// runaway cycle must fail loudly rather than eat the stack.
pub const MAX_DEPTH: usize = 8;

/// Remove `abs` (a directory) and everything under it. Failures are reported
/// on `c` under the calling command's `name`; returns false if anything could
/// not be removed (the walk keeps going and takes what it can, as rm -r does).
pub fn removeTree(c: console.Console, name: []const u8, abs: []const u8) bool {
    return removeLevel(c, name, abs, 0);
}

fn removeLevel(c: console.Console, name: []const u8, abs: []const u8, depth: usize) bool {
    if (depth >= MAX_DEPTH) {
        complain(c, name, abs, "tree deeper than the walk follows");
        return false;
    }
    var ok = true;
    // Take the FIRST entry, remove it, re-list: never iterate what is mutating.
    while (firstEntry(abs)) |e| {
        var pathbuf: [vfs.MAX_PATH]u8 = undefined;
        const child = std.fmt.bufPrint(&pathbuf, "{s}/{s}", .{ abs, e.name() }) catch {
            complain(c, name, abs, "path too long");
            return false;
        };
        switch (e.kind) {
            .dir => {
                if (!removeLevel(c, name, child, depth + 1)) return false;
            },
            .file => vfs.remove(child) catch |err| {
                complain(c, name, child, @errorName(err));
                ok = false;
                // A child that will not go means re-listing finds it forever.
                return false;
            },
        }
    }
    vfs.rmdir(abs) catch |err| {
        complain(c, name, abs, @errorName(err));
        return false;
    };
    return ok;
}

/// Copy the directory `src_abs` and everything under it to `dst_abs` (created
/// here). Reports on `c` under `name`; false on any failure. Copying a tree
/// into itself is the caller's refusal to make — it can see both paths.
pub fn copyTree(c: console.Console, name: []const u8, src_abs: []const u8, dst_abs: []const u8) bool {
    return copyLevel(c, name, src_abs, dst_abs, 0);
}

fn copyLevel(c: console.Console, name: []const u8, src: []const u8, dst: []const u8, depth: usize) bool {
    if (depth >= MAX_DEPTH) {
        complain(c, name, src, "tree deeper than the walk follows");
        return false;
    }
    vfs.mkdir(dst) catch |err| switch (err) {
        error.Exists => {},
        else => {
            complain(c, name, dst, @errorName(err));
            return false;
        },
    };
    // Copy N entries by INDEX, re-listing each time: a write can grow the
    // store and move the names a held Entry pointed into.
    var i: usize = 0;
    var ok = true;
    while (entryAt(src, i)) |e| : (i += 1) {
        var sbuf: [vfs.MAX_PATH]u8 = undefined;
        var dbuf: [vfs.MAX_PATH]u8 = undefined;
        const s = std.fmt.bufPrint(&sbuf, "{s}/{s}", .{ src, e.name() }) catch {
            complain(c, name, src, "path too long");
            return false;
        };
        const d = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ dst, e.name() }) catch {
            complain(c, name, dst, "path too long");
            return false;
        };
        switch (e.kind) {
            .dir => {
                if (!copyLevel(c, name, s, d, depth + 1)) ok = false;
            },
            .file => {
                const data = vfs.read(s) orelse {
                    complain(c, name, s, "no such file");
                    ok = false;
                    continue;
                };
                vfs.write(d, data) catch |err| {
                    complain(c, name, d, @errorName(err));
                    ok = false;
                };
            },
        }
    }
    return ok;
}

/// One entry a `walk` reports.
pub const Seen = struct {
    /// The entry's absolute path — valid for the call only (it lives in the
    /// walk's per-level buffer).
    abs: []const u8,
    kind: ifilesys.Kind,
    /// How far below the walk's starting directory it is; 1 for its children.
    depth: usize,
    /// Bytes, for a file; 0 for a directory.
    size: usize,
};

/// What a walk hands each entry to.
pub const Visit = *const fn (ctx: ?*anyopaque, e: Seen) void;

/// Visit everything under directory `abs`, depth first, a directory before its
/// contents — the order `find` prints and `du` sums. The starting directory is
/// NOT visited: the caller already has it, and every caller wants to say
/// something different about it.
///
/// Returns false if the tree runs deeper than MAX_DEPTH, having visited what it
/// could: a walk that quietly stopped short would report a subtree as empty.
pub fn walk(abs: []const u8, ctx: ?*anyopaque, visit: Visit) bool {
    return walkLevel(abs, ctx, visit, 1);
}

fn walkLevel(abs: []const u8, ctx: ?*anyopaque, visit: Visit, depth: usize) bool {
    if (depth > MAX_DEPTH) return false;
    var ok = true;
    var i: usize = 0;
    while (entryAt(abs, i)) |e| : (i += 1) {
        var pathbuf: [vfs.MAX_PATH]u8 = undefined;
        // The root is "/" already, so joining under it must not double the slash.
        const child = std.fmt.bufPrint(&pathbuf, "{s}{s}{s}", .{
            abs,
            if (abs.len == 1 and abs[0] == '/') "" else "/",
            e.name(),
        }) catch {
            ok = false;
            continue;
        };
        visit(ctx, .{ .abs = child, .kind = e.kind, .depth = depth, .size = e.size });
        if (e.kind == .dir and !walkLevel(child, ctx, visit, depth + 1)) ok = false;
    }
    return ok;
}

/// An entry snapshot: the name COPIED out, because the store may move its
/// tables under the walk's writes and removals.
const Held = struct {
    buf: [vfs.MAX_PATH]u8,
    len: usize,
    kind: ifilesys.Kind,
    size: usize = 0,

    fn name(self: *const Held) []const u8 {
        return self.buf[0..self.len];
    }
};

fn firstEntry(abs: []const u8) ?Held {
    return entryAt(abs, 0);
}

fn entryAt(abs: []const u8, want: usize) ?Held {
    var grab = Grab{ .want = want };
    vfs.list(abs, Grab.cb, &grab) catch return null;
    return if (grab.got) grab.held else null;
}

const Grab = struct {
    want: usize,
    seen: usize = 0,
    got: bool = false,
    held: Held = undefined,

    fn cb(ctx: ?*anyopaque, e: ifilesys.Entry) void {
        const g: *Grab = @ptrCast(@alignCast(ctx.?));
        defer g.seen += 1;
        if (g.got or g.seen != g.want) return;
        const n = @min(e.name.len, g.held.buf.len);
        @memcpy(g.held.buf[0..n], e.name[0..n]);
        g.held.len = n;
        g.held.kind = e.kind;
        g.held.size = e.size;
        g.got = true;
    }
};

fn complain(c: console.Console, name: []const u8, path: []const u8, what: []const u8) void {
    c.write(name);
    c.write(": cannot process '");
    c.write(path);
    c.write("': ");
    c.write(what);
    c.put('\n');
}
