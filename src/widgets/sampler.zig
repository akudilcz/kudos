//! A fixed-capacity ring of timed samples, and the rates and ranges a display
//! reads off it. PURE (imports only std): no clock, no allocation — the caller
//! pushes a value and the time it was taken, so the same series can be driven by
//! the kernel's tick, by a test's fabricated timeline, or replayed.
//!
//! This is what turns kudos's counters into something diagnosable. Every counter
//! in the tree is an instantaneous scalar; a fault is almost always visible as a
//! RATE ("drops climbing at 4/s") or a SHAPE ("free heap stepping down and never
//! coming back") that a single reading cannot show. One ring per series is the
//! cheapest thing that recovers both.
//!
//! Monotonic counters are pushed raw and differenced here — a series never has to
//! remember its own previous value, and a counter that resets (or a first sample
//! with nothing to difference against) reports a rate of zero rather than a
//! nonsense spike.

const std = @import("std");

/// A ring of `cap` samples. `cap` is comptime so the storage is inline: a HUD's
/// series array is one flat allocation made at init and never grown.
pub fn Series(comptime cap: usize) type {
    return struct {
        const Self = @This();

        /// Sample values, oldest-to-newest once wrapped.
        vals: [cap]f64 = [_]f64{0} ** cap,
        /// Sample times, in milliseconds, parallel to `vals`.
        times: [cap]u64 = [_]u64{0} ** cap,
        /// Write cursor: the next slot to fill.
        head: usize = 0,
        /// Samples held, saturating at `cap`.
        len: usize = 0,
        /// Previous raw counter reading, for `pushCounter`.
        last_total: u64 = 0,
        /// Whether `last_total` holds a reading yet — the first reading of a
        /// counter has nothing to difference against.
        have_total: bool = false,

        pub const CAPACITY = cap;

        /// Record a value observed at `now_ms`.
        pub fn push(self: *Self, value: f64, now_ms: u64) void {
            self.vals[self.head] = value;
            self.times[self.head] = now_ms;
            self.head = (self.head + 1) % cap;
            if (self.len < cap) self.len += 1;
        }

        /// Record a monotonic counter's reading: the series holds the DELTA since
        /// the previous reading, which is what a rate is made of. A reading below
        /// the last one (a counter that wrapped or was replaced) records zero
        /// rather than a negative spike.
        pub fn pushCounter(self: *Self, total: u64, now_ms: u64) void {
            const prev = self.last_total;
            self.last_total = total;
            if (!self.have_total) {
                self.have_total = true;
                self.push(0, now_ms);
                return;
            }
            self.push(if (total >= prev) @floatFromInt(total - prev) else 0, now_ms);
        }

        /// Sample `i`, oldest first. Null when `i` is past what is held.
        pub fn at(self: *const Self, i: usize) ?f64 {
            if (i >= self.len) return null;
            const start = (self.head + cap - self.len) % cap;
            return self.vals[(start + i) % cap];
        }

        /// The time sample `i` was taken.
        pub fn timeAt(self: *const Self, i: usize) ?u64 {
            if (i >= self.len) return null;
            const start = (self.head + cap - self.len) % cap;
            return self.times[(start + i) % cap];
        }

        /// The newest sample, or null when nothing has been pushed.
        pub fn latest(self: *const Self) ?f64 {
            if (self.len == 0) return null;
            return self.vals[(self.head + cap - 1) % cap];
        }

        /// Smallest and largest sample held.
        pub fn range(self: *const Self) ?struct { min: f64, max: f64 } {
            if (self.len == 0) return null;
            var lo = self.at(0).?;
            var hi = lo;
            var i: usize = 1;
            while (i < self.len) : (i += 1) {
                const v = self.at(i).?;
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
            return .{ .min = lo, .max = hi };
        }

        /// Mean of the samples held.
        pub fn mean(self: *const Self) f64 {
            if (self.len == 0) return 0;
            var sum: f64 = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) sum += self.at(i).?;
            return sum / @as(f64, @floatFromInt(self.len));
        }

        /// Units per second across the window: the summed samples divided by the
        /// time they span. Zero when fewer than two samples, or when the window
        /// has no duration — a rate needs an interval, and inventing one from a
        /// single reading is how dashboards lie.
        pub fn ratePerSecond(self: *const Self) f64 {
            if (self.len < 2) return 0;
            const t0 = self.timeAt(0).?;
            const t1 = self.timeAt(self.len - 1).?;
            if (t1 <= t0) return 0;
            var sum: f64 = 0;
            var i: usize = 1; // sample 0's delta belongs to the interval before t0
            while (i < self.len) : (i += 1) sum += self.at(i).?;
            return sum * 1000.0 / @as(f64, @floatFromInt(t1 - t0));
        }

        /// Milliseconds spanned by the samples held.
        pub fn spanMs(self: *const Self) u64 {
            if (self.len < 2) return 0;
            return self.timeAt(self.len - 1).? - self.timeAt(0).?;
        }

        /// Direction of travel: +1 rising, -1 falling, 0 flat, comparing the mean
        /// of the newest third against the mean of the oldest third. A third is
        /// wide enough that one noisy sample cannot flip the arrow.
        pub fn trend(self: *const Self) i2 {
            if (self.len < 6) return 0;
            const third = self.len / 3;
            var old: f64 = 0;
            var new: f64 = 0;
            var i: usize = 0;
            while (i < third) : (i += 1) {
                old += self.at(i).?;
                new += self.at(self.len - 1 - i).?;
            }
            const eps = @abs(old) * 0.02;
            if (new > old + eps) return 1;
            if (new + eps < old) return -1;
            return 0;
        }

        /// Forget every sample. Used when a series changes meaning (a different
        /// core, a re-armed measurement), never as routine housekeeping.
        pub fn reset(self: *Self) void {
            self.head = 0;
            self.len = 0;
            self.have_total = false;
            self.last_total = 0;
        }
    };
}
