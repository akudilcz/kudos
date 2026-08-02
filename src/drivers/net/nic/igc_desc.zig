//! Intel I226 (igc) ADVANCED descriptor codec — pure, so it is host-tested.
//!
//! QEMU NEVER RUNS THIS CODE: the emulated NIC is an e1000, which takes the LEGACY
//! descriptor path (nic.zig picks the driver by PCI ID). So this bit layout has no
//! coverage from any emulated boot, and it fails in the worst way — netdebug is carried
//! BY this NIC, so a wrong DD bit means no packets, hence no trace, hence no way to see
//! why there is no trace.
//!
//! The encoding therefore lives here, where `zig build test` reaches it; the driver keeps
//! only the volatile load/store.

const std = @import("std");

/// An advanced descriptor: 16 bytes, four dwords. TX uses the read format; RX is
/// written back by the controller. Plain data — no volatile, no MMIO.
pub const AdvDesc = extern struct { d0: u32 = 0, d1: u32 = 0, d2: u32 = 0, d3: u32 = 0 };

// cmd_type_len (TX d2) bits — I226 datasheet §7.2.2.3 (advanced TX data descriptor).
pub const DTYP_ADV_DATA: u32 = 0x3 << 20; // descriptor type = advanced data
pub const CMD_EOP: u32 = 1 << 24; // end of packet
pub const CMD_IFCS: u32 = 1 << 25; // insert FCS/CRC
pub const CMD_RS: u32 = 1 << 27; // report status (ask for the DD write-back)
pub const CMD_DEXT: u32 = 1 << 29; // descriptor extension (0 = legacy layout)

/// PAYLEN sits at bit 14 of olinfo (TX d3), NOT at bit 0. This is the shift that,
/// when wrong, produces a card that accepts every descriptor and transmits nothing.
pub const OLINFO_PAYLEN_SHIFT: u5 = 14;

/// DD ("descriptor done") — the controller's write-back acknowledgement. It lands in
/// a DIFFERENT dword for TX than for RX, which is exactly the sort of asymmetry that
/// gets miscopied: TX status is written back into d3, RX status into d2.
pub const DD: u32 = 1 << 0;

/// Encode one TX descriptor for a `len`-byte frame at `buf_phys`.
pub fn txSet(buf_phys: u64, len: usize) AdvDesc {
    const l: u32 = @intCast(len);
    return .{
        .d0 = @truncate(buf_phys), // packet address, low
        .d1 = @truncate(buf_phys >> 32), // packet address, high
        .d2 = l | DTYP_ADV_DATA | CMD_EOP | CMD_IFCS | CMD_RS | CMD_DEXT,
        .d3 = l << OLINFO_PAYLEN_SHIFT, // olinfo: PAYLEN
    };
}

/// True once the NIC has written back this TX descriptor (DD in the writeback dword).
pub fn txDone(d: AdvDesc) bool {
    return (d.d3 & DD) != 0;
}

/// Received length if the NIC has filled this RX descriptor, else null.
pub fn rxLen(d: AdvDesc) ?usize {
    if ((d.d2 & DD) == 0) return null; // not written back yet
    return d.d3 & 0xFFFF;
}

/// Return an RX descriptor to the empty/read format pointing at `buf_phys`.
pub fn rxReset(buf_phys: u64) AdvDesc {
    return .{ .d0 = @truncate(buf_phys), .d1 = @truncate(buf_phys >> 32), .d2 = 0, .d3 = 0 };
}
