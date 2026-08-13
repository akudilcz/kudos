//! `mv SRC... DEST` — move files and directories: cp then remove, because the
//! store has no rename. The source is only removed once its copy verifiably
//! landed. A directory moves whole (mv needs no -r; the tree walk is
//! fstree.zig's, shared with cp -r and rm -r).

const std = @import("std");
const console = @import("../console.zig");
const cp = @import("cp.zig");
const fstree = @import("../fstree.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: mv SRC... DEST\n";

pub fn run(c: console.Console, args: []const u8) void {
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'f' => {}, // there are no overwrite prompts to force through
            else => return opt.refuse(c, "mv", o, USAGE),
        },
        else => return opt.refuse(c, "mv", o, USAGE),
    };

    var words: [16][]const u8 = undefined;
    const n = cp.collect(args, &words);
    if (n < 2) {
        c.write(USAGE);
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
        // A directory source copies recursively — moving one is mv's normal
        // work, no flag needed.
        if (!cp.copyOne(c, "mv", src, dest, dest_is_dir, true)) continue;
        var sbuf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, src, &sbuf) orelse continue;
        if ((vfs.kind(abs) orelse .file) == .dir) {
            _ = fstree.removeTree(c, "mv", abs);
            continue;
        }
        vfs.remove(abs) catch |e| {
            c.write("mv: copied but cannot remove '");
            c.write(abs);
            c.write("': ");
            c.write(patharg.writeErrorText(e));
            c.put('\n');
        };
    }
}
