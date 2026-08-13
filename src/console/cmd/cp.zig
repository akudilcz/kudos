//! `cp SRC... DEST` — copy files. Several sources need a directory DEST, as in
//! cp(1); one source may name its copy.

const std = @import("std");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

pub fn run(c: console.Console, args: []const u8) void {
    var words: [16][]const u8 = undefined;
    const n = collect(args, &words);
    if (n < 2) {
        c.write("usage: cp SRC... DEST\n");
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
        copyOne(c, src, dest, dest_is_dir);
    }
}

/// Copy one source to `dest` (a directory keeps the source's basename).
pub fn copyOne(c: console.Console, src: []const u8, dest: []const u8, dest_is_dir: bool) bool {
    var sbuf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, src, &sbuf) orelse return false;
    const data = vfs.read(abs) orelse {
        c.write("cp: cannot read '");
        c.write(abs);
        c.write("': no such file\n");
        return false;
    };
    var tbuf: [vfs.MAX_PATH]u8 = undefined;
    var target = dest;
    if (dest_is_dir) {
        const base = if (std.mem.lastIndexOfScalar(u8, abs, '/')) |i| abs[i + 1 ..] else abs;
        target = std.fmt.bufPrint(&tbuf, "{s}/{s}", .{ dest, base }) catch {
            c.write("cp: path too long\n");
            return false;
        };
    }
    vfs.write(target, data) catch |e| {
        c.write("cp: cannot write '");
        c.write(target);
        c.write("': ");
        c.write(patharg.writeErrorText(e));
        c.put('\n');
        return false;
    };
    return true;
}

/// Split args into at most words.len tokens; more is reported by the count cap
/// (callers bound their commands well under it).
pub fn collect(args: []const u8, words: *[16][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    return n;
}
