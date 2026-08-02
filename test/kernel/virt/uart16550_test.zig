//! Host tests of src/kernel/virt/uart16550.zig.

const std = @import("std");
const uart = @import("uart16550");
const Uart = uart.Uart;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

// VIRT-005: the guest gets a serial console — its whole boot log arrives
// through this port (guest_boot.py asserts the live half).
test "TX: a written byte is transmitted out" {
    var u = Uart{};
    u.ioWrite(0, 'K'); // THR
    try expectEqual(@as(?u8, 'K'), u.popTx());
    try expectEqual(@as(?u8, null), u.popTx());
}

test "TX: a string round-trips in order" {
    var u = Uart{};
    for ("hi\n") |c| u.ioWrite(0, c);
    try expectEqual(@as(?u8, 'h'), u.popTx());
    try expectEqual(@as(?u8, 'i'), u.popTx());
    try expectEqual(@as(?u8, '\n'), u.popTx());
}

test "RX: a pushed byte is readable and sets LSR data-ready (VIRT-011)" {
    var u = Uart{};
    try expect(u.pushRx('q'));
    try expect(u.ioRead(5) & 0x01 != 0); // LSR DR
    try expectEqual(@as(u8, 'q'), u.ioRead(0)); // RBR
    try expect(u.ioRead(5) & 0x01 == 0); // DR clears after read
}

test "DLAB routes offsets 0/1 to the divisor latches, not data" {
    var u = Uart{};
    u.ioWrite(3, 0x80); // LCR: DLAB=1
    u.ioWrite(0, 0x0C); // DLL
    u.ioWrite(1, 0x00); // DLM
    try expectEqual(@as(u8, 0x0C), u.ioRead(0)); // reads DLL, not RX
    u.ioWrite(3, 0x03); // DLAB=0, 8N1
    u.ioWrite(0, 'x'); // now a real TX
    try expectEqual(@as(?u8, 'x'), u.popTx());
}

test "LSR always reports the transmitter empty" {
    var u = Uart{};
    const lsr = u.ioRead(5);
    try expect(lsr & (1 << 5) != 0); // THR empty
    try expect(lsr & (1 << 6) != 0); // transmitter empty
}

test "IRQ level asserts for RX only when the RX interrupt is enabled" {
    var u = Uart{};
    try expect(u.pushRx('a'));
    try expect(!u.irqLevel()); // IER=0
    u.ioWrite(1, 0x01); // enable RX-available interrupt
    try expect(u.irqLevel());
    _ = u.ioRead(0); // consume the byte
    try expect(!u.irqLevel());
}

test "THRE interrupt: enabling ETBEI raises it, reading IIR clears it" {
    var u = Uart{};
    u.ioWrite(1, 0x02); // enable THR-empty interrupt → thre_pending becomes true
    try expect(u.irqLevel());
    const iir = u.ioRead(2);
    try expectEqual(@as(u8, 0x02), iir & 0x0F); // reported source is THRE
    try expect(!u.irqLevel()); // reading IIR cleared the THRE condition
}

test "THRE interrupt re-arms on the next THR write" {
    var u = Uart{};
    u.ioWrite(1, 0x02);
    _ = u.ioRead(2); // clear
    try expect(!u.irqLevel());
    u.ioWrite(0, 'z'); // write THR → THRE pending again
    try expect(u.irqLevel());
}

test "RX interrupt outranks THRE in IIR" {
    var u = Uart{};
    u.ioWrite(1, 0x03); // both enabled
    try expect(u.pushRx('r'));
    try expectEqual(@as(u8, 0x04), u.ioRead(2) & 0x0F); // RX-available wins
}

test "RX ring full is counted, not fatal" {
    var u = Uart{};
    var i: usize = 0;
    // Fill past capacity; some pushes must fail and bump the counter.
    while (i < 200) : (i += 1) _ = u.pushRx('.');
    try expect(u.dropped_rx > 0);
}

test "TX ring full is counted, not fatal" {
    var u = Uart{};
    var i: usize = 0;
    // Write past the TX ring without draining; overflow must count, not corrupt.
    while (i < 1024) : (i += 1) u.ioWrite(0, 'x');
    try expect(u.dropped_tx > 0);
}

test "FCR clear-receive flushes queued RX so a re-init sees a clean line" {
    var u = Uart{};
    try expect(u.pushRx('a')); // a byte queued before the driver opened the port
    try expect(u.ioRead(5) & 0x01 != 0); // LSR data-ready
    u.ioWrite(2, 0x02); // FCR: CLEAR_RCVR
    try expect(u.ioRead(5) & 0x01 == 0); // ring flushed — no stale data-ready
}

test "FCR clear-transmit drops undrained TX" {
    var u = Uart{};
    u.ioWrite(0, 'z'); // a byte in the TX ring
    u.ioWrite(2, 0x04); // FCR: CLEAR_XMIT
    try expectEqual(@as(?u8, null), u.popTx()); // flushed
}

test "DLAB routes reads to the divisor latches; SCR is plain storage" {
    var u = Uart{};
    u.ioWrite(3, 0x83); // LCR: DLAB on
    u.ioWrite(0, 0x0C); // DLL
    u.ioWrite(1, 0x00); // DLM
    try std.testing.expectEqual(@as(u8, 0x0C), u.ioRead(0));
    try std.testing.expectEqual(@as(u8, 0x00), u.ioRead(1));
    try std.testing.expectEqual(@as(u8, 0x83), u.ioRead(3)); // LCR reads back
    u.ioWrite(3, 0x03); // DLAB off
    u.ioWrite(7, 0x5A); // scratch
    try std.testing.expectEqual(@as(u8, 0x5A), u.ioRead(7));
}

test "MSR: loopback reflects MCR outputs; line-up otherwise; status writes ignored" {
    var u = Uart{};
    u.ioWrite(4, 0x10 | 0x03); // MCR: loopback + DTR/RTS
    const looped = u.ioRead(6);
    u.ioWrite(4, 0x00);
    try std.testing.expect(looped != u.ioRead(6)); // loopback vs line-up differ
    u.ioWrite(5, 0xFF); // LSR write: ignored
    u.ioWrite(6, 0xFF); // MSR write: ignored
    try std.testing.expect(u.ioRead(5) & 0x20 != 0); // THR still empty
}

test "a full TX ring counts the overflow instead of blocking or wedging" {
    var u = Uart{};
    var i: usize = 0;
    while (i < 5000) : (i += 1) u.ioWrite(0, 'x'); // no drain: overflow territory
    try std.testing.expect(u.dropped_tx > 0);
}
