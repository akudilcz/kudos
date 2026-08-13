//! Glob matching for shell arguments: `*` (any run, empty included) and `?`
//! (exactly one character), bash's default semantics — a pattern that matches
//! nothing is passed through as itself, never an error. PURE: expansion against
//! the live VFS is the shell's job; this file only answers "does this name
//! match".

const std = @import("std");

/// Whether `word` contains a glob metacharacter at all — the gate that keeps
/// ordinary arguments (URLs excepted: `?` in a query string globs like bash)
/// from paying a directory enumeration.
pub fn hasGlob(word: []const u8) bool {
    return std.mem.indexOfAny(u8, word, "*?") != null;
}

/// Whether `name` matches `pat`. Iterative star-backtracking: on a mismatch
/// past a `*`, the star re-consumes one more character and the tail retries.
pub fn match(pat: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null; // position of the last '*' tried
    var mark: usize = 0; // name position that star had consumed to
    while (n < name.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            mark = n;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            n = mark;
        } else {
            return false;
        }
    }
    // Only trailing stars may remain: each matches the empty run.
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}
