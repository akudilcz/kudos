//! Resolving a command's path argument against its console's working
//! directory — the one place the cwd-relative → absolute VFS path rule lives
//! for every path-taking command (cd, ls, cat, show).

const vfs = @import("vfs");
const console = @import("console.zig");

/// Resolve `arg` against this console's cwd (vfs.normalize); reports overflow
/// on the console and returns null.
pub fn resolve(c: console.Console, arg: []const u8, buf: *[vfs.MAX_PATH]u8) ?[]const u8 {
    return vfs.normalize(c.cwd(), arg, buf) orelse {
        c.write("error: path too long\n");
        return null;
    };
}
