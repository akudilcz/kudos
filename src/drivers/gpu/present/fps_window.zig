//! Pure rolling-window FPS by the counter-sample method (the session
//! update cycle): the caller pushes {frame-count, now} samples at a slow cadence
//! (~2 Hz in present.zig) and reads fps = (newest.count − oldest.count) × hz ÷
//! (newest.ts − oldest.ts) — a frame-counter diff over a time diff. Cheap (a
//! handful of samples), smooth, and exact; no per-flip bookkeeping. Extracted from
//! present.zig so the ring eviction + the divide guards are host-testable;
//! present.zig keeps the call-rate throttle, the lock, and the tsc reads (this
//! module is tick-unit-agnostic: TSC ticks on hardware, anything in tests).
//! Imports nothing → its in-file tests run with `zig test` on the host.

/// One {frame-count, timestamp} sample.
pub const Sample = struct { count: u64, ts: u64 };

/// A fixed-capacity sample ring. `cap` is comptime so present.zig sizes it from
/// its FPS_SAMPLES config and tests use a small ring to hit the full-ring drop.
pub fn FpsWindow(comptime cap: usize) type {
    return struct {
        const Self = @This();

        smp: [cap]Sample,
        head: usize, // oldest sample index
        count: usize, // live samples (≤ cap)

        pub fn init() Self {
            return .{ .smp = undefined, .head = 0, .count = 0 };
        }

        /// Push one {frame_count, now} sample, first evicting samples older than
        /// `window_ticks` (always keeping at least one so the rate spans the
        /// window even when pushes are sparse), then dropping the oldest if the
        /// ring is full. `now` must be ≥ `window_ticks` and non-decreasing (TSC
        /// ticks since boot on hardware).
        pub fn push(self: *Self, frame_count: u64, now: u64, window_ticks: u64) void {
            const cutoff = now - window_ticks;
            while (self.count > 1 and self.smp[self.head].ts < cutoff) {
                self.head = (self.head + 1) % cap;
                self.count -= 1;
            }
            if (self.count == cap) { // full — drop oldest
                self.head = (self.head + 1) % cap;
                self.count -= 1;
            }
            const tail = (self.head + self.count) % cap;
            self.smp[tail] = .{ .count = frame_count, .ts = now };
            self.count += 1;
        }

        /// Smoothed FPS: frame-counter diff ÷ time diff over the sample window,
        /// scaled by `hz` (ticks per second). 0 until there are ≥2 samples
        /// spanning some time (the dt=0 guard).
        pub fn rate(self: *const Self, hz: u64) u32 {
            if (self.count < 2) return 0;
            const oldest = self.smp[self.head];
            const newest = self.smp[(self.head + self.count - 1) % cap];
            const dt = newest.ts - oldest.ts;
            if (dt == 0) return 0;
            return @intCast(((newest.count - oldest.count) * hz) / dt);
        }
    };
}
