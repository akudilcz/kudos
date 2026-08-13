//! Comparing two texts line by line — the walk `diff` prints from. PURE: it
//! reports each step as a value and holds nothing, so the same walk drives a
//! terminal, a capture or a test.
//!
//! The algorithm is the simple one: while the lines agree, advance both; where
//! they part, look ahead a bounded distance in each text for the next line that
//! re-synchronises them, and report the lines skipped on either side as removed
//! and added. It is not a minimal edit script (diff(1) computes one), so a file
//! that re-orders whole blocks reports more churn than `diff` would. It never
//! reports a difference that is not there, and it says when the look-ahead gave
//! up — which is what a diff is FOR when the question is "did this file change".

const std = @import("std");

/// How far ahead the walk searches for a line that re-synchronises the texts.
/// Past it the rest of both texts is reported as changed, with `resynced` false
/// so the caller can say the comparison ran out of look-ahead.
pub const LOOKAHEAD: usize = 64;

/// One step of the comparison.
pub const Step = union(enum) {
    /// The line is in both texts, at this pair of positions.
    same: struct { a: usize, b: usize, text: []const u8 },
    /// The line is in the FIRST text only (a `<` line: removed).
    removed: struct { a: usize, text: []const u8 },
    /// The line is in the SECOND text only (a `>` line: added).
    added: struct { b: usize, text: []const u8 },
};

/// A comparison in progress: the two texts and where each has been read to.
pub const Walk = struct {
    a: []const u8,
    b: []const u8,
    ai: usize = 0,
    bi: usize = 0,
    /// Lines still owed as `removed` / `added` from the block being resolved.
    a_pending: usize = 0,
    b_pending: usize = 0,
    /// Cleared when a look-ahead ran out: the rest was reported as changed
    /// wholesale rather than matched up.
    resynced: bool = true,

    /// The next step, or null when both texts are exhausted.
    pub fn next(self: *Walk) ?Step {
        if (self.a_pending > 0) {
            const text = lineAt(self.a, self.ai) orelse "";
            const at = self.ai;
            self.ai += 1;
            self.a_pending -= 1;
            return .{ .removed = .{ .a = at, .text = text } };
        }
        if (self.b_pending > 0) {
            const text = lineAt(self.b, self.bi) orelse "";
            const at = self.bi;
            self.bi += 1;
            self.b_pending -= 1;
            return .{ .added = .{ .b = at, .text = text } };
        }

        const la = lineAt(self.a, self.ai);
        const lb = lineAt(self.b, self.bi);
        if (la == null and lb == null) return null;
        if (la == null) {
            const text = lb.?;
            const at = self.bi;
            self.bi += 1;
            return .{ .added = .{ .b = at, .text = text } };
        }
        if (lb == null) {
            const text = la.?;
            const at = self.ai;
            self.ai += 1;
            return .{ .removed = .{ .a = at, .text = text } };
        }
        if (std.mem.eql(u8, la.?, lb.?)) {
            const step = Step{ .same = .{ .a = self.ai, .b = self.bi, .text = la.? } };
            self.ai += 1;
            self.bi += 1;
            return step;
        }

        // The texts have parted. Find the nearest pair of positions that agree
        // again, preferring the smallest total skip so a one-line change stays
        // a one-line change.
        var best: ?struct { da: usize, db: usize } = null;
        var da: usize = 0;
        while (da <= LOOKAHEAD) : (da += 1) {
            var db: usize = 0;
            while (db <= LOOKAHEAD) : (db += 1) {
                if (da == 0 and db == 0) continue;
                if (best) |bst| {
                    if (da + db >= bst.da + bst.db) continue;
                }
                const x = lineAt(self.a, self.ai + da) orelse continue;
                const y = lineAt(self.b, self.bi + db) orelse continue;
                if (!std.mem.eql(u8, x, y)) continue;
                best = .{ .da = da, .db = db };
            }
        }
        if (best) |bst| {
            self.a_pending = bst.da;
            self.b_pending = bst.db;
        } else {
            // No re-synchronisation within the look-ahead: the remainder of each
            // text is the difference.
            self.resynced = false;
            self.a_pending = count(self.a) - self.ai;
            self.b_pending = count(self.b) - self.bi;
        }
        return self.next();
    }
};

/// Whether the two texts hold the same lines — the question `diff` answers with
/// its exit status, asked directly.
pub fn same(a: []const u8, b: []const u8) bool {
    var w = Walk{ .a = a, .b = b };
    while (w.next()) |step| {
        if (step != .same) return false;
    }
    return true;
}

/// Line `i` of `text`, or null past the end. The trailing newline does not make
/// an extra empty line.
pub fn lineAt(text: []const u8, i: usize) ?[]const u8 {
    var it = lines(text);
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) {
        if (n == i) return l;
    }
    return null;
}

/// How many lines `text` holds.
pub fn count(text: []const u8) usize {
    var it = lines(text);
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

fn lines(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    const body = if (text.len > 0 and text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
    return std.mem.splitScalar(u8, body, '\n');
}
