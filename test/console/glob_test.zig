//! Host tests of src/console/glob.zig — `*`/`?` filename matching.

const std = @import("std");
const glob = @import("glob");
const expect = std.testing.expect;

test "a word without metacharacters never globs" {
    try expect(!glob.hasGlob("hello.zig"));
    try expect(glob.hasGlob("*.zig"));
    try expect(glob.hasGlob("a?c"));
}

test "star matches any run, empty included" {
    try expect(glob.match("*", ""));
    try expect(glob.match("*", "anything"));
    try expect(glob.match("*.zig", "cube.zig"));
    try expect(glob.match("*.zig", ".zig"));
    try expect(!glob.match("*.zig", "cube.zig.bak"));
    try expect(glob.match("cube.*", "cube.zig"));
    try expect(glob.match("a*b*c", "aXXbYYc"));
    try expect(!glob.match("a*b*c", "aXXbYY"));
}

test "question mark matches exactly one character" {
    try expect(glob.match("a?c", "abc"));
    try expect(!glob.match("a?c", "ac"));
    try expect(!glob.match("a?c", "abbc"));
    try expect(glob.match("???", "abc"));
}

test "star backtracks: the tail after it re-anchors as many times as needed" {
    // A first '*' that greedily ate to the end must give characters back for
    // the literal tail to land — the case a non-backtracking matcher fails.
    try expect(glob.match("*b", "abab"));
    try expect(glob.match("*ab", "aab"));
    try expect(!glob.match("*ab", "aba"));
    try expect(glob.match("a*a*a", "aaaa"));
}

test "matching is exact at both ends" {
    try expect(!glob.match("cube", "cube.zig"));
    try expect(!glob.match("ube*", "cube.zig"));
    try expect(glob.match("cube.zig", "cube.zig"));
}
