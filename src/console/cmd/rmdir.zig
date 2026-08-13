//! `rmdir DIR...` — remove empty directories. A directory with content is
//! refused (`the directory is not empty`): this shell has no recursive delete,
//! and the refusal is what makes `rm` on a directory safe to deny too.

const std = @import("std");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: rmdir DIR...\n");
        return;
    }
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |path| {
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        vfs.rmdir(abs) catch |e| {
            c.write("rmdir: cannot remove '");
            c.write(abs);
            c.write("': ");
            c.write(patharg.writeErrorText(e));
            c.put('\n');
        };
    }
}
