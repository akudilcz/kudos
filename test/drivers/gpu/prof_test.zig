//! Host tests of src/drivers/gpu/prof.zig.

const std = @import("std");
const prof = @import("testroot").gpu.prof;
const Acc = prof.Acc;
const expectEqual = std.testing.expectEqual;
const spanTicks = prof.spanTicks;

test "Acc.add accumulates sum/max/n across spans" {
    var a = Acc{};
    a.add(100);
    a.add(300);
    a.add(200);
    try expectEqual(@as(u64, 600), a.sum);
    try expectEqual(@as(u64, 300), a.max); // worst single span, not the last one
    try expectEqual(@as(u64, 3), a.n);
    try expectEqual(@as(u64, 200), a.avg());
}

test "Acc.avg with no spans is 0 (no divide-by-zero)" {
    const a = Acc{};
    try expectEqual(@as(u64, 0), a.avg());
}

test "Acc.max holds when later spans are smaller" {
    var a = Acc{};
    a.add(500);
    a.add(1);
    try expectEqual(@as(u64, 500), a.max);
}

test "spanTicks handles rdtsc wraparound via -%" {
    // A span opened just before the 64-bit counter wraps must still measure the
    // small true elapsed time, not a huge bogus one (or trap).
    const start: u64 = std.math.maxInt(u64) - 9;
    try expectEqual(@as(u64, 30), spanTicks(start, 20));
    try expectEqual(@as(u64, 0), spanTicks(start, start));
    try expectEqual(@as(u64, 7), spanTicks(100, 107));
}
