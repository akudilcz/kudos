//! The client's outbound send engine: turn a byte stream into TCP segments,
//! keep them within the peer's advertised window, and retransmit what the peer
//! never acknowledges. A go-back-N sender over a `Transport` seam that emits one
//! segment, with the current time passed in — so the whole loss/recovery
//! behaviour is host-tested against a fake transport, withholding ACKs to model
//! loss, with no NIC and no real packet loss in the loop (test/drivers/net/stack/tcp_tx_test.zig).
//! tcp.zig wires the real transport (net.sendIp), passes the millisecond timer,
//! and feeds peer ACKs in.
//!
//! Go-back-N, not stop-and-wait: multiple segments may be in flight up to the
//! window, and a timeout rewinds the send pointer to the oldest unacknowledged
//! byte and resends from there. The pure sequence/segment/backoff math lives in
//! `tcp_seg.zig`; this module is only the state machine that drives it.

const std = @import("std");
const tcp_seg = @import("tcp_seg.zig");

/// Largest payload one segment may carry. Bounds the IP packet to the 1500-byte
/// Ethernet MTU (1500 − 20 IPv4 − 20 TCP), independent of the peer's MSS, so a
/// segment never needs IP fragmentation. The peer's MSS bounds it further.
pub const MAX_SEG_BYTES: usize = 1460;
/// The MSS assumed when the peer's SYN carried no MSS option (RFC 9293 default).
pub const DEFAULT_MSS: u16 = 536;
/// Retransmit backoff: first timeout at BASE, doubling to MAX.
pub const RTO_BASE_MS: u32 = 500;
pub const RTO_MAX_MS: u32 = 8000;
/// Retransmits of the same data before the connection is declared dead.
pub const MAX_TRIES: u32 = 8;

fn rtoFor(tries: u32) u64 {
    return tcp_seg.rtoMs(tries, RTO_BASE_MS, RTO_MAX_MS);
}

/// Emit one segment on the wire. `seq` is the absolute sequence of `data[0]`.
/// Returns false if it cannot be sent right now (next hop unresolved) — the
/// sender leaves the bytes unsent and tries again on a later step.
pub const Transport = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, seq: u32, data: []const u8) bool,
};

pub const Progress = enum { sending, done, failed };

/// One outbound stream in flight. `data` is borrowed for the sender's lifetime
/// (the caller holds the request/body until the send completes).
pub const Sender = struct {
    data: []const u8,
    base_seq: u32,
    peer_mss: u16,
    peer_window: u16,
    una: usize = 0, // bytes acknowledged (offset into data)
    nxt: usize = 0, // bytes sent (offset into data)
    tries: u32 = 0,
    armed: bool = false, // is the retransmit timer running (data in flight)?
    deadline_ms: u64 = 0,

    /// A stream of `data` whose first byte carries sequence `base_seq`, sized to
    /// the peer's MSS and initial receive window (from the SYN-ACK).
    pub fn init(data: []const u8, base_seq: u32, peer_mss: u16, peer_window: u16) Sender {
        return .{
            .data = data,
            .base_seq = base_seq,
            .peer_mss = if (peer_mss == 0) DEFAULT_MSS else peer_mss,
            .peer_window = peer_window,
        };
    }

    /// Absolute sequence one past the last byte to send (what a full ACK equals).
    pub fn endSeq(self: Sender) u32 {
        return self.base_seq +% @as(u32, @intCast(self.data.len));
    }

    /// Fold in a peer ACK (with its advertised window). Advances the window base
    /// on new acknowledgement, resets the retransmit count, and re-arms the timer
    /// for whatever is still in flight. Stale/duplicate/over-ACKs are ignored
    /// (wrap-safe via tcp_seg.ackAdvances).
    pub fn onAck(self: *Sender, ack: u32, window: u16, now: u64) void {
        self.peer_window = window;
        const snd_una = self.base_seq +% @as(u32, @intCast(self.una));
        const snd_nxt = self.base_seq +% @as(u32, @intCast(self.nxt));
        if (!tcp_seg.ackAdvances(snd_una, ack, snd_nxt)) return;
        self.una += ack -% snd_una;
        self.tries = 0;
        if (self.nxt > self.una) {
            self.armed = true;
            self.deadline_ms = now +% rtoFor(self.tries);
        } else {
            self.armed = false;
        }
    }

    /// Advance the send: retransmit a timed-out window (go-back-N), then emit any
    /// new segments the window allows. Returns done once everything is
    /// acknowledged, failed once the retransmit budget is spent.
    pub fn step(self: *Sender, now: u64, t: Transport) Progress {
        if (self.una >= self.data.len) return .done;

        // The oldest in-flight segment timed out: rewind to the first unacked
        // byte and resend the window from there.
        if (self.armed and now >= self.deadline_ms) {
            if (tcp_seg.shouldGiveUp(self.tries, MAX_TRIES)) return .failed;
            self.tries += 1;
            self.nxt = self.una;
            self.armed = false;
            // PERSIST PROBE: the timer fired against a CLOSED window, not lost
            // data. The window-update ACK is the one segment TCP never
            // retransmits, so with nothing in flight this sender must ask —
            // one byte past the window. Any ACK it provokes re-reports the
            // peer's window (onAck stores it before the advance check), and a
            // peer that stays closed meets the same MAX_TRIES budget above.
            if (self.peer_window == 0 and self.una < self.data.len) {
                if (t.emit(t.ctx, self.base_seq +% @as(u32, @intCast(self.nxt)), self.data[self.nxt..][0..1]))
                    self.nxt += 1;
                self.armed = true;
                self.deadline_ms = now +% rtoFor(self.tries);
                return .sending;
            }
        }

        while (self.nxt < self.data.len) {
            const remaining = self.data.len - self.nxt;
            const inflight = self.nxt - self.una;
            if (inflight >= self.peer_window) {
                // Window full — wait for an ACK. CLOSED (zero) window with
                // nothing in flight is the dangerous case: no retransmission
                // will provoke the peer, so arm the persist timer and let the
                // probe above ask for the window (a lost window-update ACK
                // otherwise stalls the transfer forever).
                if (inflight == 0 and !self.armed) {
                    self.armed = true;
                    self.deadline_ms = now +% rtoFor(self.tries);
                }
                break;
            }
            const room: u16 = @intCast(@as(usize, self.peer_window) - inflight);
            const seg = tcp_seg.nextSegment(remaining, MAX_SEG_BYTES, self.peer_mss, room);
            if (seg == 0) {
                // Zero window. Arm the persist timer if nothing is in flight:
                // an idle sender has no retransmission to provoke the peer
                // with, so without this the probe above never fires and a lost
                // window update stalls the transfer forever.
                if (!self.armed) {
                    self.armed = true;
                    self.deadline_ms = now +% rtoFor(self.tries);
                }
                break;
            }
            if (!t.emit(t.ctx, self.base_seq +% @as(u32, @intCast(self.nxt)), self.data[self.nxt .. self.nxt + seg]))
                break; // no route right now — retry on a later step
            self.nxt += seg;
            if (!self.armed) {
                self.armed = true;
                self.deadline_ms = now +% rtoFor(self.tries);
            }
        }
        return if (self.una >= self.data.len) .done else .sending;
    }
};
