//! Host tests of src/kernel/virt/i8259.zig.

const std = @import("std");
// @"..." because a bare `i8259` is Zig's 8259-bit integer primitive.
const @"i8259" = @import("i8259");
const PicPair = @"i8259".PicPair;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

/// Program both chips the way Linux's boot path does: edge-triggered cascade
/// mode with ICW4, master vectors at 0x20, slave vectors at 0x28, slave on
/// master IRQ 2. ICW1 clears the masks, so every line starts unmasked.
fn linuxInit() PicPair {
    var p = PicPair{};
    p.ioWrite(0x20, 0x11); // master ICW1: edge, cascade, ICW4 follows
    p.ioWrite(0x21, 0x20); // ICW2: vector base 0x20
    p.ioWrite(0x21, 0x04); // ICW3: slave on IRQ 2
    p.ioWrite(0x21, 0x01); // ICW4: 8086 mode
    p.ioWrite(0xA0, 0x11); // slave ICW1
    p.ioWrite(0xA1, 0x28); // ICW2: vector base 0x28
    p.ioWrite(0xA1, 0x02); // ICW3: cascade identity 2
    p.ioWrite(0xA1, 0x01); // ICW4: 8086 mode
    return p;
}

test "ICW sequence programs the vector base" {
    var p = linuxInit();
    p.raise(4);
    try expectEqual(@as(?u8, 0x24), p.ack());
}

test "OCW1 lands in IMR after init and a masked IRQ does not ack" {
    var p = linuxInit();
    p.ioWrite(0x21, 0x10); // OCW1: mask IRQ 4
    try expectEqual(@as(u8, 0x10), p.ioRead(0x21));
    p.raise(4);
    try expectEqual(@as(?u8, null), p.ack());
    p.ioWrite(0x21, 0x00); // unmask — the latched request becomes serviceable
    try expectEqual(@as(?u8, 0x24), p.ack());
}

test "ack moves the request from IRR to ISR" {
    var p = linuxInit();
    p.raise(4);
    p.ioWrite(0x20, 0x0A); // OCW3: read IRR
    try expectEqual(@as(u8, 0x10), p.ioRead(0x20));
    try expectEqual(@as(?u8, 0x24), p.ack());
    try expectEqual(@as(u8, 0x00), p.ioRead(0x20)); // IRR cleared by the ack
    p.ioWrite(0x20, 0x0B); // OCW3: read ISR
    try expectEqual(@as(u8, 0x10), p.ioRead(0x20));
}

test "non-specific EOI clears ISR and reopens the line" {
    var p = linuxInit();
    p.raise(4);
    try expectEqual(@as(?u8, 0x24), p.ack());
    p.raise(4); // re-raised while in service: blocked until EOI
    try expectEqual(@as(?u8, null), p.ack());
    p.ioWrite(0x20, 0x20); // OCW2: non-specific EOI
    p.ioWrite(0x20, 0x0B);
    try expectEqual(@as(u8, 0x00), p.ioRead(0x20) & 0x10);
    try expectEqual(@as(?u8, 0x24), p.ack());
}

test "specific EOI clears exactly the named level" {
    var p = linuxInit();
    p.raise(4);
    try expectEqual(@as(?u8, 0x24), p.ack());
    p.ioWrite(0x20, 0x63); // OCW2: specific EOI for IRQ 3 — not in service
    p.ioWrite(0x20, 0x0B);
    try expectEqual(@as(u8, 0x10), p.ioRead(0x20)); // IRQ 4 still in service
    p.ioWrite(0x20, 0x64); // specific EOI for IRQ 4
    try expectEqual(@as(u8, 0x00), p.ioRead(0x20));
}

test "the lower IRQ number wins and nests over the higher" {
    var p = linuxInit();
    p.raise(4);
    p.raise(3);
    try expectEqual(@as(?u8, 0x23), p.ack()); // IRQ 3 outranks IRQ 4
    try expectEqual(@as(?u8, null), p.ack()); // 3 in service blocks 4
    p.ioWrite(0x20, 0x20); // EOI IRQ 3
    try expectEqual(@as(?u8, 0x24), p.ack());
}

test "a slave line asserts the cascade and resolves to the slave vector" {
    var p = linuxInit();
    p.raise(12);
    p.ioWrite(0x20, 0x0A); // master IRR shows the cascade line
    try expectEqual(@as(u8, 0x04), p.ioRead(0x20));
    try expectEqual(@as(?u8, 0x2C), p.ack()); // slave base 0x28 + IRQ 4-of-8
    p.ioWrite(0xA0, 0x0B); // slave ISR holds its line 4
    try expectEqual(@as(u8, 0x10), p.ioRead(0xA0));
    p.ioWrite(0x20, 0x0B); // master ISR holds the cascade
    try expectEqual(@as(u8, 0x04), p.ioRead(0x20));
    p.ioWrite(0xA0, 0x20); // EOI both, slave then master, as Linux does
    p.ioWrite(0x20, 0x20);
    try expectEqual(@as(u8, 0x00), p.ioRead(0xA0));
    try expectEqual(@as(?u8, null), p.ack());
}

test "lower before ack withdraws the request" {
    var p = linuxInit();
    p.raise(4);
    p.lower(4);
    try expectEqual(@as(?u8, null), p.ack());
}

test "peek reports the ack vector without consuming the request" {
    var p = linuxInit();
    try expectEqual(@as(?u8, null), p.peek()); // nothing pending
    p.raise(4);
    try expectEqual(@as(?u8, 0x24), p.peek()); // same vector ack would return
    try expectEqual(@as(?u8, 0x24), p.peek()); // still there — non-destructive
    p.ioWrite(0x20, 0x0B); // read ISR: still empty, peek did not acknowledge
    try expectEqual(@as(u8, 0x00), p.ioRead(0x20));
    try expectEqual(@as(?u8, 0x24), p.ack()); // the real ack still works
}

test "peek resolves a cascaded slave line to the slave vector" {
    var p = linuxInit();
    p.raise(12);
    try expectEqual(@as(?u8, 0x2C), p.peek()); // slave base 0x28 + IRQ 4-of-8
    try expectEqual(@as(?u8, 0x2C), p.ack()); // and it survives to be acked
}
