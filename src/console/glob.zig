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

/// Whether `name` matches `pat`, letter case included — what a shell's own
/// expansion means by a match.
pub fn match(pat: []const u8, name: []const u8) bool {
    return matches(pat, name, false);
}

/// The same match, without regard to letter case — `find -iname`, and anything
/// else that offers the case-insensitive form of a pattern flag. One matcher
/// with a parameter, so the two forms can never disagree about `*` or `?`.
pub fn matchIgnoringCase(pat: []const u8, name: []const u8) bool {
    return matches(pat, name, true);
}

/// Iterative star-backtracking: on a mismatch past a `*`, the star re-consumes
/// one more character and the tail retries.
fn matches(pat: []const u8, name: []const u8, fold: bool) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null; // position of the last '*' tried
    var mark: usize = 0; // name position that star had consumed to
    while (n < name.len) {
        if (p < pat.len and (pat[p] == '?' or same(pat[p], name[n], fold))) {
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

fn same(a: u8, b: u8, fold: bool) bool {
    if (a == b) return true;
    return fold and std.ascii.toLower(a) == std.ascii.toLower(b);
}
