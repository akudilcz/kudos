//! POSIX-style option scanning — the one argument grammar every shell command's
//! flags parse through, so `ls -al`, `ping -c 4 HOST` and `grep -in PAT FILE`
//! read the way their Linux namesakes do. PURE — no console, no VFS: the
//! scanner turns an argument string into options and operands; the command owns
//! what each letter means and refuses the rest through `refuse`, so an unknown
//! flag is one message and a usage line, never a locked terminal.
//!
//! GRAMMAR (the getopt subset these tools need):
//!   - a word starting `-` with more after it is an option cluster: `-al` is
//!     `-a -l`;
//!   - a letter marked `X:` in the spec takes a value — the rest of its word
//!     (`-n5`) or the following word (`-n 5`);
//!   - `--` ends the options; every later word is an operand however it looks;
//!   - a bare `-` and any word not starting `-` are operands, and options and
//!     operands may interleave (`ls src -l` works), as GNU tools allow;
//!   - a quote groups from the start of a word to its match, and `strip`
//!     removes a matching outer pair — how `grep 'a;b' FILE` receives `a;b`
//!     after the line grammar (redirect.zig) left the quoted `;` alone.
//!
//! Options and operands are read in two passes over the same argument string —
//! `Scan` yields the options and skips operands, `Operands` the reverse — so a
//! command's operand loop stays unbounded (an expanded glob can name more files
//! than any fixed argv array would hold). Both passes share the spec, so both
//! agree on which word a `-n` consumed.

const std = @import("std");

/// One scanned option.
pub const Opt = union(enum) {
    /// A plain option letter (`-a`, or each of `-al`'s two).
    flag: u8,
    /// A spec'd `X:` letter with the value it took.
    val: struct { letter: u8, arg: []const u8 },
    /// A spec'd `X:` letter with no value left to take.
    missing: u8,
    /// A `--word`, name included. No command here defines long options today;
    /// they land in the command's else arm and are refused by name.
    long: []const u8,
};

/// Space-split words where a quote at any point groups text (spaces included)
/// until its match — the word keeps its quotes; `strip` removes them. The one
/// word iterator both passes (and the shell's glob expansion) read through, so
/// every consumer agrees on where a word ends.
pub const Words = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(self: *Words) ?[]const u8 {
        while (self.i < self.s.len and isSpace(self.s[self.i])) self.i += 1;
        if (self.i >= self.s.len) return null;
        const start = self.i;
        var q: u8 = 0;
        while (self.i < self.s.len) : (self.i += 1) {
            const ch = self.s[self.i];
            if (q != 0) {
                if (ch == q) q = 0;
                continue;
            }
            if (ch == '\'' or ch == '"') {
                q = ch;
                continue;
            }
            if (isSpace(ch)) break;
        }
        return self.s[start..self.i];
    }
};

/// A word with a matching outer quote pair, stripped; any other word as given.
/// Matching means the word's first character opens a quote whose CLOSE is the
/// word's last character — `'a b'` strips, `'a' 'b'` (one word to the quote-
/// aware split) does not, because its first quote closes in the middle.
pub fn strip(word: []const u8) []const u8 {
    if (word.len < 2) return word;
    const q = word[0];
    if (q != '\'' and q != '"') return word;
    const close = std.mem.indexOfScalarPos(u8, word, 1, q) orelse return word;
    if (close != word.len - 1) return word;
    return word[1 .. word.len - 1];
}

/// The option pass: yields each option; operands are passed over for the
/// `Operands` pass to read.
pub const Scan = struct {
    spec: []const u8,
    words: Words,
    /// Unconsumed letters of the current `-xyz` cluster.
    rest: []const u8 = "",
    opts_over: bool = false,

    pub fn init(spec: []const u8, args: []const u8) Scan {
        return .{ .spec = spec, .words = .{ .s = args } };
    }

    pub fn next(self: *Scan) ?Opt {
        while (true) {
            if (self.rest.len > 0) {
                const ch = self.rest[0];
                self.rest = self.rest[1..];
                if (!takesValue(self.spec, ch)) return .{ .flag = ch };
                if (self.rest.len > 0) {
                    const v = strip(self.rest);
                    self.rest = "";
                    return .{ .val = .{ .letter = ch, .arg = v } };
                }
                const w = self.words.next() orelse return .{ .missing = ch };
                return .{ .val = .{ .letter = ch, .arg = strip(w) } };
            }
            const w = self.words.next() orelse return null;
            if (self.opts_over or !isOptWord(w)) continue; // an operand
            if (std.mem.eql(u8, w, "--")) {
                self.opts_over = true;
                continue;
            }
            if (w[1] == '-') return .{ .long = w };
            self.rest = w[1..];
        }
    }
};

/// The operand pass: yields each operand, quotes stripped; option words (and
/// the word a spec'd `-n` consumed as its value) are passed over.
pub const Operands = struct {
    spec: []const u8,
    words: Words,
    opts_over: bool = false,

    pub fn init(spec: []const u8, args: []const u8) Operands {
        return .{ .spec = spec, .words = .{ .s = args } };
    }

    pub fn next(self: *Operands) ?[]const u8 {
        while (self.words.next()) |w| {
            if (self.opts_over) return strip(w);
            if (std.mem.eql(u8, w, "--")) {
                self.opts_over = true;
                continue;
            }
            if (!isOptWord(w)) return strip(w);
            if (w[1] == '-') continue; // a --word takes no value here
            // Mirror Scan exactly: if the cluster's LAST letter takes a value
            // and none rode in the word, the next word was that value.
            var k: usize = 1;
            while (k < w.len) : (k += 1) {
                if (!takesValue(self.spec, w[k])) continue;
                if (k == w.len - 1) _ = self.words.next(); // `-n 5`: skip the 5
                break; // `-n5`: the rest of the word was the value
            }
        }
        return null;
    }
};

/// Print the one wording for a rejected option, then the command's usage line.
/// `c` is anything with `write([]const u8)` and `put(u8)` — the Console,
/// without this pure module importing it.
pub fn refuse(c: anytype, name: []const u8, o: Opt, usage: []const u8) void {
    c.write(name);
    switch (o) {
        .flag => |ch| {
            c.write(": invalid option -- '");
            c.put(ch);
            c.write("'\n");
        },
        .val => |v| {
            c.write(": invalid option -- '");
            c.put(v.letter);
            c.write("'\n");
        },
        .missing => |ch| {
            c.write(": option requires an argument -- '");
            c.put(ch);
            c.write("'\n");
        },
        .long => |w| {
            c.write(": unrecognized option '");
            c.write(w);
            c.write("'\n");
        },
    }
    c.write(usage);
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

/// An option word: `-x`, `-xyz`, `--`, `--word`. A bare `-` is an operand.
fn isOptWord(w: []const u8) bool {
    return w.len >= 2 and w[0] == '-';
}

/// Whether `ch` is marked `ch:` in the spec (it takes a value).
fn takesValue(spec: []const u8, ch: u8) bool {
    for (spec, 0..) |s, i| {
        if (s == ch) return i + 1 < spec.len and spec[i + 1] == ':';
    }
    return false;
}
