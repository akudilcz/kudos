//! Host tests of src/kernel/timer/rtc_decode.zig — the MC146818 snapshot
//! decode rules (BCD, 12/24-hour, century) that turn raw CMOS registers into
//! civil UTC time and epoch seconds. These are the rules that silently produce
//! a plausible-but-wrong wall clock, so every branch gets a golden vector.

const std = @import("std");
const rtc = @import("rtc_decode");

test "BCD 24-hour snapshot with century register" {
    // 2026-07-19 12:34:56 UTC, all-BCD, 24-hour, century 0x20.
    const raw24 = rtc.Raw{
        .s = 0x56,
        .m = 0x34,
        .h = 0x12,
        .day = 0x19,
        .month = 0x07,
        .year = 0x26,
        .century = 0x20,
        .status_b = rtc.STATUS_B_24H,
    };
    const c = rtc.civil(raw24).?;
    try std.testing.expectEqual(@as(i64, 2026), c.year);
    try std.testing.expectEqual(@as(u8, 7), c.month);
    try std.testing.expectEqual(@as(u8, 19), c.day);
    try std.testing.expectEqual(@as(u8, 12), c.hour);
    // date -u -d "2026-07-19T12:34:56Z" +%s
    try std.testing.expectEqual(@as(i64, 1_784_464_496), rtc.epochSeconds(raw24).?);
}

test "binary 24-hour snapshot, no century register (pivot to 20xx)" {
    // 2000-03-01 00:00:00 UTC — the classic leap-century instant.
    const raw = rtc.Raw{
        .s = 0,
        .m = 0,
        .h = 0,
        .day = 1,
        .month = 3,
        .year = 0,
        .century = 0,
        .status_b = rtc.STATUS_B_24H | rtc.STATUS_B_BINARY,
    };
    // date -u -d "2000-03-01T00:00:00Z" +%s
    try std.testing.expectEqual(@as(i64, 951_868_800), rtc.epochSeconds(raw).?);
}

test "two-digit year pivots at YEAR_PIVOT when no century register" {
    var raw = rtc.Raw{
        .s = 59,
        .m = 59,
        .h = 23,
        .day = 31,
        .month = 12,
        .year = 99,
        .century = 0,
        .status_b = rtc.STATUS_B_24H | rtc.STATUS_B_BINARY,
    };
    // 99 >= pivot -> 1999. date -u -d "1999-12-31T23:59:59Z" +%s
    try std.testing.expectEqual(@as(i64, 946_684_799), rtc.epochSeconds(raw).?);
    raw.year = 26;
    try std.testing.expectEqual(@as(i64, 2026), rtc.civil(raw).?.year);
    // The pivot itself belongs to the 19xx side: 70 -> 1970, 69 -> 2069.
    raw.year = rtc.YEAR_PIVOT;
    try std.testing.expectEqual(@as(i64, 1970), rtc.civil(raw).?.year);
    raw.year = rtc.YEAR_PIVOT - 1;
    try std.testing.expectEqual(@as(i64, 2069), rtc.civil(raw).?.year);
}

test "12-hour mode: PM adds twelve, 12 AM is hour zero, 12 PM stays twelve" {
    var raw = rtc.Raw{
        .s = 0,
        .m = 0,
        .h = 0x07 | rtc.HOURS_PM, // 7 PM, BCD 12-hour
        .day = 0x01,
        .month = 0x01,
        .year = 0x26,
        .century = 0x20,
        .status_b = 0, // BCD + 12-hour
    };
    try std.testing.expectEqual(@as(u8, 19), rtc.civil(raw).?.hour);
    raw.h = 0x12; // 12 AM -> 0
    try std.testing.expectEqual(@as(u8, 0), rtc.civil(raw).?.hour);
    raw.h = 0x12 | rtc.HOURS_PM; // 12 PM -> 12
    try std.testing.expectEqual(@as(u8, 12), rtc.civil(raw).?.hour);
}

