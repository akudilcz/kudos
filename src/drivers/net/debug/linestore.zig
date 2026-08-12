//! Trace-line store: seq-stamped lines, packed for the wire and RETAINED after
//! sending so a lost one can be served again by sequence number (DIAG-023).
//! Pure; netdebug.zig owns the one instance and the NIC.
//!
//! Two-phase drain (DIAG-024): `fill` copies pending lines without consuming
//! them; only a send the NIC accepted calls `advance`. A refused send costs
//! nothing — the same lines pack again next tick.
//!
//! Wire format: `[NNNNNN] body\n`, stamped at push so a suppressed line burns
//! no number and a resend is byte-identical.

const std = @import("std");

/// Decimal digits in the `[NNNNNN] ` stamp. The counter WRAPS rather than
/// widening; a receiver reads a smaller number after a larger one as the wrap.
pub const SEQ_DIGITS = 6;
pub const SEQ_PREFIX_LEN = SEQ_DIGITS + 3;
pub const SEQ_MOD: u32 = 1_000_000;

/// What one `push` did. Only `dropped_pending` is a loss — an unsent line was
/// overwritten. Retention expiry (a SENT line wrapped over) is not reported.
pub const Pushed = enum { stored, dropped_pending };

/// `bytes` of datagram payload holding `lines` whole lines.
pub const Filled = struct { bytes: usize, lines: usize };

/// Ring of `capacity` lines, each at most `line_cap` bytes. Layout: `total`
/// live lines, the oldest `total - unsent` already sent and retained for
/// resend, the newest `unsent` waiting for the drain.
pub fn Store(comptime capacity: usize, comptime line_cap: usize) type {
    return struct {
        const Self = @This();

        /// Body bytes a line carries after the stamp, before its newline.
        pub const BODY_CAP = line_cap - SEQ_PREFIX_LEN - 1;

        const Line = struct {
            bytes: [line_cap]u8 = undefined,
            len: usize = 0,
            /// Kept numeric so a resend match never parses its own text.
            wire_seq: u32 = 0,
        };

        slots: [capacity]Line = @splat(.{}),
        oldest: usize = 0,
        /// Live lines (retained + pending), <= capacity.
        total: usize = 0,
        /// Trailing lines of `total` not yet sent.
        unsent: usize = 0,
        next_seq: u32 = 1,

        /// Stamp `body` and queue it. Truncated to BODY_CAP; newline-terminated
        /// exactly once however it arrived.
        pub fn push(self: *Self, body: []const u8) Pushed {
            var result: Pushed = .stored;
            if (self.total == capacity) {
                // The victim is the oldest, which is retained whenever anything
                // is. Overwriting an UNSENT line is the one real loss.
                if (self.unsent == self.total) {
                    result = .dropped_pending;
                    self.unsent -= 1;
                }
                self.oldest = (self.oldest + 1) % capacity;
                self.total -= 1;
            }
            const slot = &self.slots[(self.oldest + self.total) % capacity];
            slot.wire_seq = self.next_seq;
            self.next_seq = (self.next_seq + 1) % SEQ_MOD;

            slot.bytes[0] = '[';
            var v = slot.wire_seq;
            var d: usize = SEQ_DIGITS;
            while (d > 0) {
                d -= 1;
                slot.bytes[1 + d] = '0' + @as(u8, @intCast(v % 10));
                v /= 10;
            }
            slot.bytes[1 + SEQ_DIGITS] = ']';
            slot.bytes[2 + SEQ_DIGITS] = ' ';
            // usize spelled out: @min against a comptime cap would narrow n's
            // type and the index arithmetic would overflow in it.
            var n: usize = @min(body.len, BODY_CAP);
            while (n > 0 and body[n - 1] == '\n') n -= 1;
            @memcpy(slot.bytes[SEQ_PREFIX_LEN..][0..n], body[0..n]);
            slot.bytes[SEQ_PREFIX_LEN + n] = '\n';
            slot.len = SEQ_PREFIX_LEN + n + 1;

            self.total += 1;
            self.unsent += 1;
            return result;
        }

        pub fn pending(self: *const Self) usize {
            return self.unsent;
        }

        /// Pack pending lines into `pkt`, oldest first, WITHOUT consuming them.
        /// Any pkt of at least `line_cap` always packs one.
        pub fn fill(self: *const Self, pkt: []u8) Filled {
            var used: usize = 0;
            var lines: usize = 0;
            while (lines < self.unsent) {
                const idx = (self.oldest + (self.total - self.unsent) + lines) % capacity;
                const line = &self.slots[idx];
                if (used + line.len > pkt.len) break;
                @memcpy(pkt[used..][0..line.len], line.bytes[0..line.len]);
                used += line.len;
                lines += 1;
            }
            return .{ .bytes = used, .lines = lines };
        }

        /// Mark the oldest `n` pending lines sent; they stay as resend window.
        pub fn advance(self: *Self, n: usize) void {
            self.unsent -= @min(n, self.unsent);
        }

        /// Copy live lines with seqs in `[from, from+count)` into `out`, oldest
        /// first; returns bytes used. Expired lines are absent — that is how the
        /// receiver learns a loss is permanent. Compared modulo SEQ_MOD.
        pub fn resendInto(self: *const Self, from: u32, count: u32, out: []u8) usize {
            var used: usize = 0;
            var i: usize = 0;
            while (i < self.total) : (i += 1) {
                const line = &self.slots[(self.oldest + i) % capacity];
                const rel = (line.wire_seq + SEQ_MOD - from) % SEQ_MOD;
                if (rel >= count) continue;
                if (used + line.len > out.len) break;
                @memcpy(out[used..][0..line.len], line.bytes[0..line.len]);
                used += line.len;
            }
            return used;
        }
    };
}
