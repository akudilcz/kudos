//! Resolving a command's path argument against its console's working
//! directory — the one place the cwd-relative → absolute VFS path rule lives
//! for every path-taking command — and the one wording for a store's refusal.

const vfs = @import("vfs");
const ifilesys = @import("ifilesys");
const console = @import("console.zig");

/// Resolve `arg` against this console's cwd (vfs.normalize); reports overflow
/// on the console and returns null.
pub fn resolve(c: console.Console, arg: []const u8, buf: *[vfs.MAX_PATH]u8) ?[]const u8 {
    return vfs.normalize(c.cwd(), arg, buf) orelse {
        c.write("error: path too long\n");
        return null;
    };
}

/// Plain English for a store's write refusal, shared by every mutating command
/// so "rm: error" never leaves the user guessing which store said what.
pub fn writeErrorText(e: ifilesys.WriteError) []const u8 {
    return switch (e) {
        error.NotFound => "no such file",
        error.NotADirectory => "a component of the path is a file",
        error.IsADirectory => "it is a directory",
        error.Exists => "the name is already taken",
        error.NotEmpty => "the directory is not empty",
        error.ReadOnly => "the store is read-only",
        error.NoSpace => "the store is full",
        error.IoFailed => "the store's medium failed",
    };
}
