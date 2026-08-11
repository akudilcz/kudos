//! `rm PATH` — delete a file (spec STO-008).

const ifilesys = @import("ifilesys");
const vfs = @import("vfs");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");

/// `rm PATH` — remove a file from whichever store the path resolves to.
///
/// Directories are refused: removing one is `rmdir`'s job, and a delete that
/// silently took a whole subtree with it would be the one command in this shell
/// whose mistake cannot be undone. Every failure names the resolved absolute
/// path and what the store said, because "rm: error" on a machine with several
/// mounted stores does not tell you which one refused.
pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: rm PATH\n");
        return;
    }
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, args, &buf) orelse return;
    vfs.remove(abs) catch |e| {
        c.write("error: cannot remove '");
        c.write(abs);
        c.write("': ");
        c.write(switch (e) {
            error.NotFound => "no such file",
            error.NotADirectory => "a component of the path is a file",
            error.IsADirectory => "it is a directory",
            error.Exists => "the name is already taken",
            error.NotEmpty => "the directory is not empty",
            error.ReadOnly => "the store is read-only",
            error.NoSpace => "the store is full",
            error.IoFailed => "the store's medium failed",
        });
        c.put('\n');
        return;
    };
}
