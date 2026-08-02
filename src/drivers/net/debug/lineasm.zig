//! Line assembly for the trace sink: bytes in, whole lines out.
//!
//! The trace arrives as byte spans that need not align to lines — a record may
//! land in pieces, and two records may share one span. This turns that stream
//! into complete lines, which is the unit everything downstream (the sequence
//! number, the flood suppressor, the wire) works in.
//!
//! It is pure and instance-based for one reason: a SHARED assembler is how two
//! cores tracing at once splice half of one record into the middle of another,
//! and the result is a trace that reads plausibly and says something that never
//! happened. One assembler per writer makes that impossible by construction
//! rather than by holding a lock across the whole sink.

const std = @import("std");

/// Accumulates bytes until a line completes. `CAP` bounds one line: a longer
/// source line is truncated to it rather than growing the buffer, because the
/// buffer is static and the alternative is dropping the line entirely.
pub fn Assembler(comptime CAP: usize) type {
    return struct {
        buf: [CAP]u8 = undefined,
        len: usize = 0,
        /// Lines truncated for want of room. Counted, never silent: a trace
        /// that quietly shortens its longest lines hides exactly the verbose
        /// records that were worth reading.
        truncated: u64 = 0,

        const Self = @This();

        /// Feed one span, calling `emit` with each COMPLETE line (newline
        /// included). Bytes after the last newline stay buffered for the next
        /// call. `emit` receives a slice into this assembler's buffer, valid
        /// only for the duration of the call.
        pub fn feed(self: *Self, bytes: []const u8, ctx: anytype, comptime emit: fn (@TypeOf(ctx), []const u8) void) void {
            var rest = bytes;
            while (rest.len > 0) {
                const nl = std.mem.indexOfScalar(u8, rest, '\n');
                const take = if (nl) |i| i + 1 else rest.len;
                const room = CAP - self.len;
                const n = @min(take, room);
                @memcpy(self.buf[self.len..][0..n], rest[0..n]);
                self.len += n;
                if (n < take) self.truncated += 1;
                if (nl != null) {
                    // A line that filled the buffer lost its newline with the
                    // rest of the tail; terminate it anyway, so downstream
                    // never sees a "line" that does not end like one.
                    if (self.len == CAP and self.buf[self.len - 1] != '\n') self.buf[self.len - 1] = '\n';
                    emit(ctx, self.buf[0..self.len]);
                    self.len = 0;
                }
                rest = rest[take..];
            }
        }

        /// Bytes held back waiting for a newline.
        pub fn pending(self: *const Self) usize {
            return self.len;
        }
    };
}
