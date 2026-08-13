//! Host tests of src/console/pathname.zig — the split `basename` and `dirname`
//! print. The cases that matter are the ones a path-handling bug hides in:
//! trailing slashes, the root, a bare name, and the empty string.

const std = @import("std");
const pathname = @import("pathname");
const expectEqualStrings = std.testing.expectEqualStrings;

test "basename takes the last component" {
    try expectEqualStrings("b.txt", pathname.base("/a/b.txt", ""));
    try expectEqualStrings("b.txt", pathname.base("b.txt", ""));
    try expectEqualStrings("b", pathname.base("/a/b/", "")); // trailing slash ignored
    try expectEqualStrings("b", pathname.base("/a/b///", ""));
}

test "basename answers for the root and the empty path" {
    // "/" has no last component; coreutils prints the slash itself, and an
    // empty argument is the working directory.
    try expectEqualStrings("/", pathname.base("/", ""));
    try expectEqualStrings("/", pathname.base("///", ""));
    try expectEqualStrings(".", pathname.base("", ""));
}

test "basename removes a suffix, but never the whole name" {
    try expectEqualStrings("gl", pathname.base("src/gl.zig", ".zig"));
    try expectEqualStrings("gl.zig", pathname.base("src/gl.zig", ".c")); // not this suffix
    // A name that IS the suffix keeps it: `basename .zig .zig` is `.zig`.
    try expectEqualStrings(".zig", pathname.base(".zig", ".zig"));
}

test "dirname takes everything before the last component" {
    try expectEqualStrings("/a", pathname.dir("/a/b.txt"));
    try expectEqualStrings("/a", pathname.dir("/a/b/"));
    try expectEqualStrings("/a/b", pathname.dir("/a/b/c.txt"));
}

test "dirname answers '.' with no directory and '/' at the root" {
    try expectEqualStrings(".", pathname.dir("b.txt")); // a bare name is here
    try expectEqualStrings(".", pathname.dir(""));
    try expectEqualStrings("/", pathname.dir("/b.txt")); // directly in the root
}
