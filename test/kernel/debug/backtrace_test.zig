//! Host tests of src/kernel/debug/backtrace.zig.

const std = @import("std");
const backtrace = @import("testroot").kernel.backtrace;
const testing = std.testing;
const walk = backtrace.walk;
const MAX_FRAMES = backtrace.MAX_FRAMES;

// A collector the tests emit into.
const Collector = struct {
    addrs: [MAX_FRAMES]usize = undefined,
    n: usize = 0,
    fn push(self: *Collector, a: usize) void {
        self.addrs[self.n] = a;
        self.n += 1;
    }
};

// Build a synthetic stack of `frames` linked RBP records in a buffer and return
// the innermost RBP. Each record is [saved_rbp, ret_addr]; ret_addr = 0x1000+i so
// the test can assert order. RBPs ascend (frame i at buf[2*i]).
fn buildStack(buf: []usize, frames: usize) usize {
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const next_rbp = if (i + 1 < frames) @intFromPtr(&buf[2 * (i + 1)]) else 0;
        buf[2 * i] = next_rbp; // saved rbp
        buf[2 * i + 1] = 0x1000 + i; // return address
    }
    return @intFromPtr(&buf[0]);
}

test "walks a well-formed chain innermost-first and stops at the null frame" {
    var buf: [8]usize = undefined;
    const seed = buildStack(&buf, 4);
    var col = Collector{};
    const lo = @intFromPtr(&buf[0]);
    const hi = @intFromPtr(&buf[0]) + @sizeOf(@TypeOf(buf));
    const n = walk(seed, lo, hi, &col, Collector.push);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqual(@as(usize, 0x1000), col.addrs[0]);
    try testing.expectEqual(@as(usize, 0x1003), col.addrs[3]);
}

test "a zero seed yields no frames" {
    var col = Collector{};
    try testing.expectEqual(@as(usize, 0), walk(0, 0, 0x10000, &col, Collector.push));
    try testing.expectEqual(@as(usize, 0), col.n);
}

test "an out-of-range RBP stops the walk (no wild read)" {
    var buf: [8]usize = undefined;
    const seed = buildStack(&buf, 4);
    var col = Collector{};
    // Bounds that exclude the buffer → the very first frame is rejected.
    const n = walk(seed, 0x1, 0x2, &col, Collector.push);
    try testing.expectEqual(@as(usize, 0), n);
}

test "a self-referential frame cannot loop forever" {
    var buf: [2]usize = undefined;
    buf[0] = @intFromPtr(&buf[0]); // saved rbp points at itself (cycle)
    buf[1] = 0x2000;
    var col = Collector{};
    const lo = @intFromPtr(&buf[0]);
    const hi = lo + @sizeOf(@TypeOf(buf));
    const n = walk(@intFromPtr(&buf[0]), lo, hi, &col, Collector.push);
    // Emits the first frame, then the rbp<=prev guard stops it (no infinite loop).
    try testing.expectEqual(@as(usize, 1), n);
}

test "misaligned RBP is rejected" {
    var buf: [8]usize = undefined;
    const seed = buildStack(&buf, 4);
    var col = Collector{};
    const lo = @intFromPtr(&buf[0]);
    const hi = lo + @sizeOf(@TypeOf(buf));
    // Seed +1 byte → not 8-aligned → rejected immediately.
    try testing.expectEqual(@as(usize, 0), walk(seed + 1, lo, hi, &col, Collector.push));
}
