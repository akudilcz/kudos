//! Civil date to Unix epoch seconds — the pure calendar math the wall clock
//! needs to turn the RTC's Y/M/D H:M:S into the epoch time TLS certificate
//! validity checks compare against. Uses Howard Hinnant's days-from-civil
//! algorithm, correct across leap years and centuries. No allocation, no
//! hardware — host-tested against known instants.

const std = @import("std");

/// Days since 1970-01-01 for a proleptic-Gregorian date. `m` in 1..12.
pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = @mod(@as(i64, month) + 9, 12); // Mar=0..Feb=11
    const doy: i64 = @divTrunc(153 * mp + 2, 5) + @as(i64, day) - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Unix epoch seconds for a UTC civil timestamp.
pub fn epochSeconds(year: i64, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    return daysFromCivil(year, month, day) * 86400 +
        @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

/// A civil date, and the time of day when it came from an instant rather than
/// from a date alone.
pub const Civil = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    /// Day of the week, 1 = Sunday … 7 = Saturday — the numbering the
    /// MC146818's day-of-week register uses.
    weekday: u8 = 1,
};

/// The proleptic-Gregorian date `days` after 1970-01-01. The exact inverse of
/// `daysFromCivil` (Hinnant's civil-from-days), including for negative days.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp: i64 = @divTrunc(5 * doy + 2, 153); // [0, 11], Mar=0
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    // 1970-01-01 was a Thursday, which is weekday 5 in the RTC's 1 = Sunday
    // numbering; @mod keeps that true for dates before the epoch too.
    const weekday: i64 = @mod(days + 4, 7) + 1;
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @intCast(m),
        .day = @intCast(d),
        .weekday = @intCast(weekday),
    };
}

/// The UTC civil timestamp at `epoch` Unix seconds. The exact inverse of
/// `epochSeconds`.
pub fn civilFromEpoch(epoch: i64) Civil {
    const days = @divFloor(epoch, 86400);
    const secs = @mod(epoch, 86400); // [0, 86399] even for negative epochs
    var c = civilFromDays(days);
    c.hour = @intCast(@divTrunc(secs, 3600));
    c.minute = @intCast(@divTrunc(@mod(secs, 3600), 60));
    c.second = @intCast(@mod(secs, 60));
    return c;
}
