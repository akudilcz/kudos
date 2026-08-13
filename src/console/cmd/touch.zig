//! `touch FILE...` — create empty files. An existing file is left exactly as it
//! is: this store keeps no timestamps, so there is nothing true to update.

const std = @import("std");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: touch FILE...\n");
        return;
    }
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |path| {
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        if (vfs.read(abs) != null) continue;
        vfs.write(abs, "") catch |e| {
            c.write("touch: cannot create '");
            c.write(abs);
            c.write("': ");
            c.write(patharg.writeErrorText(e));
            c.put('\n');
        };
    }
}
