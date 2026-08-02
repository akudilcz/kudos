//! Host tests of src/drivers/net/stack/dns_wire.zig. The answer parser reads a
//! buffer any DNS server — or anything that can spoof one datagram — hands us,
//! so malformed input (truncated packets, label overruns, compression-pointer
//! games) is first-class coverage, not an afterthought.

const std = @import("std");
const dns_wire = @import("dns_wire");
const buildQuery = dns_wire.buildQuery;
const parseAnswer = dns_wire.parseAnswer;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const TXID: u16 = 0x4B55;

// A reply header for TXID with the given question/answer counts (flags QR+RD+RA).
fn hdr(comptime qd: u16, comptime an: u16) [12]u8 {
    return .{
        TXID >> 8, TXID & 0xFF,
        0x81,      0x80,
        qd >> 8,   qd & 0xFF,
        an >> 8,   an & 0xFF,
        0,         0,
        0,         0,
    };
}

// The question section for "ab.c", type A class IN.
const QUESTION = [_]u8{ 2, 'a', 'b', 1, 'c', 0, 0, 1, 0, 1 };
// An A record whose NAME is a compression pointer to the question (offset 12).
const ANSWER_A = [_]u8{ 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34 };
const ANSWER_IP = [4]u8{ 93, 184, 216, 34 };
// The straightforward well-formed reply every hostile variant below mutates.
const REPLY = hdr(1, 1) ++ QUESTION ++ ANSWER_A;

test "buildQuery: header, labels, footer" {
    var q: [512]u8 = undefined;
    const n = buildQuery(&q, TXID, "ab.c").?;
    // Header: txid, RD flag, one question, empty other counts.
    try expectEqual(@as(u8, TXID >> 8), q[0]);
    try expectEqual(@as(u8, TXID & 0xFF), q[1]);
    try expectEqual(@as(u8, dns_wire.DNS_FLAG_RD >> 8), q[2]);
    try expectEqual(@as(u8, dns_wire.DNS_FLAG_RD & 0xFF), q[3]);
    try expect(std.mem.eql(u8, &[_]u8{ 0, 1, 0, 0, 0, 0, 0, 0 }, q[4..12]));
    // Name + footer, exactly the question section an honest server echoes back.
    try expectEqual(dns_wire.DNS_HLEN + QUESTION.len, n);
    try expect(std.mem.eql(u8, &QUESTION, q[dns_wire.DNS_HLEN..n]));
}

test "buildQuery: an over-long label is refused" {
    var q: [512]u8 = undefined;
    const long = [_]u8{'a'} ** 64; // a label is at most 63 bytes
    try expect(buildQuery(&q, TXID, &long) == null);
    const max = [_]u8{'a'} ** 63;
    try expect(buildQuery(&q, TXID, &max) != null);
}

test "buildQuery: a host that would overflow the buffer is refused, not written" {
    var small: [24]u8 = undefined;
    // 20 name bytes + length byte + null + 4-byte footer > the 12 bytes left.
    try expect(buildQuery(&small, TXID, "aaaaaaaaaaaaaaaaaaaa") == null);
}

test "parseAnswer: pointer-compressed answer name yields the A record (NET-008)" {
    try expectEqual(ANSWER_IP, try parseAnswer(&REPLY, TXID));
}

test "parseAnswer: a label-sequence answer name also parses" {
    const named = [_]u8{ 2, 'a', 'b', 1, 'c', 0 } ++ ANSWER_A[2..].*;
    const r = hdr(1, 1) ++ QUESTION ++ named;
    try expectEqual(ANSWER_IP, try parseAnswer(&r, TXID));
}

test "parseAnswer: a non-A record is skipped by RDLENGTH to reach the A behind it" {
    // CNAME (type 5) with a 6-byte RDATA, then the A record.
    const cname = [_]u8{ 0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, 6, 1, 'x', 1, 'y', 1, 'z' };
    const r = hdr(1, 2) ++ QUESTION ++ cname ++ ANSWER_A;
    try expectEqual(ANSWER_IP, try parseAnswer(&r, TXID));
}

test "parseAnswer: a stale transaction id is rejected before anything is read" {
    try expectError(error.TxidMismatch, parseAnswer(&REPLY, TXID ^ 1));
}

test "regression: truncated packets must fail cleanly, never read out of bounds" {
    // Every prefix, from the empty packet to one byte short of complete: the
    // parse must return without walking past the buffer — an error, or (once
    // the A record's RDATA fits inside the prefix) the address itself.
    var cut: usize = 0;
    while (cut < REPLY.len) : (cut += 1) {
        _ = parseAnswer(REPLY[0..cut], TXID) catch |e| {
            try expect(e == error.NoARecord or e == error.TxidMismatch);
        };
    }
}

test "regression: a compression pointer aimed at itself must not loop or mislead" {
    // The answer's NAME points at ITSELF. A parser that follows pointers spins
    // forever; this one only skips the 2 pointer bytes, finds no valid A record
    // (the RDLENGTH runs past the packet), and returns cleanly.
    const self_ptr = [_]u8{ 0xC0, 12 + QUESTION.len, 0, 5, 0, 1, 0, 0, 0, 60, 0, 200 };
    const r = hdr(1, 1) ++ QUESTION ++ self_ptr;
    try expectError(error.NoARecord, parseAnswer(&r, TXID));
}

test "regression: a label length running past the end must not walk off the buffer" {
    // Answer NAME opens with a 63-byte label but the packet ends after 3 bytes.
    const r = hdr(1, 1) ++ QUESTION ++ [_]u8{ 63, 'a', 'b' };
    try expectError(error.NoARecord, parseAnswer(&r, TXID));
}

test "parseAnswer: an A record whose RDLENGTH lies (not 4) is not taken as an address" {
    const bad = comptime blk: {
        var b = REPLY;
        b[12 + QUESTION.len + 11] = 3; // type A but rdlen 3
        break :blk b;
    };
    try expectError(error.NoARecord, parseAnswer(&bad, TXID));
}
