//! xHCI completion codes and the verdicts drawn from them — pure, so they can be
//! host-tested (`zig build test`).
//!
//! This is the biggest QEMU-vs-real-hardware divergence in the driver: REAL CONTROLLERS
//! REPORT SHORT PACKET (CC 13) WHERE QEMU REPORTS SUCCESS (CC 1). Drop CC 13 from
//! `xferOk` and every HID report and short descriptor read becomes an endpoint-recovery
//! event on real silicon while emulation stays green — so the decision lives here, where
//! a host test can reach it. The driver keeps the MMIO and the `last_cc` bookkeeping.

const std = @import("std");

// Completion codes (event TRB status bits 31:24), xHCI §6.4.5 Table 6-90.
pub const CC_INVALID: u32 = 0;
pub const CC_SUCCESS: u32 = 1;
/// The xHC could not parse the TRB — a driver bug (bad context, bad TRB field),
/// never a device problem. Address Device answers with this when the slot context
/// is malformed.
pub const CC_TRB_ERROR: u32 = 5;
/// The device returned STALL and the xHC HALTED the endpoint. A halted endpoint
/// runs NO further TRBs until Reset Endpoint + Set TR Dequeue: its doorbell is a
/// no-op, so an unrecovered stall silently kills the device for the session.
pub const CC_STALL: u32 = 6;
/// CErr exhausted — marginal signal, a long cable, a dying device. Also HALTS the
/// endpoint, so recovery cannot be gated on STALL alone.
pub const CC_USB_TRANSACTION_ERROR: u32 = 4;
/// The device sent more data than the endpoint's max packet size. Its usual cause
/// is US programming EP0 with the wrong max-packet size for the port speed — a
/// SuperSpeedPlus port defaulting to 8 bytes made the Phison stick babble on every
/// descriptor read (see port_fsm.maxPacketForSpeed).
pub const CC_BABBLE: u32 = 3;
/// The device returned FEWER bytes than the TD asked for. A completely normal
/// result — a boot report is shorter than the buffer, a descriptor is shorter than
/// the read. See the file header: this is the code QEMU almost never produces.
pub const CC_SHORT_PACKET: u32 = 13;
/// A context field the xHC rejected — like CC_TRB_ERROR, always a driver bug.
pub const CC_PARAMETER_ERROR: u32 = 17;

/// The endpoint was STOPPED — the completion of a TRB that was executing when a
/// Stop Endpoint command (or a dequeue-pointer move) ran. NOT a device fault:
/// the xHC produces this Transfer Event for the in-flight TRB whenever software
/// stops the endpoint, which the HID recovery path itself does. It must be
/// ignored, not "recovered" — recovering on it re-stops the endpoint software
/// just re-armed, an endless self-inflicted reset that kills the device. Linux
/// treats COMP_STOPPED / _LENGTH_INVALID / _SHORT_PACKET the same way.
pub const CC_STOPPED: u32 = 26;
pub const CC_STOPPED_LENGTH_INVALID: u32 = 27;
pub const CC_STOPPED_SHORT_PACKET: u32 = 28;
/// Not a controller code. The driver stamps this when NO completion arrived at all,
/// so "timed out" is distinguishable from "the xHC said something".
pub const CC_TIMEOUT: u32 = 0xFF;

/// Completion code of an event TRB (status bits 31:24).
pub fn completionCode(status: u32) u32 {
    return (status >> 24) & 0xFF;
}

/// A COMMAND completed successfully. Commands have no short-packet notion: only
/// exact Success will do.
pub fn cmdOk(cc: u32) bool {
    return cc == CC_SUCCESS;
}

/// A TRANSFER completion that delivered valid data: Success, or Short Packet.
pub fn xferOk(cc: u32) bool {
    return cc == CC_SUCCESS or cc == CC_SHORT_PACKET;
}

/// A "Stopped" transfer completion — the benign echo of a Stop Endpoint command
/// or a dequeue-pointer move, NOT a device fault. Delivered no data and needs no
/// recovery: the endpoint is (or is about to be) re-armed by the code that
/// stopped it. See CC_STOPPED.
pub fn xferStopped(cc: u32) bool {
    return cc == CC_STOPPED or cc == CC_STOPPED_LENGTH_INVALID or cc == CC_STOPPED_SHORT_PACKET;
}

/// A transfer completion that may have HALTED the endpoint, and therefore needs
/// recovery (Reset Endpoint + Set TR Dequeue) before the endpoint runs anything
/// further. That is any completion which is neither valid data (Success/Short-
/// Packet) NOR a benign Stopped echo — STALL, transaction error, babble, etc.
/// Treating only STALL as halting left EP0 and the interrupt-IN endpoint wedged
/// after a transaction error, and the device silently died for the session.
/// Treating a STOPPED echo as needing recovery, in turn, re-stopped a
/// just-re-armed endpoint forever (the HID keyboard/mouse freeze on lemon's
/// controller).
pub fn xferNeedsRecovery(cc: u32) bool {
    return !xferOk(cc) and !xferStopped(cc);
}

/// A human name for a completion code — for the trace, where "cc=3" costs a
/// debugging session and "babble" ends one.
pub fn ccName(cc: u32) []const u8 {
    return switch (cc) {
        CC_SUCCESS => "success",
        CC_BABBLE => "babble-detected", // the device sent MORE than the xHC expected
        CC_USB_TRANSACTION_ERROR => "transaction-error",
        CC_TRB_ERROR => "trb-error",
        CC_STALL => "stall",
        CC_SHORT_PACKET => "short-packet",
        CC_PARAMETER_ERROR => "parameter-error",
        CC_STOPPED => "stopped",
        CC_STOPPED_LENGTH_INVALID => "stopped-length-invalid",
        CC_STOPPED_SHORT_PACKET => "stopped-short-packet",
        CC_TIMEOUT => "timeout",
        else => "?",
    };
}