test "garbage registers surface as no clock, never a wrong time" {
    const base = rtc.Raw{
        .s = 0,
        .m = 0,
        .h = 0,
        .day = 1,
        .month = 1,
        .year = 26,
        .century = 0,
        .status_b = rtc.STATUS_B_24H | rtc.STATUS_B_BINARY,
    };
    var bad = base;
    bad.month = 13;
    try std.testing.expect(rtc.civil(bad) == null);
    bad = base;
    bad.day = 0;
    try std.testing.expect(rtc.civil(bad) == null);
    bad = base;
    bad.h = 24;
    try std.testing.expect(rtc.civil(bad) == null);
    bad = base;
    bad.s = 60;
    try std.testing.expect(rtc.civil(bad) == null);
}

// ── The stable-read policy (KRN-004) ─────────────────────────────────────────
// Wall-clock time is initialised from one RTC read at boot; these prove the
// read that anchors it can never be a torn snapshot, and that a broken clock
// surfaces as null instead of a wrong time or a wedge.

/// A scripted RTC: each step is a UIP flag plus the snapshot a read would see.
const FakeRtc = struct {
    steps: []const Step,
    i: *usize,
    const Step = struct { uip: bool, raw: rtc.Raw };
    pub fn updateInProgress(f: FakeRtc) bool {
        const s = f.steps[@min(f.i.*, f.steps.len - 1)];
        f.i.* += 1;
        return s.uip;
    }
    pub fn snapshot(f: FakeRtc) rtc.Raw {
        const s = f.steps[@min(f.i.* - 1, f.steps.len - 1)];
        return s.raw;
    }
};

fn at(h: u8, m: u8, s: u8) rtc.Raw {
    return .{ .s = s, .m = m, .h = h, .day = 0x15, .month = 0x07, .year = 0x26, .century = 0x20, .status_b = 0 };
}

test "a torn rollover read is never accepted; the settled pair is (KRN-004)" {
    // First attempt tears across 09:59:59 → 10:00:00; the retry settles.
    var i: usize = 0;
    const fake = FakeRtc{ .i = &i, .steps = &.{
        .{ .uip = false, .raw = at(0x09, 0x59, 0x59) }, // UIP gate for attempt 1
        .{ .uip = false, .raw = at(0x10, 0x00, 0x00) }, // second read disagrees: torn
        .{ .uip = false, .raw = at(0x10, 0x00, 0x00) }, // attempt 2: identical pair
        .{ .uip = false, .raw = at(0x10, 0x00, 0x00) },
    } };
    const got = rtc.stableRead(fake, 10) orelse return error.NoStableRead;
    try std.testing.expectEqual(@as(u8, 0x10), got.h);
    try std.testing.expectEqual(@as(u8, 0x00), got.s);
}

test "an update in progress defers the read rather than tearing it (KRN-004)" {
    var i: usize = 0;
    const fake = FakeRtc{ .i = &i, .steps = &.{
        .{ .uip = true, .raw = at(0, 0, 0) }, // mid-update: attempt burned, no read
        .{ .uip = false, .raw = at(0x08, 0x30, 0x00) },
        .{ .uip = false, .raw = at(0x08, 0x30, 0x00) },
        .{ .uip = false, .raw = at(0x08, 0x30, 0x00) },
    } };
    const got = rtc.stableRead(fake, 10) orelse return error.NoStableRead;
    try std.testing.expectEqual(@as(u8, 0x08), got.h);
}

test "an RTC that never settles is a null clock, not a wedge or a guess (KRN-004)" {
    // UIP stuck high: the bounded retry gives up loudly.
    var i: usize = 0;
    var stuck_steps: [64]FakeRtc.Step = undefined;
    for (&stuck_steps) |*s| s.* = .{ .uip = true, .raw = at(0, 0, 0) };
    const stuck = FakeRtc{ .i = &i, .steps = &stuck_steps };
    try std.testing.expectEqual(@as(?rtc.Raw, null), rtc.stableRead(stuck, 10));

    // Forever-torn reads: two snapshots never agree; same loud null.
    var j: usize = 0;
    var torn_steps: [64]FakeRtc.Step = undefined;
    for (&torn_steps, 0..) |*s, n| s.* = .{ .uip = false, .raw = at(0, 0, @intCast(n % 60)) };
    const torn = FakeRtc{ .i = &j, .steps = &torn_steps };
    try std.testing.expectEqual(@as(?rtc.Raw, null), rtc.stableRead(torn, 10));
}
