//! `mv SRC... DEST` — move files: cp then remove, because the store has no
//! rename. The source is only removed once its copy verifiably landed.

const std = @import("std");
const console = @import("../console.zig");
const cp = @import("cp.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

pub fn run(c: console.Console, args: []const u8) void {
    var words: [16][]const u8 = undefined;
    const n = cp.collect(args, &words);
    if (n < 2) {
        c.write("usage: mv SRC... DEST\n");
        return;
    }
    var dbuf: [vfs.MAX_PATH]u8 = undefined;
    const dest = patharg.resolve(c, words[n - 1], &dbuf) orelse return;
    const dest_is_dir = (vfs.kind(dest) orelse .file) == .dir;
    if (n > 2 and !dest_is_dir) {
        c.write("mv: '");
        c.write(dest);
        c.write("' is not a directory\n");
        return;
    }
    for (words[0 .. n - 1]) |src| {
        if (!cp.copyOne(c, src, dest, dest_is_dir)) continue;
        var sbuf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, src, &sbuf) orelse continue;
        vfs.remove(abs) catch |e| {
            c.write("mv: copied but cannot remove '");
            c.write(abs);
            c.write("': ");
            c.write(patharg.writeErrorText(e));
            c.put('\n');
        };
    }
}
