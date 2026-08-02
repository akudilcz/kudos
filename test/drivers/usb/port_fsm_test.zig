//! Host tests of src/drivers/usb/port_fsm.zig.

const std = @import("std");
const port_fsm = @import("port_fsm");
const PLS_COMPLIANCE = port_fsm.PLS_COMPLIANCE;
const PLS_SS_INACTIVE = port_fsm.PLS_SS_INACTIVE;
const PORTSC_CCS = port_fsm.PORTSC_CCS;
const PORTSC_CSC = port_fsm.PORTSC_CSC;
const PORTSC_PED = port_fsm.PORTSC_PED;
const PORTSC_PP = port_fsm.PORTSC_PP;
const PORTSC_PRC = port_fsm.PORTSC_PRC;
const PORTSC_RW1C = port_fsm.PORTSC_RW1C;
const PORTSC_WRC = port_fsm.PORTSC_WRC;
const PORT_GIVE_UP = port_fsm.PORT_GIVE_UP;
const PortChangeAction = port_fsm.PortChangeAction;
const PortVerdict = port_fsm.PortVerdict;
const ResetFail = port_fsm.ResetFail;
const ResetKind = port_fsm.ResetKind;
const SPEED_FULL = port_fsm.SPEED_FULL;
const SPEED_HIGH = port_fsm.SPEED_HIGH;
const SPEED_LOW = port_fsm.SPEED_LOW;
const SPEED_SUPER = port_fsm.SPEED_SUPER;
const SPEED_SUPER_PLUS = port_fsm.SPEED_SUPER_PLUS;
const W_PORT_CONNECTION = port_fsm.W_PORT_CONNECTION;
const W_PORT_ENABLE = port_fsm.W_PORT_ENABLE;
const W_PORT_HIGH_SPEED = port_fsm.W_PORT_HIGH_SPEED;
const W_PORT_LOW_SPEED = port_fsm.W_PORT_LOW_SPEED;
const endpointInterval = port_fsm.endpointInterval;
const ep0MpsCorrection = port_fsm.ep0MpsCorrection;
const expectEqual = std.testing.expectEqual;
const hubChildSpeed = port_fsm.hubChildSpeed;
const hubResetEnabled = port_fsm.hubResetEnabled;
const hubResetFail = port_fsm.hubResetFail;
const isSuper = port_fsm.isSuper;
const maxPacketForSpeed = port_fsm.maxPacketForSpeed;
const portBit = port_fsm.portBit;
const portChangeAction = port_fsm.portChangeAction;
const portFailNext = port_fsm.portFailNext;
const portVerdict = port_fsm.portVerdict;
const portscNeutral = port_fsm.portscNeutral;
const rootResetComplete = port_fsm.rootResetComplete;
const rootResetFail = port_fsm.rootResetFail;
const rootResetKind = port_fsm.rootResetKind;

/// Test fixture: a PORTSC value for a SuperSpeed powered port with the given
/// connect/enable/link-state/reset bits.
fn mkPortsc(ccs: bool, ped: bool, pls: u32, pr: bool, wpr: bool) u32 {
    var v: u32 = PORTSC_PP | (@as(u32, SPEED_SUPER) << 10);
    if (ccs) v |= PORTSC_CCS;
    if (ped) v |= PORTSC_PED;
    v |= (pls << port_fsm.PORTSC_PLS_SHIFT) & port_fsm.PORTSC_PLS_MASK;
    if (pr) v |= port_fsm.PORTSC_PR;
    if (wpr) v |= port_fsm.PORTSC_WPR;
    return v;
}

test "rootResetComplete: PED + PLS==U0 + CCS + reset clear, and nothing less" {
    try expectEqual(true, rootResetComplete(mkPortsc(true, true, 0, false, false)));
    // Hot reset still asserted.
    try expectEqual(false, rootResetComplete(mkPortsc(true, true, 0, true, false)));
    // WARM reset still asserted (PR clear) — must also gate completion.
    try expectEqual(false, rootResetComplete(mkPortsc(true, true, 0, false, true)));
    // Not enabled.
    try expectEqual(false, rootResetComplete(mkPortsc(true, false, 0, false, false)));
    // Link not in U0 (still retraining / Polling=7).
    try expectEqual(false, rootResetComplete(mkPortsc(true, true, 7, false, false)));
    // Device left: enabled but no connect — retraining wait must not pass.
    try expectEqual(false, rootResetComplete(mkPortsc(false, true, 0, false, false)));
}

test "rootResetKind: SS.Inactive and Compliance escalate to warm, all else hot" {
    try expectEqual(ResetKind.warm, rootResetKind(mkPortsc(true, false, PLS_SS_INACTIVE, false, false)));
    try expectEqual(ResetKind.warm, rootResetKind(mkPortsc(true, false, PLS_COMPLIANCE, false, false)));
    try expectEqual(ResetKind.hot, rootResetKind(mkPortsc(true, true, 0, false, false))); // U0
    try expectEqual(ResetKind.hot, rootResetKind(mkPortsc(true, false, 5, false, false))); // RxDetect
    try expectEqual(ResetKind.hot, rootResetKind(mkPortsc(true, false, 7, false, false))); // Polling
}

