//! Host tests of src/kernel/timer/caldate.zig — civil date to epoch, against
//! known instants and leap-year/century edges.

const std = @import("std");
const caldate = @import("caldate");

test "epoch and well-known instants" {
    try std.testing.expectEqual(@as(i64, 0), caldate.epochSeconds(1970, 1, 1, 0, 0, 0));
    // 2001-09-09 01:46:40 UTC is exactly 1_000_000_000.
    try std.testing.expectEqual(@as(i64, 1_000_000_000), caldate.epochSeconds(2001, 9, 9, 1, 46, 40));
    // 2009-02-13 23:31:30 UTC is 1_234_567_890.
    try std.testing.expectEqual(@as(i64, 1_234_567_890), caldate.epochSeconds(2009, 2, 13, 23, 31, 30));
}

test "leap day and century (2000 is a leap year, 1900 is not)" {
    // 2000-02-29 exists; day count for 2000-03-01 minus 2000-02-29 is one day.
    const feb29 = caldate.daysFromCivil(2000, 2, 29);
    const mar01 = caldate.daysFromCivil(2000, 3, 1);
    try std.testing.expectEqual(@as(i64, 1), mar01 - feb29);
    // A recent cert-relevant instant: 2026-07-19 00:00:00.
    try std.testing.expectEqual(@as(i64, 1_784_419_200), caldate.epochSeconds(2026, 7, 19, 0, 0, 0));
}

test "days advance by exactly 86400 seconds" {
    const a = caldate.epochSeconds(2024, 12, 31, 12, 0, 0);
    const b = caldate.epochSeconds(2025, 1, 1, 12, 0, 0);
    try std.testing.expectEqual(@as(i64, 86400), b - a);
}

test "civilFromEpoch inverts epochSeconds exactly" {
    // Known instants first, so a broken inverse cannot agree with a broken
    // forward direction and call it a pass.
    const y2k = caldate.civilFromEpoch(946_684_800);
    try std.testing.expectEqual(@as(i64, 2000), y2k.year);
    try std.testing.expectEqual(@as(u8, 1), y2k.month);
    try std.testing.expectEqual(@as(u8, 1), y2k.day);
    try std.testing.expectEqual(@as(u8, 0), y2k.hour);

    const billion = caldate.civilFromEpoch(1_000_000_000);
    try std.testing.expectEqual(@as(i64, 2001), billion.year);
    try std.testing.expectEqual(@as(u8, 9), billion.month);
    try std.testing.expectEqual(@as(u8, 9), billion.day);
    try std.testing.expectEqual(@as(u8, 1), billion.hour);
    try std.testing.expectEqual(@as(u8, 46), billion.minute);
    try std.testing.expectEqual(@as(u8, 40), billion.second);

    // Then the round trip over a long stride of instants: every third day and a
    // few seconds, across a century, catching leap years and century rules.
    var t: i64 = 0;
    while (t < 3_200_000_000) : (t += 259_207) {
        const c = caldate.civilFromEpoch(t);
        try std.testing.expectEqual(t, caldate.epochSeconds(c.year, c.month, c.day, c.hour, c.minute, c.second));
    }
}

test "civilFromEpoch handles instants before the epoch" {
    // The RTC can read a date in the 1900s, and @divFloor/@mod must carry
    // correctly rather than truncating toward zero and inventing a time of day.
    const c = caldate.civilFromEpoch(-1);
    try std.testing.expectEqual(@as(i64, 1969), c.year);
    try std.testing.expectEqual(@as(u8, 12), c.month);
    try std.testing.expectEqual(@as(u8, 31), c.day);
    try std.testing.expectEqual(@as(u8, 23), c.hour);
    try std.testing.expectEqual(@as(u8, 59), c.minute);
    try std.testing.expectEqual(@as(u8, 59), c.second);
    try std.testing.expectEqual(@as(i64, -1), caldate.epochSeconds(c.year, c.month, c.day, c.hour, c.minute, c.second));
}

test "the weekday numbering matches the RTC's 1 = Sunday register" {
    // 1970-01-01 was a Thursday: 5 when Sunday is 1.
    try std.testing.expectEqual(@as(u8, 5), caldate.civilFromEpoch(0).weekday);
    // …and it cycles, forwards and backwards over the epoch.
    try std.testing.expectEqual(@as(u8, 6), caldate.civilFromEpoch(86_400).weekday);
    try std.testing.expectEqual(@as(u8, 7), caldate.civilFromEpoch(2 * 86_400).weekday);
    try std.testing.expectEqual(@as(u8, 1), caldate.civilFromEpoch(3 * 86_400).weekday);
    try std.testing.expectEqual(@as(u8, 4), caldate.civilFromEpoch(-86_400).weekday);
    // 2026-07-25 was a Saturday.
    try std.testing.expectEqual(@as(u8, 7), caldate.civilFromEpoch(caldate.epochSeconds(2026, 7, 25, 12, 0, 0)).weekday);
}
