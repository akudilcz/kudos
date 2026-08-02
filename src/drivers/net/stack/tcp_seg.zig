//! Pure TCP send-path math for the in-kernel client's outbound segmentation and
//! stop-and-wait retransmission: how big the next segment may be, the
//! retransmit backoff schedule, and the wraparound-safe test for whether an ACK
//! covers outstanding data. These are the exact places a u32 sequence-number
//! wrap or an off-by-one bites, so they live here, host-tested, apart from the
//! socket code.

const std = @import("std");

/// Largest payload the next outbound segment may carry: bounded by our segment
/// cap, the peer's MSS, and the peer's currently advertised receive window, and
/// never more than what remains to send. Zero means "cannot send now" (the
/// window is closed), which the caller turns into a persist wait.
pub fn nextSegment(remaining: usize, max_seg: usize, peer_mss: u16, peer_window: u16) usize {
    const by_mss = @min(max_seg, @as(usize, peer_mss));
    const by_win = @min(by_mss, @as(usize, peer_window));
    return @min(by_win, remaining);
}

/// Retransmit timeout for attempt `tries` (0 = first send): exponential backoff
/// from `base_ms`, doubling each retry, capped at `max_ms`.
pub fn rtoMs(tries: u32, base_ms: u32, max_ms: u32) u32 {
    var v: u64 = base_ms;
    var n = tries;
    while (n != 0) : (n -= 1) {
        v *= 2;
        if (v >= max_ms) return max_ms;
    }
    return @intCast(@min(v, max_ms));
}

/// True once we have retried enough that the connection should be declared dead.
pub fn shouldGiveUp(tries: u32, max_tries: u32) bool {
    return tries >= max_tries;
}

/// Wraparound-safe: does `ack` acknowledge everything up to `snd_nxt`, given the
/// oldest unacknowledged byte `snd_una`? TCP sequence numbers are mod 2^32, so
/// this compares unsigned distances from `snd_una`, never raw `<=`. All
/// outstanding data is covered exactly when `ack == snd_nxt`.
pub fn ackCoversAll(snd_una: u32, ack: u32, snd_nxt: u32) bool {
    return (ack -% snd_una) == (snd_nxt -% snd_una);
}

/// True if `ack` acknowledges new data — advances past `snd_una` without
/// claiming anything beyond `snd_nxt` (a stale or duplicate ACK is false).
pub fn ackAdvances(snd_una: u32, ack: u32, snd_nxt: u32) bool {
    const acked = ack -% snd_una;
    return acked != 0 and acked <= (snd_nxt -% snd_una);
}
