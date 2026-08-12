//! Output redirection: where a command line's output goes when the answer is a
//! file, and the bounded buffer it lands in on the way. PURE — no VFS, no
//! console, no allocation; shell.zig resolves the path, runs the command against
//! a `Sink`, and writes the result.
//!
//! GRAMMAR: the LAST space-delimited `>` (replace) or `>>` (append) token
//! redirects, and one path word follows it. Both rules exist so source code can
//! be typed at a shell with no editor:
//!   - space-delimited, so `a>b` inside a line is text;
//!   - LAST, so `echo if (a > b) { > guard.zig` writes `if (a > b) {`.
//! The cost: a line ending in a literal `>` cannot be written this way, there
//! being no quoting to escape one with.
//!
//! Redirection is a SHELL facility. The per-core local commands (`prime`, `rt`,
//! `run`, `shutdown`) are dispatched by the line editor before the shell sees the
//! line and write through `Out`, which carries no cwd to resolve a path against;
//! they refuse a redirection rather than half-honour it.

const std = @import("std");

/// The largest file a redirection can write. An overflow writes NOTHING and says
/// so (`Sink.lost`) — a file cut in half compiles to a mystery.
pub const MAX_BYTES: usize = 16 << 10;

/// What a redirection does with a file that already exists.
pub const Mode = enum {
    /// `>` — the file becomes exactly this command's output.
    replace,
    /// `>>` — this command's output goes after what is already there.
    append,
};

/// A line that carries a redirection, split at it.
pub const Parsed = struct {
    /// The line with the redirection removed — what the shell runs.
    command: []const u8,
    /// The path as written, not yet normalized. Empty when none was named,
    /// multi-word when several were: `parse` reports the shape, the shell owns
    /// the wording of the complaint.
    path: []const u8,
    mode: Mode,
};

/// Split `line` at its redirection, or null when it has none.
pub fn parse(line: []const u8) ?Parsed {
    const trimmed = std.mem.trim(u8, line, " \t");
    // The LAST token wins, so the scan runs to the end.
    var at: ?usize = null;
    var tok_len: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) {
        while (i < trimmed.len and isSpace(trimmed[i])) i += 1;
        const start = i;
        while (i < trimmed.len and !isSpace(trimmed[i])) i += 1;
        const tok = trimmed[start..i];
        if (isRedirect(tok)) {
            at = start;
            tok_len = tok.len;
        }
    }
    const cut = at orelse return null;
    return .{
        .command = std.mem.trim(u8, trimmed[0..cut], " \t"),
        .path = std.mem.trim(u8, trimmed[cut + tok_len ..], " \t"),
        .mode = if (tok_len == 2) .append else .replace,
    };
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn isRedirect(tok: []const u8) bool {
    return std.mem.eql(u8, tok, ">") or std.mem.eql(u8, tok, ">>");
}

/// Where a redirected command's output accumulates: the caller's buffer, what is
/// used, and what did not fit. The loss is counted, not tolerated.
pub const Sink = struct {
    buf: []u8,
    len: usize = 0,
    lost: usize = 0,

    /// Put the file's existing content in front of the command's output — how
    /// `>>` appends with no second buffer. False when it does not fit.
    pub fn prefill(self: *Sink, existing: []const u8) bool {
        if (self.len != 0) return false; // only the first act on a fresh sink
        if (existing.len > self.buf.len) return false;
        @memcpy(self.buf[0..existing.len], existing);
        self.len = existing.len;
        return true;
    }

    /// Take one character, or count it lost once the budget is spent.
    pub fn put(self: *Sink, ch: u8) void {
        if (self.len == self.buf.len) {
            self.lost += 1;
            return;
        }
        self.buf[self.len] = ch;
        self.len += 1;
    }

    /// What the file should contain.
    pub fn bytes(self: *const Sink) []const u8 {
        return self.buf[0..self.len];
    }

    /// Anything dropped: the caller must not write a partial file.
    pub fn overflowed(self: *const Sink) bool {
        return self.lost != 0;
    }
};
