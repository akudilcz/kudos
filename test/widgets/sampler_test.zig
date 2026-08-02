//! Host tests for the sample ring: wrapping keeps the newest samples in order,
//! counter deltas survive a reset without inventing a spike, and a rate is only
//! reported when there is an interval to divide by.

const std = @import("std");
const sampler = @import("sampler");

const S8 = sampler.Series(8);

test "an empty series reports nothing rather than zero" {
    var s = S8{};
    try std.testing.expectEqual(@as(?f64, null), s.latest());
    try std.testing.expectEqual(@as(?f64, null), s.at(0));
    try std.testing.expect(s.range() == null);
    try std.testing.expectEqual(@as(f64, 0), s.ratePerSecond());
    try std.testing.expectEqual(@as(u64, 0), s.spanMs());
}

test "samples read back oldest-first and the ring wraps" {
    var s = S8{};
    var i: u64 = 0;
    while (i < 12) : (i += 1) s.push(@floatFromInt(i), i * 100);
    // Capacity is 8, so 4..11 survive, oldest first.
    try std.testing.expectEqual(@as(usize, 8), s.len);
    try std.testing.expectEqual(@as(f64, 4), s.at(0).?);
    try std.testing.expectEqual(@as(f64, 11), s.at(7).?);
    try std.testing.expectEqual(@as(f64, 11), s.latest().?);
    try std.testing.expectEqual(@as(?f64, null), s.at(8));
    try std.testing.expectEqual(@as(u64, 400), s.timeAt(0).?);
    try std.testing.expectEqual(@as(u64, 700), s.spanMs());
}

test "range and mean cover the samples held, not the ones evicted" {
    var s = S8{};
    for ([_]f64{ 100, 2, 3, 4, 5, 6, 7, 8, 9 }, 0..) |v, i| s.push(v, i * 10);
    const r = s.range().?;
    try std.testing.expectEqual(@as(f64, 2), r.min); // the 100 has been evicted
    try std.testing.expectEqual(@as(f64, 9), r.max);
    try std.testing.expectApproxEqAbs(@as(f64, 5.5), s.mean(), 0.001);
}

test "a counter series holds deltas and starts at zero" {
    var s = S8{};
    s.pushCounter(1000, 0); // first reading: nothing to difference against
    s.pushCounter(1010, 1000);
    s.pushCounter(1030, 2000);
    try std.testing.expectEqual(@as(f64, 0), s.at(0).?);
    try std.testing.expectEqual(@as(f64, 10), s.at(1).?);
    try std.testing.expectEqual(@as(f64, 20), s.at(2).?);
}

test "a counter that goes backwards records zero, not a negative spike" {
    var s = S8{};
    s.pushCounter(500, 0);
    s.pushCounter(600, 1000);
    s.pushCounter(5, 2000); // wrapped, or replaced by a fresh counter
    try std.testing.expectEqual(@as(f64, 0), s.latest().?);
    try std.testing.expect(s.ratePerSecond() >= 0);
}

test "rate is the summed deltas over the window's real duration" {
    var s = S8{};
    var t: u64 = 0;
    var total: u64 = 0;
    while (t <= 4000) : (t += 1000) {
        s.pushCounter(total, t);
        total += 50; // 50 per second
    }
    try std.testing.expectApproxEqAbs(@as(f64, 50), s.ratePerSecond(), 0.001);
}

test "a rate needs an interval: one sample, or a frozen clock, reports zero" {
    var s = S8{};
    s.pushCounter(10, 5000);
    try std.testing.expectEqual(@as(f64, 0), s.ratePerSecond());
    s.pushCounter(99, 5000); // same instant: no interval to divide by
    try std.testing.expectEqual(@as(f64, 0), s.ratePerSecond());
}

test "trend needs enough samples and follows the newest third" {
    var s = sampler.Series(12){};
    try std.testing.expectEqual(@as(i2, 0), s.trend());
    var i: usize = 0;
    while (i < 12) : (i += 1) s.push(@floatFromInt(i), i * 100);
    try std.testing.expectEqual(@as(i2, 1), s.trend());

    var falling = sampler.Series(12){};
    i = 0;
    while (i < 12) : (i += 1) falling.push(@floatFromInt(12 - i), i * 100);
    try std.testing.expectEqual(@as(i2, -1), falling.trend());

    var flat = sampler.Series(12){};
    i = 0;
    while (i < 12) : (i += 1) flat.push(42, i * 100);
    try std.testing.expectEqual(@as(i2, 0), flat.trend());
}

test "reset forgets the samples and the counter baseline" {
    var s = S8{};
    s.pushCounter(100, 0);
    s.pushCounter(200, 1000);
    s.reset();
    try std.testing.expectEqual(@as(usize, 0), s.len);
    s.pushCounter(9000, 2000); // a fresh baseline, not a 8800 spike
    try std.testing.expectEqual(@as(f64, 0), s.latest().?);
}
