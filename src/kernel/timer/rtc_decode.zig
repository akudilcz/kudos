//! Pure decode of an MC146818 real-time-clock register snapshot into civil
//! time and Unix epoch seconds. The hardware read (ports, update-in-progress
//! handshake) lives in wallclock.zig; every numeric rule — BCD, 12/24-hour
//! form, the century register — lives here, host-tested, because these are
//! exactly the rules that silently produce a plausible-but-wrong clock.
//!
//! This is the READ direction, for the host's own clock. The guest-facing
//! encode direction is its device's own register format (virt/mc146818.zig).

const std = @import("std");
const caldate = @import("caldate.zig");

/// Status-register-B bits (MC146818): how the value registers are encoded.
pub const STATUS_B_24H: u8 = 0x02; // hours are 0..23, not 1..12 + PM bit
pub const STATUS_B_BINARY: u8 = 0x04; // values are binary, not BCD
/// 12-hour mode: PM flag on the hours register.
pub const HOURS_PM: u8 = 0x80;

/// The RTC year register holds two digits. When the century register (CMOS
/// 0x32) is absent or nonsense, the two-digit year pivots here: years below
/// the pivot are 20xx, the rest 19xx.
pub const YEAR_PIVOT: u8 = 70;

/// One raw register snapshot, exactly as read (BCD or binary per status B).
/// `century` is 0 when the platform has no century register.
pub const Raw = struct {
    s: u8,
    m: u8,
    h: u8,
    day: u8,
    month: u8,
    year: u8,
    century: u8 = 0,
    status_b: u8,
};

pub const Civil = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

fn bcdToBinary(v: u8) u8 {
    return (v >> 4) * 10 + (v & 0x0F);
}

/// Decode a snapshot to civil UTC time, or null when any field is out of
/// range (a garbage CMOS must surface as "no clock", never as a wrong time).
pub fn civil(raw: Raw) ?Civil {
    const binary = raw.status_b & STATUS_B_BINARY != 0;
    const is24 = raw.status_b & STATUS_B_24H != 0;

    const s: u8 = if (binary) raw.s else bcdToBinary(raw.s);
    const m: u8 = if (binary) raw.m else bcdToBinary(raw.m);
    var hour_reg = raw.h;
    const pm = !is24 and (hour_reg & HOURS_PM) != 0;
    hour_reg &= ~HOURS_PM;
    var h: u8 = if (binary) hour_reg else bcdToBinary(hour_reg);
    if (!is24) {
        // 12-hour mode: 12 AM is hour 0, 12 PM stays 12, 1..11 PM add 12.
        if (h == 12) h = 0;
        if (pm) h += 12;
    }
    const day: u8 = if (binary) raw.day else bcdToBinary(raw.day);
    const month: u8 = if (binary) raw.month else bcdToBinary(raw.month);
    const yy: u8 = if (binary) raw.year else bcdToBinary(raw.year);
    const century: u8 = if (binary) raw.century else bcdToBinary(raw.century);

    // A plausible century register (19..21) is authoritative; otherwise the
    // two-digit year pivots at YEAR_PIVOT.
    const year: i64 = if (century >= 19 and century <= 21)
        @as(i64, century) * 100 + yy
    else if (yy < YEAR_PIVOT)
        2000 + @as(i64, yy)
    else
        1900 + @as(i64, yy);

    if (s > 59 or m > 59 or h > 23) return null;
    if (day == 0 or day > 31 or month == 0 or month > 12) return null;
    return .{ .year = year, .month = month, .day = day, .hour = h, .minute = m, .second = s };
}

/// Decode a snapshot straight to Unix epoch seconds (UTC), or null on garbage.
pub fn epochSeconds(raw: Raw) ?i64 {
    const c = civil(raw) orelse return null;
    return caldate.epochSeconds(c.year, c.month, c.day, c.hour, c.minute, c.second);
}

/// Two snapshots agree on the time and date fields. Century and status are
/// configuration, not moving time — they cannot tear and are not compared.
pub fn sameTime(a: Raw, b: Raw) bool {
    return a.s == b.s and a.m == b.m and a.h == b.h and
        a.day == b.day and a.month == b.month and a.year == b.year;
}

/// The MC146818 stable-read policy (KRN-004): wait out an in-progress update,
/// read twice, accept only two identical consecutive snapshots. A torn read
/// across a rollover otherwise yields e.g. 09:59:59 → 09:00:00. `rtc` is the
/// register access seam: `updateInProgress()` (status A UIP) and `snapshot()`;
/// the retry bound keeps a broken clock loud (null) instead of wedging boot.
pub fn stableRead(rtc: anytype, max_attempts: u8) ?Raw {
    var attempt: u8 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (rtc.updateInProgress()) continue;
        const a = rtc.snapshot();
        if (rtc.updateInProgress()) continue;
        const b = rtc.snapshot();
        if (sameTime(a, b)) return a;
    }
    return null;
}
