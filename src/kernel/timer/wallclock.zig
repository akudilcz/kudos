//! Wall-clock time — the platform CMOS real-time clock (RTC), read ONCE at
//! boot, then advanced by the tick timer. Nothing here re-reads the hardware
//! after init: the RTC is battery-backed calendar time with one-second
//! resolution, and one clean read plus the monotonic tick base is drift-free
//! at the scale a desktop clock needs. The RTC is taken as UTC; certificate
//! validity (NET-011/NET-015) compares against the epoch seconds kept here.
//!
//! The read follows the MC146818 contract: wait out an in-progress update
//! (status A UIP bit), read twice, and accept only two identical consecutive
//! snapshots — a torn read across a rollover otherwise yields e.g. 09:59:59 →
//! 09:00:00. The stable-read policy and all numeric decode rules (BCD,
//! 12/24-hour, century) live in the pure, host-tested rtc_decode.zig; this
//! file owns only the port IO under them.

const std = @import("std");
const io = @import("../../drivers/io/io.zig");
const timer = @import("timer.zig");
const klog = @import("../debug/klog.zig");
const rtc_decode = @import("rtc_decode.zig");

// CMOS access ports (MC146818): write the register index to INDEX (bit 7 set
// keeps NMI disabled state unchanged — we leave NMI alone), read DATA.
const CMOS_INDEX: u16 = 0x70;
const CMOS_DATA: u16 = 0x71;

// RTC register indices, as the MC146818 datasheet numbers them.
const REG_SECONDS: u8 = 0x00;
const REG_MINUTES: u8 = 0x02;
const REG_HOURS: u8 = 0x04;
const REG_DAY_OF_MONTH: u8 = 0x07;
const REG_MONTH: u8 = 0x08;
const REG_YEAR: u8 = 0x09;
const REG_STATUS_A: u8 = 0x0A;
const REG_STATUS_B: u8 = 0x0B;
/// The ACPI-era century register. Not part of the MC146818 itself; reads 0 on
/// platforms without it, which rtc_decode treats as "derive from the year".
const REG_CENTURY: u8 = 0x32;

const STATUS_A_UIP: u8 = 0x80; // update in progress: registers unstable

/// Retries for a stable (UIP-clear, twice-identical) snapshot. Each UIP wait
/// is bounded by the RTC's own update cycle (~2 ms); 10 attempts is orders of
/// magnitude beyond what a healthy RTC needs, and a broken one fails loudly.
const READ_ATTEMPTS: u8 = 10;

const SECONDS_PER_DAY: u64 = 24 * 60 * 60;

/// Unix epoch seconds at the moment `init` ran, or null when no stable RTC
/// read was possible. Consumers must handle null — a dead clock face labelled
/// "no RTC", or a refused HTTPS connection (NET-015), beats fake time.
var epoch_base: ?i64 = null;
/// The tick-timer reading (`timer.millis()`) taken with `epoch_base`.
var base_ms: u64 = 0;

fn readReg(reg: u8) u8 {
    io.outb(CMOS_INDEX, reg);
    return io.inb(CMOS_DATA);
}

/// The CMOS register access seam rtc_decode.stableRead drives: the stable-read
/// POLICY lives with the other pure decode rules, host-tested; only the port
/// IO below is silicon-bound.
const CmosRtc = struct {
    pub fn updateInProgress(_: CmosRtc) bool {
        return readReg(REG_STATUS_A) & STATUS_A_UIP != 0;
    }
    pub fn snapshot(_: CmosRtc) rtc_decode.Raw {
        return .{
            .s = readReg(REG_SECONDS),
            .m = readReg(REG_MINUTES),
            .h = readReg(REG_HOURS),
            .day = readReg(REG_DAY_OF_MONTH),
            .month = readReg(REG_MONTH),
            .year = readReg(REG_YEAR),
            .century = readReg(REG_CENTURY),
            .status_b = readReg(REG_STATUS_B),
        };
    }
};

/// Read the RTC once and anchor wall-clock time to the tick timer. Call after
/// timer.init; safe to call on a machine with a dead RTC (wall time is then
/// simply unavailable).
pub fn init() void {
    const raw = rtc_decode.stableRead(CmosRtc{}, READ_ATTEMPTS) orelse {
        klog.puts("wallclock: no stable RTC read — wall time unavailable\n");
        return;
    };
    const epoch = rtc_decode.epochSeconds(raw) orelse {
        klog.puts("wallclock: RTC snapshot out of range — wall time unavailable\n");
        return;
    };
    epoch_base = epoch;
    base_ms = timer.millis();

    const c = rtc_decode.civil(raw).?; // epochSeconds above proved it decodes
    var buf: [64]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&buf, "wallclock: RTC read {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}Z\n", .{
        c.year, c.month, c.day, c.hour, c.minute, c.second,
    }) catch "wallclock: RTC read\n");
}

/// Unix epoch seconds (UTC) right now, or null when the RTC never yielded a
/// stable read at boot.
pub fn epochSeconds() ?i64 {
    const base = epoch_base orelse return null;
    return base + @as(i64, @intCast((timer.millis() - base_ms) / 1000));
}

/// Seconds since midnight UTC right now (0..86399), or null when the RTC never
/// yielded a stable read at boot.
pub fn secondsSinceMidnight() ?u64 {
    const epoch = epochSeconds() orelse return null;
    return @as(u64, @intCast(@mod(epoch, @as(i64, @intCast(SECONDS_PER_DAY)))));
}
