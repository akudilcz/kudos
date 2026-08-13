//! Host tests of src/drivers/net/debug/linestore.zig — the seq-stamped,
//! retained trace-line store behind netdebug's reliable drain (DIAG-023,
//! DIAG-024).

const std = @import("std");
const linestore = @import("linestore");

// Small on purpose: wrap and overrun behaviour must be reachable in a test.
const CAP = 4;
const LINE_CAP = 40;
const S = linestore.Store(CAP, LINE_CAP);

/// The i-th newline-terminated line of a packed datagram.
fn line(pkt: []const u8, i: usize) []const u8 {
    var it = std.mem.splitScalar(u8, pkt, '\n');
    var n: usize = 0;
    while (it.next()) |l| {
        if (l.len == 0) continue;
        if (n == i) return l;
        n += 1;
    }
    return "";
}

test "a pushed line is stamped, terminated, and pending (DIAG-024)" {
    var s = S{};
    try std.testing.expectEqual(linestore.Pushed.stored, s.push("hello\n"));
    try std.testing.expectEqual(@as(usize, 1), s.pending());
    var pkt: [256]u8 = undefined;
    const f = s.fill(&pkt);
    try std.testing.expectEqual(@as(usize, 1), f.lines);
    try std.testing.expectEqualStrings("[000001] hello\n", pkt[0..f.bytes]);
}

test "fill packs multiple lines and does NOT consume them (DIAG-024)" {
    var s = S{};
    _ = s.push("a\n");
    _ = s.push("b\n");
    var pkt: [256]u8 = undefined;
    const f = s.fill(&pkt);
    try std.testing.expectEqual(@as(usize, 2), f.lines);
    // The failed-send path: nothing advanced, so the same two lines pack again,
    // byte-identical and with the same sequence numbers.
    try std.testing.expectEqual(@as(usize, 2), s.pending());
    var pkt2: [256]u8 = undefined;
    const f2 = s.fill(&pkt2);
    try std.testing.expectEqualStrings(pkt[0..f.bytes], pkt2[0..f2.bytes]);
}

test "advance consumes exactly the packed count, in order" {
    var s = S{};
    _ = s.push("a\n");
    _ = s.push("b\n");
    _ = s.push("c\n");
    var pkt: [256]u8 = undefined;
    var f = s.fill(pkt[0 .. 2 * "[000001] a\n".len]); // room for exactly two
    try std.testing.expectEqual(@as(usize, 2), f.lines);
    s.advance(f.lines);
    try std.testing.expectEqual(@as(usize, 1), s.pending());
    f = s.fill(&pkt);
    try std.testing.expectEqual(@as(usize, 1), f.lines);
    try std.testing.expectEqualStrings("[000003] c\n", pkt[0..f.bytes]);
}

test "a sent line is retained and served again by sequence number (DIAG-023)" {
    var s = S{};
    _ = s.push("a\n");
    _ = s.push("b\n");
    var pkt: [256]u8 = undefined;
    const f = s.fill(&pkt);
    s.advance(f.lines);
    try std.testing.expectEqual(@as(usize, 0), s.pending());
    // The receiver lost seq 2 on the wire and asks for it back.
    var out: [256]u8 = undefined;
    const n = s.resendInto(2, 1, &out);
    try std.testing.expectEqualStrings("[000002] b\n", out[0..n]);
    // A window covers several lines at once.
    const n2 = s.resendInto(1, 2, &out);
    try std.testing.expectEqualStrings("[000001] a\n[000002] b\n", out[0..n2]);
}

test "an expired line yields nothing — the loss is permanent and visible (DIAG-023)" {
    var s = S{};
    var i: usize = 0;
    while (i < CAP + 2) : (i += 1) {
        _ = s.push("x\n");
        var pkt: [64]u8 = undefined;
        const f = s.fill(&pkt);
        s.advance(f.lines);
    }
    // Seqs 1 and 2 were wrapped over; the newest CAP lines survive.
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), s.resendInto(1, 2, &out));
    const n = s.resendInto(CAP + 2, 1, &out);
    try std.testing.expect(n > 0);
}

test "overwriting a pending line is reported; expiring a sent one is not" {
    var s = S{};
    // Fill completely with UNSENT lines, then push one more: a real loss.
    var i: usize = 0;
    while (i < CAP) : (i += 1) try std.testing.expectEqual(linestore.Pushed.stored, s.push("p\n"));
    try std.testing.expectEqual(linestore.Pushed.dropped_pending, s.push("q\n"));
    try std.testing.expectEqual(@as(usize, CAP), s.pending());

    // Now send everything; further pushes expire RETAINED lines silently.
    var pkt: [256]u8 = undefined;
    const f = s.fill(&pkt);
    s.advance(f.lines);
    try std.testing.expectEqual(linestore.Pushed.stored, s.push("r\n"));
}

test "the sequence stamp wraps at its digit budget rather than widening" {
    var s = S{};
    s.next_seq = linestore.SEQ_MOD - 1;
    _ = s.push("last\n");
    _ = s.push("wrapped\n");
    var pkt: [256]u8 = undefined;
    const f = s.fill(&pkt);
    try std.testing.expectEqual(@as(usize, 2), f.lines);
    try std.testing.expectEqualStrings("[999999] last", line(pkt[0..f.bytes], 0));
    // 10^6 wraps to 0 — the receiver's gap detector treats the drop as a wrap.
    try std.testing.expectEqualStrings("[000000] wrapped", line(pkt[0..f.bytes], 1));
    // Resend across the wrap still finds both.
    s.advance(2);
    var out: [256]u8 = undefined;
    const n = s.resendInto(linestore.SEQ_MOD - 1, 2, &out);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "last") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "wrapped") != null);
}

test "an over-long body is truncated to its cap, stamp and newline intact" {
    var s = S{};
    const long = "x" ** (LINE_CAP * 2);
    _ = s.push(long);
    var pkt: [2 * LINE_CAP]u8 = undefined;
    const f = s.fill(&pkt);
    try std.testing.expectEqual(@as(usize, 1), f.lines);
    try std.testing.expectEqual(@as(usize, LINE_CAP), f.bytes);
    try std.testing.expect(pkt[f.bytes - 1] == '\n');
    try std.testing.expect(std.mem.startsWith(u8, pkt[0..f.bytes], "[000001] xxx"));
}

test "a datagram too small for the next line packs nothing rather than a torn line" {
    var s = S{};
    _ = s.push("a long-ish body\n");
    var tiny: [8]u8 = undefined;
    const f = s.fill(&tiny);
    try std.testing.expectEqual(@as(usize, 0), f.lines);
    try std.testing.expectEqual(@as(usize, 0), f.bytes);
    try std.testing.expectEqual(@as(usize, 1), s.pending());
}
