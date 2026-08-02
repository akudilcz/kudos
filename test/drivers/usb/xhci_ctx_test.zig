//! Host tests of src/drivers/usb/xhci_ctx.zig.

const std = @import("std");
const xhci_ctx = @import("xhci_ctx");
const EP_TYPE_CONTROL = xhci_ctx.EP_TYPE_CONTROL;
const EP_TYPE_INTERRUPT_IN = xhci_ctx.EP_TYPE_INTERRUPT_IN;
const ctrl = xhci_ctx.ctrl;
const ctxOffset = xhci_ctx.ctxOffset;
const epDw1 = xhci_ctx.epDw1;
const expectEqual = std.testing.expectEqual;
const setupPkt = xhci_ctx.setupPkt;
const slotDw0 = xhci_ctx.slotDw0;
const trDequeueHi = xhci_ctx.trDequeueHi;
const trDequeueLo = xhci_ctx.trDequeueLo;
const trbType = xhci_ctx.trbType;

test "regression: the 64-byte context stride real controllers use, and QEMU does not" {
    // HCCPARAMS1.CSZ: QEMU says 32, every real xHC (lemon's Intel PCH included) says
    // 64. Hard-code 32 and emulation is flawless while real hardware has each context
    // written half-way into the previous one.
    try expectEqual(@as(usize, 0), ctxOffset(64, 0, 0));
    try expectEqual(@as(usize, 64), ctxOffset(64, 1, 0)); // slot ctx, 64-byte stride
    try expectEqual(@as(usize, 128), ctxOffset(64, 2, 0)); // EP0 ctx
    try expectEqual(@as(usize, 132), ctxOffset(64, 2, 1)); // …its DW1

    // The 32-byte (QEMU) layout, for contrast — the SAME indices land elsewhere.
    try expectEqual(@as(usize, 32), ctxOffset(32, 1, 0));
    try expectEqual(@as(usize, 64), ctxOffset(32, 2, 0));

    // The property that matters: context N+1 never overlaps context N.
    for ([_]usize{ 32, 64 }) |csz| {
        var idx: usize = 0;
        while (idx < 8) : (idx += 1) {
            const end_of_this = ctxOffset(csz, idx, csz / 4 - 1) + 4;
            try std.testing.expect(end_of_this <= ctxOffset(csz, idx + 1, 0));
        }
    }
}

test "TRB control word: type in 15:10, and ctrl/trbType round-trip" {
    const TRB_NORMAL = 1;
    const TRB_LINK = 6;
    const TRB_ADDRESS_DEVICE = 11;
    for ([_]u32{ TRB_NORMAL, TRB_LINK, TRB_ADDRESS_DEVICE, 32, 33, 63 }) |t| {
        try expectEqual(t, trbType(ctrl(t, 0)));
        try expectEqual(t, trbType(ctrl(t, 0x3F))); // flags must not bleed into the type
    }
    // The cycle bit (bit 0) is the ring's business — ctrl never sets it.
    try expectEqual(@as(u32, 0), ctrl(TRB_NORMAL, 0) & 1);
}

test "endpoint context DW1: type, CErr and max-packet in their own fields" {
    const dw = epDw1(EP_TYPE_INTERRUPT_IN, 8);
    try expectEqual(@as(u32, EP_TYPE_INTERRUPT_IN), (dw >> 3) & 0x7);
    try expectEqual(@as(u32, 3), (dw >> 1) & 0x3); // CErr = 3
    try expectEqual(@as(u32, 8), dw >> 16); // MPS

    // A 512-byte EP0 (USB 3.x) must not overflow into anything.
    const ss = epDw1(EP_TYPE_CONTROL, 512);
    try expectEqual(@as(u32, 512), ss >> 16);
    try expectEqual(@as(u32, EP_TYPE_CONTROL), (ss >> 3) & 0x7);
}

test "slot context DW0: route, speed and context-entries do not collide" {
    // A tier-2 route string with two nibbles set, SuperSpeedPlus, 3 context entries.
    const dw = slotDw0(0x0000_0021, 3, 5, 0);
    try expectEqual(@as(u32, 0x21), dw & 0xF_FFFF); // route: bits 19:0
    try expectEqual(@as(u32, 5), (dw >> 20) & 0xF); // speed: bits 23:20
    try expectEqual(@as(u32, 3), dw >> 27); // ctx entries: bits 31:27

    // The Hub flag (bit 26) sits between speed and context-entries and must survive.
    const hub = slotDw0(0, 1, 3, 1 << 26);
    try expectEqual(@as(u32, 1), (hub >> 26) & 1);
    try expectEqual(@as(u32, 1), hub >> 27);
}

test "TR dequeue pointer: DCS in bit 0, address split lo/hi" {
    const phys: u64 = 0x1_2345_6000;
    try expectEqual(@as(u32, 0x2345_6001), trDequeueLo(phys)); // DCS set
    try expectEqual(@as(u32, 1), trDequeueHi(phys));
    // The address is 16-byte aligned, so DCS never corrupts it.
    try expectEqual(phys, (@as(u64, trDequeueHi(phys)) << 32) | (trDequeueLo(phys) & ~@as(u32, 0xF)));
}

test "SETUP packet: the byte order a Setup Stage TRB carries inline" {
    // GET_DESCRIPTOR(Device), wLength = 18 — the read that babbled on the Phison.
    const p = setupPkt(0x80, 6, 0x0100, 0, 18);
    try expectEqual(@as(u8, 0x80), @as(u8, @truncate(p))); // bmRequestType
    try expectEqual(@as(u8, 6), @as(u8, @truncate(p >> 8))); // bRequest
    try expectEqual(@as(u16, 0x0100), @as(u16, @truncate(p >> 16))); // wValue
    try expectEqual(@as(u16, 0), @as(u16, @truncate(p >> 32))); // wIndex
    try expectEqual(@as(u16, 18), @as(u16, @truncate(p >> 48))); // wLength
}
