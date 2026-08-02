//! Host tests for src/drivers/net/stack/tcp_tx.zig — the client's go-back-N send
//! engine. A fake transport records every emitted segment; loss is modelled by
//! simply withholding the ACK for a segment and letting the retransmit timer
//! fire, so the whole retransmit/flow-control behaviour is proven with no NIC and
//! no real packet loss.

const std = @import("std");
const tcp_tx = @import("tcp_tx");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Seg = struct { seq: u32, len: usize };

/// Records each emitted segment. `fail_route` makes emit() report "no route" so
/// the sender leaves the bytes unsent (never records) and retries later.
const Fake = struct {
    segs: [128]Seg = undefined,
    n: usize = 0,
    fail_route: bool = false,

    fn emit(ctx: *anyopaque, seq: u32, data: []const u8) bool {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.fail_route) return false;
        self.segs[self.n] = .{ .seq = seq, .len = data.len };
        self.n += 1;
        return true;
    }

    fn transport(self: *Fake) tcp_tx.Transport {
        return .{ .ctx = self, .emit = emit };
    }

    fn totalBytes(self: Fake) usize {
        var s: usize = 0;
        for (self.segs[0..self.n]) |seg| s += seg.len;
        return s;
    }
};

const BASE: u32 = 0x1000;
const BIG_WIN: u16 = 0xFFFF;

test "a stream that fits one segment: emitted once, done after its ACK" {
    var fake = Fake{};
    var s = tcp_tx.Sender.init("hello", BASE, 1460, BIG_WIN);
    try expectEqual(tcp_tx.Progress.sending, s.step(0, fake.transport()));
    try expectEqual(@as(usize, 1), fake.n);
    try expectEqual(BASE, fake.segs[0].seq);
    try expectEqual(@as(usize, 5), fake.segs[0].len);
    // Peer acks all five bytes → done, nothing more emitted.
    s.onAck(BASE +% 5, BIG_WIN, 1);
    try expectEqual(tcp_tx.Progress.done, s.step(1, fake.transport()));
    try expectEqual(@as(usize, 1), fake.n);
}

test "a large stream is split into MSS-sized segments covering every byte (NET-003)" {
    var fake = Fake{};
    const data = [_]u8{0xAB} ** 4000;
    var s = tcp_tx.Sender.init(&data, BASE, 1460, BIG_WIN);
    _ = s.step(0, fake.transport());
    // 4000 bytes over a 1460 MSS = 1460 + 1460 + 1080.
    try expectEqual(@as(usize, 3), fake.n);
    try expectEqual(@as(usize, 1460), fake.segs[0].len);
    try expectEqual(@as(usize, 1460), fake.segs[1].len);
    try expectEqual(@as(usize, 1080), fake.segs[2].len);
    try expectEqual(@as(usize, 4000), fake.totalBytes());
    // Sequence numbers are contiguous.
    try expectEqual(BASE, fake.segs[0].seq);
    try expectEqual(BASE +% 1460, fake.segs[1].seq);
    try expectEqual(BASE +% 2920, fake.segs[2].seq);
}

test "flow control: never more than the peer's window is in flight" {
    var fake = Fake{};
    const data = [_]u8{0xCD} ** 4000;
    var s = tcp_tx.Sender.init(&data, BASE, 1460, 2000); // 2000-byte window
    _ = s.step(0, fake.transport());
    // At most 2000 bytes unacked: 1460 + 540, then the window is full.
    try expectEqual(@as(usize, 2000), fake.totalBytes());
    const before = fake.n;
    // A step with no ACK sends nothing more (window still full).
    _ = s.step(1, fake.transport());
    try expectEqual(before, fake.n);
    // The peer acks the first 1460 and keeps the window open → the rest flows.
    s.onAck(BASE +% 1460, 2000, 2);
    _ = s.step(2, fake.transport());
    try expect(fake.totalBytes() > 2000);
}

