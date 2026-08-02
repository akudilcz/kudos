//! Host tests of src/drivers/usb/xhci_cc.zig.

const std = @import("std");
const xhci_cc = @import("xhci_cc");
const CC_BABBLE = xhci_cc.CC_BABBLE;
const CC_SHORT_PACKET = xhci_cc.CC_SHORT_PACKET;
const CC_STALL = xhci_cc.CC_STALL;
const CC_SUCCESS = xhci_cc.CC_SUCCESS;
const CC_TIMEOUT = xhci_cc.CC_TIMEOUT;
const CC_TRB_ERROR = xhci_cc.CC_TRB_ERROR;
const CC_USB_TRANSACTION_ERROR = xhci_cc.CC_USB_TRANSACTION_ERROR;
const ccName = xhci_cc.ccName;
const cmdOk = xhci_cc.cmdOk;
const completionCode = xhci_cc.completionCode;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const xferNeedsRecovery = xhci_cc.xferNeedsRecovery;
const xferOk = xhci_cc.xferOk;

test "regression: SHORT PACKET is a successful transfer, not a failure" {
    // THE DIVERGENCE. Real hardware answers a short descriptor read or a boot HID
    // report with CC 13; QEMU answers the same transfer with CC 1. If Short Packet
    // is not accepted here, enumeration works perfectly in emulation and every
    // device on real silicon gets its endpoint "recovered" out from under it.
    try expect(xferOk(CC_SHORT_PACKET));
    try expect(!xferNeedsRecovery(CC_SHORT_PACKET));
    try expect(xferOk(CC_SUCCESS));
    try expect(!xferNeedsRecovery(CC_SUCCESS));
}

test "regression: a transaction error HALTS the endpoint — STALL is not the only one" {
    // Treating only STALL as halting left the endpoint wedged after a CErr-exhausted
    // transaction error: its doorbell is a no-op, so the device went silent for the
    // whole session with no error anywhere.
    try expect(xferNeedsRecovery(CC_USB_TRANSACTION_ERROR));
    try expect(xferNeedsRecovery(CC_STALL));
    try expect(xferNeedsRecovery(CC_BABBLE));
    try expect(xferNeedsRecovery(CC_TIMEOUT));
    // The property, stated directly: anything that is not OK needs recovery.
    for ([_]u32{ 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 0xFF }) |cc| {
        try expect(xferNeedsRecovery(cc));
    }
}

test "a COMMAND has no short-packet notion — only exact Success passes" {
    try expect(cmdOk(CC_SUCCESS));
    // A command completing "short" is meaningless; if the xHC ever said so, it is
    // not a success. This is the one place Short Packet must NOT be accepted.
    try expect(!cmdOk(CC_SHORT_PACKET));
    try expect(!cmdOk(CC_TRB_ERROR));
    try expect(!cmdOk(CC_TIMEOUT));
}

test "completionCode reads status bits 31:24" {
    try expectEqual(@as(u32, CC_SUCCESS), completionCode(0x0100_0000));
    try expectEqual(@as(u32, CC_SHORT_PACKET), completionCode(0x0D00_1234)); // residual in low bits
    try expectEqual(@as(u32, CC_BABBLE), completionCode(0x03FF_FFFF));
}

test "ccName: babble is named, because cc=3 cost us a session" {
    try expectEqual(@as([]const u8, "babble-detected"), ccName(CC_BABBLE));
    try expectEqual(@as([]const u8, "short-packet"), ccName(CC_SHORT_PACKET));
    try expectEqual(@as([]const u8, "timeout"), ccName(CC_TIMEOUT));
    try expectEqual(@as([]const u8, "?"), ccName(99));
}

test "a STOPPED echo is neither valid data nor a fault to recover from" {
    const CC_STOPPED = xhci_cc.CC_STOPPED;
    const CC_STOPPED_SHORT = xhci_cc.CC_STOPPED_SHORT_PACKET;
    const xferStopped = xhci_cc.xferStopped;
    // Stopped (26/27/28) is the echo of our own Stop Endpoint command.
    try expect(xferStopped(CC_STOPPED));
    try expect(xferStopped(xhci_cc.CC_STOPPED_LENGTH_INVALID));
    try expect(xferStopped(CC_STOPPED_SHORT));
    try expect(!xferStopped(CC_STALL));
    try expect(!xferStopped(CC_SUCCESS));
    // It carried no data...
    try expect(!xferOk(CC_STOPPED));
    // ...and must NOT trigger recovery — recovering re-stops the endpoint the
    // recovery just re-armed (the HID keyboard/mouse freeze).
    try expect(!xferNeedsRecovery(CC_STOPPED));
    try expect(!xferNeedsRecovery(CC_STOPPED_SHORT));
    // A real STALL still needs recovery.
    try expect(xferNeedsRecovery(CC_STALL));
    try expect(xferNeedsRecovery(CC_TRB_ERROR));
    try expectEqual(@as([]const u8, "stopped"), xhci_cc.ccName(CC_STOPPED));
}
