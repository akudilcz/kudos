//! Host tests of src/drivers/net/stack/tcp_seg.zig — outbound segment sizing,
//! RTO backoff, and wraparound-safe ACK coverage.

const std = @import("std");
const seg = @import("tcp_seg");

test "nextSegment is bounded by cap, mss, window, and remaining" {
    // remaining is the limit
    try std.testing.expectEqual(@as(usize, 100), seg.nextSegment(100, 1460, 1460, 8192));
    // mss is the limit
    try std.testing.expectEqual(@as(usize, 536), seg.nextSegment(10000, 1460, 536, 8192));
    // window is the limit
    try std.testing.expectEqual(@as(usize, 200), seg.nextSegment(10000, 1460, 1460, 200));
    // cap is the limit
    try std.testing.expectEqual(@as(usize, 1460), seg.nextSegment(10000, 1460, 9000, 60000));
    // closed window -> nothing
    try std.testing.expectEqual(@as(usize, 0), seg.nextSegment(10000, 1460, 1460, 0));
}

test "rtoMs doubles per retry and caps" {
    try std.testing.expectEqual(@as(u32, 300), seg.rtoMs(0, 300, 3000));
    try std.testing.expectEqual(@as(u32, 600), seg.rtoMs(1, 300, 3000));
    try std.testing.expectEqual(@as(u32, 1200), seg.rtoMs(2, 300, 3000));
    try std.testing.expectEqual(@as(u32, 2400), seg.rtoMs(3, 300, 3000));
    try std.testing.expectEqual(@as(u32, 3000), seg.rtoMs(4, 300, 3000)); // capped
    try std.testing.expectEqual(@as(u32, 3000), seg.rtoMs(10, 300, 3000));
}

test "shouldGiveUp at the retry limit" {
    try std.testing.expect(!seg.shouldGiveUp(4, 5));
    try std.testing.expect(seg.shouldGiveUp(5, 5));
    try std.testing.expect(seg.shouldGiveUp(6, 5));
}

test "ackCoversAll / ackAdvances without wraparound" {
    // una=1000, sent 500 bytes -> nxt=1500
    try std.testing.expect(seg.ackCoversAll(1000, 1500, 1500));
    try std.testing.expect(!seg.ackCoversAll(1000, 1400, 1500));
    try std.testing.expect(seg.ackAdvances(1000, 1400, 1500)); // partial ack advances
    try std.testing.expect(!seg.ackAdvances(1000, 1000, 1500)); // dup ack
}

test "ack math is correct across the u32 wrap" {
    // una near the top of the sequence space; nxt wraps past 0.
    const una: u32 = 0xFFFF_FF00;
    const nxt: u32 = una +% 512; // = 0x0000_0100
    try std.testing.expect(seg.ackCoversAll(una, nxt, nxt));
    try std.testing.expect(seg.ackAdvances(una, una +% 200, nxt));
    try std.testing.expect(!seg.ackAdvances(una, una, nxt));
    // a stale ack from before una must NOT look like progress
    try std.testing.expect(!seg.ackAdvances(una, una -% 50, nxt));
    try std.testing.expect(!seg.ackCoversAll(una, una -% 50, nxt));
}