test "rootResetFail: device gone during reset abandons, otherwise retry" {
    try expectEqual(ResetFail.vanished, rootResetFail(mkPortsc(false, false, 5, false, false)));
    try expectEqual(ResetFail.retry, rootResetFail(mkPortsc(true, false, 7, false, false)));
}

test "hub downstream reset: enable bit, vanish vs retry, child speed decode (PER-004)" {
    try expectEqual(true, hubResetEnabled(W_PORT_CONNECTION | W_PORT_ENABLE));
    try expectEqual(false, hubResetEnabled(W_PORT_CONNECTION));
    try expectEqual(ResetFail.vanished, hubResetFail(0));
    try expectEqual(ResetFail.retry, hubResetFail(W_PORT_CONNECTION));
    // Children of an SS hub are SS regardless of the status bits.
    try expectEqual(@as(u32, SPEED_SUPER), hubChildSpeed(SPEED_SUPER, W_PORT_CONNECTION));
    // USB2 hub: bit 9 low, bit 10 high, neither full.
    try expectEqual(@as(u32, SPEED_LOW), hubChildSpeed(SPEED_HIGH, W_PORT_CONNECTION | W_PORT_LOW_SPEED));
    try expectEqual(@as(u32, SPEED_HIGH), hubChildSpeed(SPEED_HIGH, W_PORT_CONNECTION | W_PORT_HIGH_SPEED));
    try expectEqual(@as(u32, SPEED_FULL), hubChildSpeed(SPEED_HIGH, W_PORT_CONNECTION));
}

test "endpointInterval: HS/SS exponent passthrough with clamp [1,16]-1" {
    // bInterval 0 clamps up to 1 → exponent 0 (not underflow).
    try expectEqual(@as(u32, 0), endpointInterval(SPEED_HIGH, 0));
    try expectEqual(@as(u32, 0), endpointInterval(SPEED_HIGH, 1));
    try expectEqual(@as(u32, 3), endpointInterval(SPEED_SUPER, 4)); // 2^3 * 125µs = 1ms
    try expectEqual(@as(u32, 15), endpointInterval(SPEED_SUPER, 16));
    // Above 16 clamps down to 16 → 15.
    try expectEqual(@as(u32, 15), endpointInterval(SPEED_HIGH, 255));
}

test "endpointInterval: FS/LS frames → floor(log2(frames*8)) clamped to [3,10]" {
    // 1ms frame → 8 µframes → exp 3 (also the clamp floor).
    try expectEqual(@as(u32, 3), endpointInterval(SPEED_FULL, 1));
    try expectEqual(@as(u32, 3), endpointInterval(SPEED_LOW, 0)); // frames floor at 1
    try expectEqual(@as(u32, 4), endpointInterval(SPEED_FULL, 2));
    try expectEqual(@as(u32, 6), endpointInterval(SPEED_LOW, 8)); // 64 µframes → 6
    try expectEqual(@as(u32, 6), endpointInterval(SPEED_FULL, 10)); // floor(log2(80)) = 6
    try expectEqual(@as(u32, 9), endpointInterval(SPEED_FULL, 64)); // 512 µframes → 9
    // 255 frames → 2040 µframes → floor(log2) = 10, the clamp ceiling.
    try expectEqual(@as(u32, 10), endpointInterval(SPEED_FULL, 255));
}

test "portBit: 1-based ports map to bits, out-of-range latches nothing" {
    try expectEqual(@as(u32, 0), portBit(0));
    try expectEqual(@as(u32, 1), portBit(1));
    try expectEqual(@as(u32, 0x8000_0000), portBit(32));
    try expectEqual(@as(u32, 0), portBit(33));
}

test "portChangeAction: the owned-port no-op prevents duplicate-slot re-enumeration" {
    try expectEqual(PortChangeAction.enumerate, portChangeAction(true, false));
    try expectEqual(PortChangeAction.remove, portChangeAction(false, true));
    // Connected AND owned: the boot resets latched a PSCE for a device we
    // already enumerated — re-running bringUp here created a duplicate slot.
    try expectEqual(PortChangeAction.ignore, portChangeAction(true, true));
    try expectEqual(PortChangeAction.ignore, portChangeAction(false, false));
}

test "portscNeutral strips every write-1 bit and keeps status" {
    const v: u32 = PORTSC_CCS | PORTSC_PED | PORTSC_PP | PORTSC_CSC | PORTSC_PRC |
        PORTSC_WRC | (3 << 10);
    const n = portscNeutral(v);
    try expectEqual(@as(u32, 0), n & PORTSC_RW1C);
    try expectEqual(@as(u32, PORTSC_CCS | PORTSC_PP | (3 << 10)), n);
}

