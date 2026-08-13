//! `ls [PATH...]` — list directories and name files. Directories print with a
//! trailing '/', files with their size; `ls /` shows the mounts. Several
//! arguments (a glob's usual product) list each; a file argument prints as its
//! own one-line entry, the way ls answers `ls *.zig`.

const std = @import("std");
const vfs = @import("vfs");
const ifilesys = @import("ifilesys");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");

pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) return listOne(c, ".");
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |path| listOne(c, path);
}

fn listOne(c: console.Console, path: []const u8) void {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, path, &buf) orelse return;
    // A file argument is its own entry; only a directory is enumerated.
    if (vfs.kind(abs)) |k| {
        if (k == .file) {
            var line: [96]u8 = undefined;
            const size = if (vfs.read(abs)) |data| data.len else 0;
            c.write(std.fmt.bufPrint(&line, "{s}  ({d} bytes)\n", .{ path, size }) catch return);
            return;
        }
    }
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
            error.NotADirectory => "ls: not a directory: '",
            error.NotFound => "ls: no such directory '",
            error.IoFailed => "ls: i/o error reading '",
        });
        c.write(abs);
        c.write("'\n");
    };
}
