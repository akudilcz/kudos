//! `ls [PATH...]` — list directories and name files. Directories print in cyan
//! with a trailing '/', files in the default color with their size; `ls /`
//! shows the mounts. Several arguments (a glob's usual product) list each; a
//! file argument prints as its own one-line entry, the way ls answers
//! `ls *.zig`.

const std = @import("std");
const vfs = @import("vfs");
const ifilesys = @import("ifilesys");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");

/// The cyan directory entries print in — a pale tint from the same family as
/// the terminal's prompt green (0xFF80FFB0), on a console that colors at all.
const DIR_FG: u32 = 0xFF80FFFF;

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
            const size = if (vfs.read(abs)) |d| d.len else 0;
            c.write(std.fmt.bufPrint(&line, "{s}  ({d} bytes)\n", .{ path, size }) catch return);
            return;
        }
    }
    var cc = c;
    const Print = struct {
        fn cb(ctx: ?*anyopaque, e: ifilesys.Entry) void {
            const con: *console.Console = @ptrCast(@alignCast(ctx.?));
            var line: [96]u8 = undefined;
            switch (e.kind) {
                .dir => {
                    const s = std.fmt.bufPrint(&line, "{s}/\n", .{e.name}) catch return;
                    con.setColor(DIR_FG);
                    con.write(s);
                    con.resetColor();
                },
                .file => con.write(std.fmt.bufPrint(&line, "{s}  ({d} bytes)\n", .{ e.name, e.size }) catch return),
            }
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
