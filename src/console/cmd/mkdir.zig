//! `mkdir DIR...` — create directories.

const std = @import("std");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: mkdir DIR...\n");
        return;
    }
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |path| {
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        vfs.mkdir(abs) catch |e| {
            c.write("mkdir: cannot create '");
            c.write(abs);
            c.write("': ");
            c.write(patharg.writeErrorText(e));
            c.put('\n');
        };
    }
}
