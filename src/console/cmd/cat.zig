//! `cat FILE...` — print files, concatenated in argument order (which is what
//! the name means). Errors name the resolved absolute path.

const std = @import("std");
const vfs = @import("vfs");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");

pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: cat FILE...\n");
        return;
    }
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |path| {
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        if (vfs.read(abs)) |data| {
            c.write(data);
            if (data.len > 0 and data[data.len - 1] != '\n') c.put('\n');
        } else {
            c.write("cat: no such file '");
            c.write(abs);
            c.write("'\n");
        }
    }
}
