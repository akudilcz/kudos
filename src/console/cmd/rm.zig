//! `rm FILE...` — delete files (spec STO-008).
//!
//! Directories are refused: removing one is `rmdir`'s job, and a delete that
//! silently took a whole subtree would be the one command in this shell whose
//! mistake cannot be undone. Every failure names the resolved absolute path
//! and what the store said, because "rm: error" on a machine with several
//! mounted stores does not tell you which one refused.

const std = @import("std");
const vfs = @import("vfs");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");

pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: rm FILE...\n");
        return;
    }
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |path| {
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        vfs.remove(abs) catch |e| {
            c.write("rm: cannot remove '");
            c.write(abs);
            c.write("': ");
            c.write(patharg.writeErrorText(e));
            c.put('\n');
        };
    }
}
