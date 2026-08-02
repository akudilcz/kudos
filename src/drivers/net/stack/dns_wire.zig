//! DNS wire codec (RFC 1035): A-record query building and answer parsing —
//! pure, so it is host-tested (`zig build test`), mirroring the dhcp/dhcp_wire
//! split. The IO (ephemeral port, send, timeout, logging) stays in udp.zig.
//!
//! parseAnswer reads a buffer any DNS server — or anything that can spoof one
//! datagram — hands us, so every step is bounded against the packet: a
//! truncated packet, a label length running off the end, or a compression
//! pointer must never walk an offset out of bounds.

const std = @import("std");
const wire = @import("wire.zig");

/// DNS header size (RFC 1035 §4.1.1): id, flags, qd/an/ns/ar counts.
pub const DNS_HLEN: usize = 12;
/// Recursion Desired bit in the header flags word (RFC 1035 §4.1.1).
pub const DNS_FLAG_RD: u16 = 0x0100;
/// QTYPE A — a host (IPv4) address record (RFC 1035 §3.2.2).
pub const QTYPE_A: u16 = 1;
/// QCLASS IN — the Internet class (RFC 1035 §3.2.4).
pub const QCLASS_IN: u16 = 1;
/// A DNS label is at most 63 bytes (RFC 1035 §2.3.4).
pub const MAX_LABEL: usize = 63;
/// The fixed resource-record header after the NAME: TYPE(2) CLASS(2) TTL(4)
/// RDLENGTH(2) (RFC 1035 §4.1.3).
const RR_FIXED: usize = 10;
/// A name byte with the top two bits set is a compression pointer, not a label
/// length (RFC 1035 §4.1.4).
const NAME_PTR_MASK: u8 = 0xC0;

/// Serialize one recursive A-record query for `host` into `buf`. Returns the
/// byte count used, or null when a label is over-long or the name (plus its
/// length byte, trailing null, and 4-byte type+class footer) would overflow
/// `buf` — the bound that keeps an over-long host from overrunning the
/// caller's buffer.
pub fn buildQuery(buf: []u8, txid: u16, host: []const u8) ?usize {
    if (buf.len < DNS_HLEN) return null;
    wire.wbe16(buf[0..2], txid);
    wire.wbe16(buf[2..4], DNS_FLAG_RD);
    wire.wbe16(buf[4..6], 1); // qdcount
    @memset(buf[6..DNS_HLEN], 0);
    var n: usize = DNS_HLEN;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |label| {
        if (label.len > MAX_LABEL or n + 1 + label.len + 5 > buf.len) return null;
        buf[n] = @intCast(label.len);
        n += 1;
        @memcpy(buf[n .. n + label.len], label);
        n += label.len;
    }
    buf[n] = 0; // root label terminates the name
    n += 1;
    wire.wbe16(buf[n..][0..2], QTYPE_A);
    n += 2;
    wire.wbe16(buf[n..][0..2], QCLASS_IN);
    n += 2;
    return n;
}

/// Why an answer yielded no address; udp.zig logs each distinctly.
pub const ParseError = error{
    /// The reply's transaction id is not the query's: on a reused local port a
    /// late/duplicate answer from a prior lookup must not be taken for this one.
    TxidMismatch,
    /// No A record in the (possibly truncated or malformed) answer sections.
    NoARecord,
};

/// Skip a NAME starting at `off`: either a compression pointer (2 bytes — the
/// pointer is never FOLLOWED, a skip needs only its size) or a run of
/// length-prefixed labels ended by the zero label. Treating a pointer byte as a
/// label length would misparse the sections that follow from an
/// attacker-chosen offset. Every step is bounded by `r.len`; the returned
/// offset may sit past the buffer — the caller re-validates before reading.
fn skipName(r: []const u8, start: usize) usize {
    var off = start;
    if (off < r.len and r[off] & NAME_PTR_MASK == NAME_PTR_MASK) return off + 2;
    while (off < r.len and r[off] != 0) off += @as(usize, r[off]) + 1;
    return off + 1; // the zero label
}

/// Walk a DNS reply for the first A record: match the transaction id, skip the
/// question section, then scan the answers. Bounded at every step — malformed
/// input yields an error, never an out-of-bounds read.
pub fn parseAnswer(r: []const u8, txid: u16) ParseError![4]u8 {
    if (r.len < DNS_HLEN) return error.NoARecord;
    if (wire.rbe16(r[0..2]) != txid) return error.TxidMismatch;
    const qd = wire.rbe16(r[4..6]);
    const an = wire.rbe16(r[6..8]);
    var off: usize = DNS_HLEN;
    var i: usize = 0;
    // Question entries: NAME then QTYPE(2) + QCLASS(2).
    while (i < qd and off < r.len) : (i += 1) {
        off = skipName(r, off);
        off += 4; // qtype + qclass
    }
    i = 0;
    while (i < an and off < r.len) : (i += 1) {
        off = skipName(r, off);
        // Re-validate AFTER the name skip, before reading the fixed RR header —
        // the loop-top check alone does not cover how far the name advanced `off`.
        if (off + RR_FIXED > r.len) break;
        const atype = wire.rbe16(r[off..][0..2]);
        const rdlen = wire.rbe16(r[off + 8 ..][0..2]);
        off += RR_FIXED;
        if (atype == QTYPE_A and rdlen == 4 and off + 4 <= r.len) {
            return r[off..][0..4].*;
        }
        off += rdlen;
    }
    return error.NoARecord;
}
