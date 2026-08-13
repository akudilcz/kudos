//! `cp [-r] SRC... DEST` — copy files, and with `-r` whole directories through
//! the shared tree walk (fstree.zig). Several sources need a directory DEST, as
//! in cp(1); one source may name its copy. A directory without `-r` is omitted
//! with a word, exactly as cp omits it.

const std = @import("std");
const console = @import("../console.zig");
const fstree = @import("../fstree.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: cp [-r] SRC... DEST\n";

pub fn run(c: console.Console, args: []const u8) void {
    var recurse = false;
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'r', 'R' => recurse = true,
            'f' => {}, // there are no permission prompts to force through
            else => return opt.refuse(c, "cp", o, USAGE),
        },
        else => return opt.refuse(c, "cp", o, USAGE),
    };

    var words: [16][]const u8 = undefined;
    const n = collect(args, &words);
    if (n < 2) {
        c.write(USAGE);
        return;
    }
    var dbuf: [vfs.MAX_PATH]u8 = undefined;
    const dest = patharg.resolve(c, words[n - 1], &dbuf) orelse return;
    const dest_is_dir = (vfs.kind(dest) orelse .file) == .dir;
    if (n > 2 and !dest_is_dir) {
        c.write("cp: '");
        c.write(dest);
        c.write("' is not a directory\n");
        return;
    }
    for (words[0 .. n - 1]) |src| {
        _ = copyOne(c, "cp", src, dest, dest_is_dir, recurse);
    }
}

/// Copy one source to `dest` (a directory keeps the source's basename). A
/// directory source needs `recurse`; shared with `mv`, whose directory move is
/// this copy plus the shared remove.
pub fn copyOne(c: console.Console, name: []const u8, src: []const u8, dest: []const u8, dest_is_dir: bool, recurse: bool) bool {
    var sbuf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, src, &sbuf) orelse return false;

    var tbuf: [vfs.MAX_PATH]u8 = undefined;
    var target = dest;
    if (dest_is_dir) {
        const base = if (std.mem.lastIndexOfScalar(u8, abs, '/')) |i| abs[i + 1 ..] else abs;
        target = std.fmt.bufPrint(&tbuf, "{s}/{s}", .{ dest, base }) catch {
            c.write(name);
            c.write(": path too long\n");
            return false;
        };
    }

    if ((vfs.kind(abs) orelse .file) == .dir) {
        if (!recurse) {
            c.write(name);
            c.write(": -r not specified; omitting directory '");
            c.write(abs);
            c.write("'\n");
            return false;
        }
        // A tree must not be copied into itself: the walk would find its own
        // output forever.
        if (std.mem.startsWith(u8, target, abs) and
            (target.len == abs.len or target[abs.len] == '/'))
        {
            c.write(name);
            c.write(": cannot copy '");
            c.write(abs);
            c.write("' into itself\n");
            return false;
        }
        return fstree.copyTree(c, name, abs, target);
    }

    const data = vfs.read(abs) orelse {
        c.write(name);
        c.write(": cannot read '");
        c.write(abs);
        c.write("': no such file\n");
        return false;
    };
    vfs.write(target, data) catch |e| {
        c.write(name);
        c.write(": cannot write '");
        c.write(target);
        c.write("': ");
        c.write(patharg.writeErrorText(e));
        c.put('\n');
        return false;
    };
    return true;
}

/// Split args into at most words.len OPERAND tokens (options skipped); more is
/// reported by the count cap (callers bound their commands well under it).
pub fn collect(args: []const u8, words: *[16][]const u8) usize {
    var n: usize = 0;
    var ops = opt.Operands.init("", args);
    while (ops.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    return n;
}