test "regression: a successful hub/MSC enumeration is NOT a port failure" {
    // THE BUG. The verdict was `ndev == before`, and `ndev` counts HID devices
    // only — so `.ok_hub` and `.ok_msc` (which never touch it) read as failures.
    // Plugging a WORKING USB stick into the same root port three times in one boot
    // drove fail_count to PORT_GIVE_UP and blacklisted that port for the rest of
    // the boot, including for a keyboard plugged in next. The verdict must come
    // from the bring-up OUTCOME, and every success arm must count as one.
    var fails: u8 = 0;
    for (0..5) |_| { // five plug cycles of a device that enumerates fine
        const v = portVerdict(true, fails);
        try expectEqual(PortVerdict.ok, v);
        fails = portFailNext(v, fails);
        try expectEqual(@as(u8, 0), fails); // never accumulates
    }
}

test "portVerdict: a port that never enumerates is given up after PORT_GIVE_UP tries" {
    var fails: u8 = 0;
    try expectEqual(PortVerdict.fail, portVerdict(false, fails));
    fails = portFailNext(.fail, fails);
    try expectEqual(@as(u8, 1), fails);

    try expectEqual(PortVerdict.fail, portVerdict(false, fails));
    fails = portFailNext(.fail, fails);
    try expectEqual(@as(u8, 2), fails);

    // The third consecutive failure is the last one we attempt.
    try expectEqual(PortVerdict.give_up, portVerdict(false, fails));
    fails = portFailNext(.give_up, fails);
    try expectEqual(PORT_GIVE_UP, fails);
}

test "portVerdict: one success clears a history of failures" {
    // The count means failures IN A ROW. A flaky device that finally comes up must
    // not leave the port one attempt away from being abandoned.
    var fails: u8 = portFailNext(.fail, portFailNext(.fail, 0));
    try expectEqual(@as(u8, 2), fails);
    fails = portFailNext(portVerdict(true, fails), fails);
    try expectEqual(@as(u8, 0), fails);
}

test "regression: SuperSpeedPlus EP0 is 512 — the Phison babble" {
    // THE BUG. spd=5 fell through to the `else` arm's low-speed default of 8, EP0 was
    // programmed with a max packet size of 8, and the stick answered an 18-byte
    // descriptor read with a 512-byte packet — BABBLE (cc=3), every time, forever.
    // Gen1 and Gen2 must BOTH land on 512.
    try expectEqual(@as(u32, 512), maxPacketForSpeed(SPEED_SUPER));
    try expectEqual(@as(u32, 512), maxPacketForSpeed(SPEED_SUPER_PLUS));
    // Stated as the property, so a future speed ID cannot quietly regress it:
    // anything isSuper() accepts has a 512-byte EP0.
    for ([_]u32{ SPEED_SUPER, SPEED_SUPER_PLUS }) |s| {
        try std.testing.expect(isSuper(s));
        try expectEqual(@as(u32, 512), maxPacketForSpeed(s));
    }
}

test "maxPacketForSpeed: the fixed speeds, and full speed's optimistic guess" {
    try expectEqual(@as(u32, 8), maxPacketForSpeed(SPEED_LOW));
    try expectEqual(@as(u32, 64), maxPacketForSpeed(SPEED_HIGH));
    // Full speed may legally be 8/16/32/64. Guessing 64 (Linux parity) and correcting
    // beats guessing 8: an 8-byte guess fragments a 64-byte EP0's data stage on real
    // HW and the descriptor read errors out.
    try expectEqual(@as(u32, 64), maxPacketForSpeed(SPEED_FULL));
    try expectEqual(@as(u32, 8), maxPacketForSpeed(0)); // unknown: the safe floor
}

test "ep0MpsCorrection: only full speed corrects, and only to a legal value" {
    // A fixed-speed device is never corrected — its EP0 size is spec, not descriptor.
    try expectEqual(@as(?u32, null), ep0MpsCorrection(SPEED_SUPER_PLUS, 9));
    try expectEqual(@as(?u32, null), ep0MpsCorrection(SPEED_HIGH, 8));

    // Full speed: the four legal values, and 64 is already the guess (no round-trip).
    try expectEqual(@as(?u32, 8), ep0MpsCorrection(SPEED_FULL, 8));
    try expectEqual(@as(?u32, 16), ep0MpsCorrection(SPEED_FULL, 16));
    try expectEqual(@as(?u32, 32), ep0MpsCorrection(SPEED_FULL, 32));
    try expectEqual(@as(?u32, null), ep0MpsCorrection(SPEED_FULL, 64));

    // Garbage from a half-read descriptor must NOT reach the endpoint context.
    for ([_]u8{ 0, 1, 7, 9, 63, 65, 255 }) |bad| {
        try expectEqual(@as(?u32, null), ep0MpsCorrection(SPEED_FULL, bad));
    }
}