test "a segment the peer never ACKs is retransmitted after the RTO" {
    var fake = Fake{};
    var s = tcp_tx.Sender.init("retransmit-me", BASE, 1460, BIG_WIN);
    _ = s.step(0, fake.transport()); // emitted once at t=0
    try expectEqual(@as(usize, 1), fake.n);
    // No ACK. Before the RTO nothing happens.
    _ = s.step(tcp_tx.RTO_BASE_MS - 1, fake.transport());
    try expectEqual(@as(usize, 1), fake.n);
    // At the RTO the same bytes are resent (go-back-N from the unacked base).
    _ = s.step(tcp_tx.RTO_BASE_MS, fake.transport());
    try expectEqual(@as(usize, 2), fake.n);
    try expectEqual(fake.segs[0].seq, fake.segs[1].seq);
    try expectEqual(fake.segs[0].len, fake.segs[1].len);
    // The retransmission is finally acked → done.
    s.onAck(s.endSeq(), BIG_WIN, tcp_tx.RTO_BASE_MS);
    try expectEqual(tcp_tx.Progress.done, s.step(tcp_tx.RTO_BASE_MS + 1, fake.transport()));
}

test "after MAX_TRIES unacknowledged retransmits the sender declares failure" {
    var fake = Fake{};
    var s = tcp_tx.Sender.init("dead-peer", BASE, 1460, BIG_WIN);
    var now: u64 = 0;
    var result = s.step(now, fake.transport());
    // Drive the RTO backoff to exhaustion without ever acking.
    var guard: u32 = 0;
    while (result == .sending and guard < 100) : (guard += 1) {
        now += tcp_tx.RTO_MAX_MS; // jump past whatever the current backoff is
        result = s.step(now, fake.transport());
    }
    try expectEqual(tcp_tx.Progress.failed, result);
}

test "a closed (zero) window persists: nothing is sent until it reopens" {
    var fake = Fake{};
    const data = [_]u8{0xEE} ** 100;
    var s = tcp_tx.Sender.init(&data, BASE, 1460, 0); // window closed
    try expectEqual(tcp_tx.Progress.sending, s.step(0, fake.transport()));
    try expectEqual(@as(usize, 0), fake.n); // nothing sent into a zero window
    // A duplicate ACK that opens the window lets data flow.
    s.onAck(BASE, 100, 1);
    _ = s.step(1, fake.transport());
    try expectEqual(@as(usize, 100), fake.totalBytes());
}

test "no route: the segment is held and sent once the route resolves" {
    var fake = Fake{ .fail_route = true };
    var s = tcp_tx.Sender.init("later", BASE, 1460, BIG_WIN);
    _ = s.step(0, fake.transport());
    try expectEqual(@as(usize, 0), fake.n); // emit refused, nothing recorded or advanced
    fake.fail_route = false;
    _ = s.step(1, fake.transport());
    try expectEqual(@as(usize, 1), fake.n);
    try expectEqual(BASE, fake.segs[0].seq);
}

test "sequence math is wrap-safe when the stream straddles the u32 boundary" {
    var fake = Fake{};
    const base: u32 = 0xFFFF_FFF0; // 16 bytes below the wrap
    const data = [_]u8{0x5A} ** 40; // spans past 0xFFFFFFFF
    var s = tcp_tx.Sender.init(&data, base, 1460, BIG_WIN);
    _ = s.step(0, fake.transport());
    try expectEqual(@as(usize, 40), fake.totalBytes());
    // A wrapped ACK for the whole stream (base + 40 wraps to 0x18) still completes.
    try expectEqual(@as(u32, 0x18), s.endSeq());
    s.onAck(s.endSeq(), BIG_WIN, 1);
    try expectEqual(tcp_tx.Progress.done, s.step(1, fake.transport()));
}

test "a partial ACK advances the window base and only the rest is retransmitted" {
    var fake = Fake{};
    const data = [_]u8{0x11} ** 3000; // 1460 + 1460 + 80
    var s = tcp_tx.Sender.init(&data, BASE, 1460, BIG_WIN);
    _ = s.step(0, fake.transport()); // 3 segments in flight
    try expectEqual(@as(usize, 3), fake.n);
    // Peer acks only the first segment.
    s.onAck(BASE +% 1460, BIG_WIN, 1);
    // Time out the remaining in-flight data: go-back-N resends from byte 1460 on,
    // i.e. 1540 bytes, NOT the acked first segment.
    const n_before = fake.n;
    _ = s.step(tcp_tx.RTO_BASE_MS + 1, fake.transport());
    var resent: usize = 0;
    for (fake.segs[n_before..fake.n]) |seg| resent += seg.len;
    try expectEqual(@as(usize, 1540), resent);
    try expectEqual(BASE +% 1460, fake.segs[n_before].seq);
}
