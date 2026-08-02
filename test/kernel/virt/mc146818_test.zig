//! Host tests of src/kernel/virt/mc146818.zig — the clock a guest reads at boot.
//! The property that decides whether a guest boots at all is the first one
//! tested: the update-in-progress bit must read CLEAR. Linux waits on it in an
//! unbounded loop with interrupts off, so a set bit is not a wrong clock, it is a
//! guest that never gets past its interrupt setup.

const std = @import("std");
const cmos = @import("guestcmos");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// The instant the clock is asked about: 2026-07-25 18:04:05 UTC, a Saturday.
/// The device does no calendar arithmetic, so the weekday is the caller's fact.
const WHEN = cmos.Time{
    .second = 5,
    .minute = 4,
    .hour = 18,
    .weekday = 7,
    .day = 25,
    .month = 7,
    .year = 2026,
};

/// Read register `reg` the way a guest does — index port, then data port.
fn readReg(c: *cmos.Cmos, reg: u8, now: cmos.Time) u8 {
    c.ioWrite(cmos.INDEX_PORT, reg);
    return c.ioRead(cmos.DATA_PORT, now);
}

test "the update-in-progress bit reads clear, so a guest's wait loop ends" {
    var c = cmos.Cmos{};
    const status_a = readReg(&c, 0x0A, WHEN);
    try expectEqual(@as(u8, 0), status_a & cmos.STATUS_A_UIP);
    // …and the time base reads as the 32.768 kHz divider every PC uses, so the
    // guest does not conclude the clock is stopped.
    try expectEqual(cmos.STATUS_A_DIVIDER_32KHZ, status_a);
}

test "the time and date registers read back in BCD, 24-hour" {
    var c = cmos.Cmos{};
    try expectEqual(@as(u8, 0x05), readReg(&c, 0x00, WHEN)); // seconds
    try expectEqual(@as(u8, 0x04), readReg(&c, 0x02, WHEN)); // minutes
    try expectEqual(@as(u8, 0x18), readReg(&c, 0x04, WHEN)); // hours, not 6 PM
    try expectEqual(@as(u8, 0x25), readReg(&c, 0x07, WHEN)); // day of month
    try expectEqual(@as(u8, 0x07), readReg(&c, 0x08, WHEN)); // month
    try expectEqual(@as(u8, 0x26), readReg(&c, 0x09, WHEN)); // year, two digits
    try expectEqual(@as(u8, 0x20), readReg(&c, 0x32, WHEN)); // century
    try expectEqual(@as(u8, 7), readReg(&c, 0x06, WHEN)); // Saturday, 1 = Sunday
}

test "status B says 24-hour BCD, which is how the registers are actually encoded" {
    var c = cmos.Cmos{};
    const status_b = readReg(&c, 0x0B, WHEN);
    // A guest reads this to decide how to interpret every register above. If it
    // ever disagreed with the encoding, the guest's clock would be silently
    // wrong rather than obviously broken.
    try expect(status_b & cmos.STATUS_B_24H != 0);
    try expectEqual(@as(u8, 0), status_b & cmos.STATUS_B_BINARY);
}

test "status D reports valid RAM and a good battery" {
    var c = cmos.Cmos{};
    // Without it Linux's rtc_cmos driver calls the clock "broken or not
    // accessible" and registers no /dev/rtc0.
    try expectEqual(cmos.STATUS_D_VALID, readReg(&c, 0x0D, WHEN) & cmos.STATUS_D_VALID);
}

test "each register reads the instant it is asked about, not a stored one" {
    var c = cmos.Cmos{};
    var later = WHEN;
    later.second = 6;
    try expectEqual(@as(u8, 0x05), readReg(&c, 0x00, WHEN));
    try expectEqual(@as(u8, 0x06), readReg(&c, 0x00, later));
}

test "a BCD digit carry crosses the nibble boundary" {
    var c = cmos.Cmos{};
    var t = WHEN;
    t.second = 9;
    try expectEqual(@as(u8, 0x09), readReg(&c, 0x00, t));
    t.second = 10;
    try expectEqual(@as(u8, 0x10), readReg(&c, 0x00, t)); // not 0x0A
    t.second = 59;
    try expectEqual(@as(u8, 0x59), readReg(&c, 0x00, t));
}

test "a guest write to a time register does not change what the clock reports" {
    var c = cmos.Cmos{};
    c.ioWrite(cmos.INDEX_PORT, 0x00);
    c.ioWrite(cmos.DATA_PORT, 0x59);
    try expectEqual(@as(u8, 0x05), readReg(&c, 0x00, WHEN));
}

test "a guest write to status B is remembered, because the guest reads it back" {
    var c = cmos.Cmos{};
    c.ioWrite(cmos.INDEX_PORT, 0x0B);
    c.ioWrite(cmos.DATA_PORT, cmos.STATUS_B_24H | 0x40); // enable periodic interrupts
    try expectEqual(cmos.STATUS_B_24H | 0x40, readReg(&c, 0x0B, WHEN));
}

test "CMOS RAM behind the clock registers holds what a guest writes" {
    var c = cmos.Cmos{};
    c.ioWrite(cmos.INDEX_PORT, 0x40);
    c.ioWrite(cmos.DATA_PORT, 0xA5);
    try expectEqual(@as(u8, 0xA5), readReg(&c, 0x40, WHEN));
    // An untouched byte is zero, not all-ones: "no floppy, no PS/2 mouse".
    try expectEqual(@as(u8, 0), readReg(&c, 0x41, WHEN));
}

test "the index port ignores the NMI-disable bit a PC sends with it" {
    var c = cmos.Cmos{};
    c.ioWrite(cmos.INDEX_PORT, 0x40);
    c.ioWrite(cmos.DATA_PORT, 0x5A);
    // 0x80 | 0x40: Linux's CMOS_READ sets bit 7 to mask NMI. It must select the
    // same register, or every read after the first lands somewhere else.
    c.ioWrite(cmos.INDEX_PORT, 0x80 | 0x40);
    try expectEqual(@as(u8, 0x5A), c.ioRead(cmos.DATA_PORT, WHEN));
}

test "only the two CMOS ports are claimed" {
    try expect(cmos.Cmos.owns(0x70));
    try expect(cmos.Cmos.owns(0x71));
    try expect(!cmos.Cmos.owns(0x6F));
    try expect(!cmos.Cmos.owns(0x72));
    // The 8254 next door must keep its own ports.
    try expect(!cmos.Cmos.owns(0x43));
}

test "the epoch reads as 1970, the fallback a clockless host produces" {
    var c = cmos.Cmos{};
    const epoch = cmos.Time{ .second = 0, .minute = 0, .hour = 0, .weekday = 5, .day = 1, .month = 1, .year = 1970 };
    try expectEqual(@as(u8, 0x70), readReg(&c, 0x09, epoch)); // year 70
    try expectEqual(@as(u8, 0x19), readReg(&c, 0x32, epoch)); // century 19
    // A guest that decodes this gets 1970 — a wrong clock, but a booting one.
    try expectEqual(@as(u8, 0x01), readReg(&c, 0x08, epoch));
    try expectEqual(@as(u8, 0x01), readReg(&c, 0x07, epoch));
}
