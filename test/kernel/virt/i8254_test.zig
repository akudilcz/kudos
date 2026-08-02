//! Host tests of src/kernel/virt/i8254.zig — the guest's legacy interval timer.
//! The property that matters: a guest that programs channel 0 the way Linux
//! does gets periodic pulses at the rate it asked for, and a guest that does
//! not program it gets none.

const std = @import("std");
const pit = @import("i8254");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Linux's HZ=250 divisor: PIT_HZ / 250, what `pit_timer_init` writes.
const DIV_250HZ: u64 = pit.PIT_HZ / 250;

/// Program channel 0 exactly as Linux does: control word 0x34 (channel 0,
/// lsb-then-msb, mode 2, binary), then the divisor low byte then high byte.
fn programChannel0(p: *pit.Pit, div: u64) void {
    p.ioWrite(pit.COMMAND_PORT, 0x34);
    p.ioWrite(pit.COUNTER0_PORT, @truncate(div));
    p.ioWrite(pit.COUNTER0_PORT, @truncate(div >> 8));
}

test "an unprogrammed PIT never manufactures a tick" {
    var p = pit.Pit{};
    try expectEqual(@as(u64, 0), p.expired(0, 4));
    try expectEqual(@as(u64, 0), p.expired(1_000_000_000, 4));
    try expectEqual(@as(u64, 0), p.ticks_total);
}

test "mode 2 at Linux's HZ=250 divisor pulses once per period" {
    var p = pit.Pit{};
    programChannel0(&p, DIV_250HZ);
    try expectEqual(DIV_250HZ, p.period());
    // The first call only seeds the schedule — a guest must not be handed a
    // tick for time that passed before it programmed the timer.
    try expectEqual(@as(u64, 0), p.expired(1000, 4));
    // One period later: exactly one pulse.
    try expectEqual(@as(u64, 1), p.expired(1000 + DIV_250HZ, 4));
    // Half a period later: none.
    try expectEqual(@as(u64, 0), p.expired(1000 + DIV_250HZ + DIV_250HZ / 2, 4));
    // The next boundary: one more.
    try expectEqual(@as(u64, 1), p.expired(1000 + 2 * DIV_250HZ, 4));
    try expectEqual(@as(u64, 2), p.ticks_total);
}

test "a long gap coalesces to the catch-up cap and counts the rest" {
    var p = pit.Pit{};
    programChannel0(&p, DIV_250HZ);
    _ = p.expired(0, 4);
    // Ten periods pass in one gap; only the cap is delivered now.
    const delivered = p.expired(10 * DIV_250HZ, 4);
    try expectEqual(@as(u64, 4), delivered);
    try expectEqual(@as(u64, 6), p.pending_ticks); // counted, not dropped
    // Later polls drain the remainder rather than losing it.
    try expectEqual(@as(u64, 4), p.expired(10 * DIV_250HZ, 4));
    try expectEqual(@as(u64, 2), p.expired(10 * DIV_250HZ, 4));
    try expectEqual(@as(u64, 0), p.expired(10 * DIV_250HZ, 4));
}

test "mode 0 fires exactly once until the count is rewritten" {
    var p = pit.Pit{};
    p.ioWrite(pit.COMMAND_PORT, 0x30); // channel 0, lsb/msb, mode 0
    p.ioWrite(pit.COUNTER0_PORT, 0x00);
    p.ioWrite(pit.COUNTER0_PORT, 0x10); // 0x1000 ticks
    _ = p.expired(0, 4);
    try expectEqual(@as(u64, 1), p.expired(0x1000, 4));
    try expectEqual(@as(u64, 0), p.expired(0x8000, 4)); // disarmed after one shot
    p.ioWrite(pit.COUNTER0_PORT, 0x00);
    p.ioWrite(pit.COUNTER0_PORT, 0x10); // rearm
    _ = p.expired(0x8000, 4);
    try expectEqual(@as(u64, 1), p.expired(0x9000, 4));
}

test "a reload of zero means the longest period, never a divide by zero" {
    var p = pit.Pit{};
    programChannel0(&p, 0);
    try expectEqual(@as(u64, 65536), p.period());
    _ = p.expired(0, 4);
    try expectEqual(@as(u64, 0), p.expired(65535, 4));
    try expectEqual(@as(u64, 1), p.expired(65536, 4));
}

test "the counter reads back the value the guest wrote, low byte then high" {
    var p = pit.Pit{};
    programChannel0(&p, 0x1234);
    p.ioWrite(pit.COMMAND_PORT, 0x00); // latch channel 0
    try expectEqual(@as(u8, 0x34), p.ioRead(pit.COUNTER0_PORT));
    try expectEqual(@as(u8, 0x12), p.ioRead(pit.COUNTER0_PORT));
}

test "a read-back command latches status carrying the programmed mode" {
    var p = pit.Pit{};
    programChannel0(&p, DIV_250HZ);
    p.ioWrite(pit.COMMAND_PORT, 0xE2); // read-back, status, channel 0
    const status = p.ioRead(pit.COUNTER0_PORT);
    try expectEqual(@as(u8, 2), (status >> 1) & 0x7); // mode 2
    try expectEqual(@as(u8, 3), (status >> 4) & 0x3); // lsb-then-msb access
}

test "reprogramming the mode disarms until a fresh count arrives" {
    var p = pit.Pit{};
    programChannel0(&p, DIV_250HZ);
    _ = p.expired(0, 4);
    p.ioWrite(pit.COMMAND_PORT, 0x34); // mode write only, no count yet
    try expectEqual(@as(u64, 0), p.expired(100 * DIV_250HZ, 4));
    p.ioWrite(pit.COUNTER0_PORT, @truncate(DIV_250HZ));
    p.ioWrite(pit.COUNTER0_PORT, @truncate(DIV_250HZ >> 8));
    _ = p.expired(100 * DIV_250HZ, 4);
    try expectEqual(@as(u64, 1), p.expired(101 * DIV_250HZ, 4));
}

test "the PIT owns 0x40..0x43 and nothing else" {
    try expect(pit.Pit.owns(0x40));
    try expect(pit.Pit.owns(0x43));
    try expect(!pit.Pit.owns(0x3F));
    try expect(!pit.Pit.owns(0x44));
    try expect(!pit.Pit.owns(0x21)); // the PIC's, not ours
}

test "the command port is write-only: reads return all-ones" {
    var p = pit.Pit{};
    try expectEqual(@as(u8, 0xFF), p.ioRead(pit.COMMAND_PORT));
}
