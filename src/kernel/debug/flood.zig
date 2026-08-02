//! Flood suppression for the trace bus: collapse a repeating line instead of
//! shipping it a thousand times. Pure, so it is host-tested.
//!
//! WHY THIS IS A BUS FACILITY, NOT A PER-CALLSITE FIX. netdebug is the only observation
//! channel kudos has, and it is METERED (a bounded batch of lines per tick, because the
//! NIC's TX ring is 8 descriptors deep). So a subsystem repeating one line in a tight
//! loop does not merely add noise — it consumes the whole trace budget and pushes
//! everything else off the wire. A thousand repeats is tens of seconds of backlog in
//! which nothing else about the machine is visible.
//!
//! The callsites that flood are the ones you did not predict — a failing device, a
//! wedged loop, a retry that never gives up — so the BUS must be resilient to its
//! producers rather than each producer being patched in turn.
//!
//! WHAT IT DOES. Identical consecutive lines are swallowed. Every SUMMARY_EVERY of
//! them, one `(last line repeated N times)` marker is emitted instead — so a flood
//! stays VISIBLE (you can see it is still happening, and how fast) while costing a
//! bounded fraction of the trace. When a different line finally arrives, any
//! outstanding repeats are summarised first, so the count is never silently lost.
//!
//! Note it compares the line BODY, not the wire line: the `[NNNNNN] ` sequence prefix
//! differs on every line by construction, so comparing that would suppress nothing.

const std = @import("std");

/// Emit one summary marker per this many suppressed repeats. Small enough that a
/// flood is obvious in the trace; large enough that it cannot itself flood.
pub const SUMMARY_EVERY: u32 = 64;

/// How many identical repeats still print VERBATIM before suppression kicks in.
///
/// A line legitimately appearing two or three times in a row is not a flood, and
/// replacing the second one with `... last line repeated 1 more times` is noisier
/// than the duplicate was — it trades a line you can read for a line about a line.
/// Suppression should only engage when something is genuinely stuck.
pub const PASS_REPEATS: u32 = 2;

/// How many bytes of a line are compared. Lines longer than this are compared on
/// their prefix — two lines agreeing for 120 bytes are the same line for our purposes.
pub const CMP_CAP: usize = 120;

/// What the caller should do with the line it just fed in.
pub const Action = enum {
    /// Nothing was suppressed; ship this line.
    emit,
    /// Identical to the last line; drop it silently.
    suppress,
    /// Drop this line, but first ship a `(last line repeated N times)` marker.
    /// `count` is set on the Verdict.
    summary,
    /// Repeats ended. Ship the summary marker FIRST, then this line.
    summary_then_emit,
};

pub const Verdict = struct {
    action: Action,
    /// Repeats the summary marker should report (0 unless action names a summary).
    count: u32 = 0,
};

pub const Suppressor = struct {
    last: [CMP_CAP]u8 = @splat(0),
    last_len: usize = 0,
    have_last: bool = false,
    /// Repeats accumulated since the last marker was emitted.
    pending: u32 = 0,
    /// Repeats accumulated since the run of identical lines began (for the marker).
    run: u32 = 0,

    fn same(self: *const Suppressor, line: []const u8) bool {
        if (!self.have_last) return false;
        const n = @min(line.len, CMP_CAP);
        return n == self.last_len and std.mem.eql(u8, self.last[0..n], line[0..n]);
    }

    fn remember(self: *Suppressor, line: []const u8) void {
        const n = @min(line.len, CMP_CAP);
        @memcpy(self.last[0..n], line[0..n]);
        self.last_len = n;
        self.have_last = true;
    }

    pub fn feed(self: *Suppressor, line: []const u8) Verdict {
        if (self.same(line)) {
            self.run += 1;
            // A short run of duplicates reads better as itself than as a marker.
            if (self.run <= PASS_REPEATS) return .{ .action = .emit };
            self.pending += 1;
            if (self.pending >= SUMMARY_EVERY) {
                const n = self.pending;
                self.pending = 0;
                return .{ .action = .summary, .count = n };
            }
            return .{ .action = .suppress };
        }

        // A different line. If repeats are outstanding, report them before it — the
        // count must never be silently lost, or the trace lies about what happened.
        const owed = self.pending;
        self.pending = 0;
        self.run = 0;
        self.remember(line);
        if (owed > 0) return .{ .action = .summary_then_emit, .count = owed };
        return .{ .action = .emit };
    }

    /// Repeats not yet reported. A final flush (panic path, shutdown) should emit a
    /// marker for these, or the last flood vanishes with the machine.
    pub fn outstanding(self: *const Suppressor) u32 {
        return self.pending;
    }

    pub fn takeOutstanding(self: *Suppressor) u32 {
        const n = self.pending;
        self.pending = 0;
        return n;
    }
};
