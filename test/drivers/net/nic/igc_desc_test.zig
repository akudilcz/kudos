//! Host tests of src/drivers/net/nic/igc_desc.zig.

const std = @import("std");
const igc_desc = @import("igc_desc");
const AdvDesc = igc_desc.AdvDesc;
const CMD_DEXT = igc_desc.CMD_DEXT;
const CMD_EOP = igc_desc.CMD_EOP;
const CMD_IFCS = igc_desc.CMD_IFCS;
const CMD_RS = igc_desc.CMD_RS;
const DD = igc_desc.DD;
const DTYP_ADV_DATA = igc_desc.DTYP_ADV_DATA;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const rxLen = igc_desc.rxLen;
const rxReset = igc_desc.rxReset;
const txDone = igc_desc.txDone;
const txSet = igc_desc.txSet;

test "TX descriptor: the exact wire encoding for a frame" {
    const d = txSet(0x1234_5678_9ABC, 60);

    try expectEqual(@as(u32, 0x5678_9ABC), d.d0); // address split lo/hi
    try expectEqual(@as(u32, 0x0000_1234), d.d1);

    // cmd_type_len: length in the low bits, then the four command bits + DTYP.
    try expectEqual(@as(u32, 60), d.d2 & 0xFFFF);
    try expect(d.d2 & DTYP_ADV_DATA == DTYP_ADV_DATA); // advanced, not legacy
    try expect(d.d2 & CMD_EOP != 0);
    try expect(d.d2 & CMD_IFCS != 0); // the NIC appends the CRC; without this the
    //                                   frame is 4 bytes short and every peer drops it
    try expect(d.d2 & CMD_RS != 0); // ask for the write-back, or txDone NEVER fires
    try expect(d.d2 & CMD_DEXT != 0); // clear DEXT and the card reads this as a
    //                                   LEGACY descriptor: the fields mean other things

    // PAYLEN is at bit 14. At bit 0 it would collide with the length field and the
    // card transmits nothing while acknowledging everything.
    try expectEqual(@as(u32, 60 << 14), d.d3);
    try expectEqual(@as(u32, 60), d.d3 >> 14);
}

test "regression: TX DD is in d3, RX DD is in d2 — they are NOT the same dword" {
    // The asymmetry that invites a copy-paste bug. Reading TX's DD from d2 makes the
    // driver believe a descriptor is done the instant it is queued; reading RX's from
    // d3 means it never sees a packet arrive.
    var tx = txSet(0x1000, 64);
    try expect(!txDone(tx)); // freshly encoded: not yet written back
    tx.d3 |= DD; // the NIC writes back HERE for TX
    try expect(txDone(tx));

    var rx = rxReset(0x2000);
    try expectEqual(@as(?usize, null), rxLen(rx)); // freshly armed: nothing yet
    rx.d2 |= DD; // the NIC writes back HERE for RX
    rx.d3 = 1514;
    try expectEqual(@as(?usize, 1514), rxLen(rx));

    // Setting DD in the WRONG dword must not fool either side.
    var tx_bad = txSet(0x1000, 64);
    tx_bad.d2 |= DD;
    try expect(!txDone(tx_bad));
    var rx_bad = rxReset(0x2000);
    rx_bad.d3 = 1514 | DD;
    try expectEqual(@as(?usize, null), rxLen(rx_bad));
}

test "RX length is the low 16 bits only — the status bits above it are not length" {
    var rx = rxReset(0x2000);
    rx.d2 = DD;
    rx.d3 = 0xDEAD_05DC; // upper half is status/vlan; 0x05DC = 1500
    try expectEqual(@as(?usize, 1500), rxLen(rx));
}

test "rxReset re-arms the descriptor: address restored, status cleared" {
    // A descriptor handed back to the NIC with a stale DD still set would be read as
    // "already full" and the ring would wedge instantly.
    var rx = AdvDesc{ .d0 = 0xFFFF, .d1 = 0xFFFF, .d2 = DD, .d3 = 1514 };
    rx = rxReset(0x1_0000_2000);
    try expectEqual(@as(u32, 0x0000_2000), rx.d0);
    try expectEqual(@as(u32, 0x0000_0001), rx.d1);
    try expectEqual(@as(?usize, null), rxLen(rx)); // status genuinely cleared
}

test "a 64-bit DMA address splits across d0/d1 without truncation" {
    const d = txSet(0xFFFF_FFFF_FFFF_F000, 1514);
    try expectEqual(@as(u32, 0xFFFF_F000), d.d0);
    try expectEqual(@as(u32, 0xFFFF_FFFF), d.d1);
    const back = (@as(u64, d.d1) << 32) | d.d0;
    try expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_F000), back);
}
