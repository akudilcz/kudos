//! The `N`, `N-M`, `N-`, `-M` list `cut -f`/`cut -c` takes, and the question it
//! exists to answer: is position K selected? PURE — a parser over the spec text
//! and a predicate, no allocation and no fixed maximum on how many ranges a
//! spec may hold (the text itself is the storage, re-read per test).
//!
//! Positions are 1-BASED, as every tool that speaks this grammar has them: the
//! first field is 1, and 0 selects nothing rather than the first field, so a
//! `cut -f 0` reports nothing instead of quietly shifting every column.

const std = @import("std");

/// A parsed list, kept as its own text: `selects` re-reads it per position,
/// which costs a scan of a handful of characters and needs no bound on the
/// number of ranges.
pub const List = struct {
    spec: []const u8,

    /// Whether the list names 1-based position `pos`.
    pub fn selects(self: List, pos: usize) bool {
        if (pos == 0) return false;
        var it = std.mem.splitScalar(u8, self.spec, ',');
        while (it.next()) |part| {
            const r = parseRange(part) orelse continue;
            if (pos >= r.first and pos <= r.last) return true;
        }
        return false;
    }
};

/// Whether `spec` is a well-formed list — every part a number or a range, and
/// no part reversed (`5-2`). The caller refuses rather than guessing.
pub fn valid(spec: []const u8) bool {
    if (spec.len == 0) return false;
    var it = std.mem.splitScalar(u8, spec, ',');
    var any = false;
    while (it.next()) |part| {
        const r = parseRange(part) orelse return false;
        if (r.first > r.last) return false;
        any = true;
    }
    return any;
}

/// One `N`, `N-M`, `N-` or `-M` part as an inclusive bound pair. Null when the
/// part is not one of those.
fn parseRange(part: []const u8) ?struct { first: usize, last: usize } {
    const t = std.mem.trim(u8, part, " \t");
    if (t.len == 0) return null;
    const dash = std.mem.indexOfScalar(u8, t, '-') orelse {
        const n = std.fmt.parseInt(usize, t, 10) catch return null;
        return .{ .first = n, .last = n };
    };
    const lo_text = t[0..dash];
    const hi_text = t[dash + 1 ..];
    if (lo_text.len == 0 and hi_text.len == 0) return null; // a bare "-"
    const lo = if (lo_text.len == 0) 1 else std.fmt.parseInt(usize, lo_text, 10) catch return null;
    const hi = if (hi_text.len == 0) std.math.maxInt(usize) else std.fmt.parseInt(usize, hi_text, 10) catch return null;
    return .{ .first = lo, .last = hi };
}
