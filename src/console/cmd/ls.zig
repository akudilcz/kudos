//! `ls [PATH]` — list a directory.

const std = @import("std");
const vfs = @import("vfs");
const ifilesys = @import("ifilesys");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");

/// `ls [PATH]` — list a directory (default: the cwd). Directories print
/// with a trailing '/', files with their size; `ls /` shows the mounts.
pub fn run(c: console.Console, args: []const u8) void {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, if (args.len == 0) "." else args, &buf) orelse return;
    // The listing callback's context: this console, addressable for the
    // duration of the synchronous vfs.list below.
    var cc = c;
    const Print = struct {
        fn cb(ctx: ?*anyopaque, e: ifilesys.Entry) void {
            const con: *console.Console = @ptrCast(@alignCast(ctx.?));
            var line: [96]u8 = undefined;
            const s = switch (e.kind) {
                .dir => std.fmt.bufPrint(&line, "{s}/\n", .{e.name}) catch return,
                .file => std.fmt.bufPrint(&line, "{s}  ({d} bytes)\n", .{ e.name, e.size }) catch return,
            };
            con.write(s);
        }
    };
    vfs.list(abs, Print.cb, &cc) catch |e| {
        c.write(switch (e) {
            error.NotADirectory => "error: not a directory: '",
            error.NotFound => "error: no such directory '",
            error.IoFailed => "error: i/o error reading '",
        });
        c.write(abs);
        c.write("'\n");
    };
}
