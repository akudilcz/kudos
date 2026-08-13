//! Splitting a path into the name at its end and the directory before it — what
//! `basename` and `dirname` print, and the same answers coreutils gives for the
//! awkward inputs (trailing slashes, the root, a bare name, an empty string).
//! PURE: slices of the input, no allocation, no VFS — nothing here asks whether
//! the path exists, because neither tool does.

const std = @import("std");

/// The last component of `path`, with any trailing slashes ignored:
///   `/a/b.txt` → `b.txt`,  `/a/b/` → `b`,  `b` → `b`,  `/` → `/`,  `` → `.`
///
/// `suffix` is removed from the end of the answer when it is there and is not
/// the whole of it — `basename src/gl.zig .zig` → `gl`, while
/// `basename .zig .zig` stays `.zig`, exactly as coreutils has it.
pub fn base(path: []const u8, suffix: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return if (path.len == 0) "." else "/";
    const cut = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| i + 1 else 0;
    const name = trimmed[cut..];
    if (suffix.len == 0 or suffix.len >= name.len) return name;
    if (!std.mem.endsWith(u8, name, suffix)) return name;
    return name[0 .. name.len - suffix.len];
}

/// Everything before the last component of `path`:
///   `/a/b.txt` → `/a`,  `/a/b/` → `/a`,  `b` → `.`,  `/b` → `/`,  `` → `.`
pub fn dir(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const cut = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return ".";
    if (cut == 0) return "/"; // the name sat directly in the root
    return trimmed[0..cut];
}
