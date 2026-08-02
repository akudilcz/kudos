//! USB port state decisions. Pure logic — the register/hub-status sampling,
//! sleeps, and retry loops live in the driver (xhci.zig); this owns the
//! PORTSC / wPortStatus → verdict decisions, the endpoint-interval encoding,
//! and the root-port-change action table. Mirrors Linux
//! `hub_port_reset`/`hub_port_wait_reset`/`hub_event` (linux-source-7.0.0
//! drivers/usb/core/hub.c) and `xhci_get_endpoint_interval` (xhci-mem.c).

// PORTSC bits (xHCI §5.4.8). CCS/speed are read-only; PED + the change bits
// are write-1 semantics (writing 1 disables/clears), so a read-modify-write
// must zero them or it will clobber state it never meant to touch.
pub const PORTSC_CCS = 1 << 0; // current connect status (RO)
pub const PORTSC_PED = 1 << 1; // port enabled/disabled (write-1-to-disable)
pub const PORTSC_PR = 1 << 4; // port reset
pub const PORTSC_PLS_SHIFT = 5; // port link state (bits 5-8); U0 == 0
pub const PORTSC_PLS_MASK = @as(u32, 0xF) << PORTSC_PLS_SHIFT;
pub const PORTSC_PP = 1 << 9; // port power
pub const PORTSC_CSC = 1 << 17; // connect status change (RW1C)
pub const PORTSC_PRC = 1 << 21; // port reset change (RW1C)
pub const PORTSC_WRC = 1 << 19; // warm reset change (RW1C)
pub const PORTSC_WPR: u32 = 1 << 31; // warm port reset (SS only; write-1 to start)
// All change bits (17..23): CSC PEC WRC OCC PRC PLC CEC — the PSCE ack set.
pub const PORTSC_CHANGE_MASK: u32 = @as(u32, 0x7F) << 17;
// Write-1-to-clear / write-1-to-disable bits: PED (1) and change bits 17..23.
pub const PORTSC_RW1C = PORTSC_PED | PORTSC_CHANGE_MASK;
// Link states (PLS) that mean a SuperSpeed link is wedged beyond a hot reset —
// Linux hub_port_warm_reset_required: escalate to a WARM reset.
pub const PLS_SS_INACTIVE: u32 = 6;
pub const PLS_COMPLIANCE: u32 = 10;

// xHCI PORTSC speed IDs (also the slot-context speed field): 1=Full, 2=Low,
// 3=High, 4=Super.
pub const SPEED_FULL = 1;
pub const SPEED_LOW = 2;
pub const SPEED_HIGH = 3;
pub const SPEED_SUPER = 4;
/// SuperSpeedPlus (USB 3.1 Gen2, 10 Gb/s). A DISTINCT PORTSC speed ID from
/// SuperSpeed. Omitting it makes a spd=5 port fall through to the low-speed
/// default, EP0 is programmed with a max packet size of 8, and the device answers
/// an 18-byte descriptor read with a 512-byte packet — which the xHC reports as
/// BABBLE (cc=3). It behaves exactly like SuperSpeed for our purposes;
/// what matters is that it is not treated as "unknown".
pub const SPEED_SUPER_PLUS = 5;

/// True for any USB 3.x speed (SuperSpeed or SuperSpeedPlus). Use this rather than
/// `== SPEED_SUPER`, so a Gen2 port is never mistaken for an unknown speed.
pub fn isSuper(speed: u32) bool {
    return speed == SPEED_SUPER or speed == SPEED_SUPER_PLUS;
}

/// EP0's max packet size to program before the device descriptor has been read —
/// the chicken-and-egg of enumeration (you need EP0 to read the descriptor that
/// tells you EP0's size). Low speed is fixed at 8 and high/super are fixed
/// (64/512), but FULL speed may be 8/16/32/64, so Linux guesses 64 and corrects via
/// Evaluate Context once bMaxPacketSize0 is known (see ep0MpsCorrection).
///
/// GUESSING 8 IS NOT A SAFE DEFAULT. A SuperSpeedPlus port falling through to the
/// `else` arm gets an 8-byte EP0, the device answers an 18-byte descriptor read with a
/// 512-byte packet, and the xHC reports BABBLE (cc=3) — every time, forever. Any new
/// speed ID must land on a deliberate arm here.
pub fn maxPacketForSpeed(speed: u32) u32 {
    return switch (speed) {
        SPEED_LOW => 8,
        SPEED_FULL => 64, // optimistic; corrected once bMaxPacketSize0 is known
        SPEED_HIGH => 64,
        SPEED_SUPER, SPEED_SUPER_PLUS => 512, // USB 3.x EP0 is FIXED at 512, Gen1 and Gen2 alike
        else => 8,
    };
}

/// The corrected EP0 max-packet size once the device descriptor's bMaxPacketSize0
/// is in hand, or null for "leave the guess in place".
///
/// Only FULL speed can be wrong (every other speed is fixed by the spec), and only
/// the four legal values are accepted — a garbage byte from a half-read descriptor
/// must not be programmed into the endpoint context. Returns null when the value is
/// already what we guessed, so the caller can skip the Evaluate Context round-trip.
pub fn ep0MpsCorrection(speed: u32, b_max_packet_size0: u8) ?u32 {
    if (speed != SPEED_FULL) return null;
    const want: u32 = switch (b_max_packet_size0) {
        8, 16, 32, 64 => b_max_packet_size0,
        else => return null, // implausible; keep the guess rather than trust it
    };
    if (want == maxPacketForSpeed(SPEED_FULL)) return null; // already correct
    return want;
}

// Hub wPortStatus bits (USB 2.0 §11.24.2.7 / GET_STATUS(port)).
pub const W_PORT_CONNECTION: u32 = 1 << 0;
pub const W_PORT_ENABLE: u32 = 1 << 1;
pub const W_PORT_LOW_SPEED: u32 = 1 << 9;
pub const W_PORT_HIGH_SPEED: u32 = 1 << 10;

/// A PORTSC value safe to OR an action bit into: current contents with every
/// write-1 (RW1C / disable) bit zeroed, so the write only does what we add.
pub fn portscNeutral(v: u32) u32 {
    return v & ~PORTSC_RW1C;
}

/// Which reset a root-port attempt should issue. A SuperSpeed link wedged in
/// SS.Inactive or Compliance Mode is beyond a hot reset's reach — escalate to
/// a WARM reset (Linux hub_port_warm_reset_required; PORTSC.WPR).
pub const ResetKind = enum { hot, warm };

pub fn rootResetKind(portsc: u32) ResetKind {
    const pls = (portsc & PORTSC_PLS_MASK) >> PORTSC_PLS_SHIFT;
    return if (pls == PLS_SS_INACTIVE or pls == PLS_COMPLIANCE) .warm else .hot;
}

/// True once a root-port reset attempt has completed: reset (hot AND warm)
/// de-asserted, port Enabled, link trained to U0, AND still connected — the
/// connect requirement makes the wait cover USB3 link retraining, not just
/// reset de-assertion (Linux hub_port_wait_reset).
pub fn rootResetComplete(portsc: u32) bool {
    const resetting = (portsc & (PORTSC_PR | PORTSC_WPR)) != 0;
    return !resetting and (portsc & PORTSC_PED) != 0 and
        (portsc & PORTSC_PLS_MASK) == 0 and (portsc & PORTSC_CCS) != 0;
}

/// What a timed-out reset attempt means for the retry loop: a device that left
/// during reset is abandoned outright — retrying an empty port only slows the
/// scan (Linux -ENOTCONN); otherwise the next attempt runs.
pub const ResetFail = enum { retry, vanished };

pub fn rootResetFail(portsc: u32) ResetFail {
    return if ((portsc & PORTSC_CCS) == 0) .vanished else .retry;
}

/// True once a hub downstream-port reset attempt has enabled the port
/// (wPortStatus PORT_ENABLE).
pub fn hubResetEnabled(w_port_status: u32) bool {
    return (w_port_status & W_PORT_ENABLE) != 0;
}

/// The downstream analogue of rootResetFail, from wPortStatus: connection bit
/// clear = device gone — abandon (Linux -ENOTCONN); otherwise retry.
pub fn hubResetFail(w_port_status: u32) ResetFail {
    return if ((w_port_status & W_PORT_CONNECTION) == 0) .vanished else .retry;
}

/// Speed of the device on an enabled hub downstream port. Children of a
/// SuperSpeed hub are SuperSpeed by construction (the USB2 bus doesn't route
/// through it — Linux hub_port_connect); otherwise wPortStatus bit 9 = low
/// speed, bit 10 = high speed, neither = full speed.
pub fn hubChildSpeed(hub_speed: u32, w_port_status: u32) u32 {
    if (isSuper(hub_speed)) return hub_speed; // Gen1 AND Gen2: a USB3 hub's children are USB3
    if ((w_port_status & W_PORT_LOW_SPEED) != 0) return SPEED_LOW;
    if ((w_port_status & W_PORT_HIGH_SPEED) != 0) return SPEED_HIGH;
    return SPEED_FULL;
}

/// xHCI endpoint-context Interval (DW0 bits 16-23): the exponent N where the
/// xHC services the endpoint every 2^N * 125µs. Computed from the endpoint's
/// `bInterval` per the device speed (xHCI §6.2.3.6, mirrors Linux
/// xhci_get_endpoint_interval). Leaving this 0 means "every 125µs", which on
/// real HW over-allocates periodic bandwidth (Configure Endpoint Bandwidth
/// Error) or hammers a slow HID device far faster than it asked for (NAK
/// storms).
pub fn endpointInterval(speed: u32, b_interval: u8) u32 {
    switch (speed) {
        SPEED_HIGH, SPEED_SUPER, SPEED_SUPER_PLUS => {
            // bInterval is already a 2^(bInterval-1) microframe exponent encoding.
            const bi: u32 = @max(@as(u32, 1), @min(@as(u32, b_interval), 16));
            return bi - 1;
        },
        else => {
            // Full/low speed interrupt: bInterval is in 1ms frames. Convert to a
            // microframe exponent: floor(log2(bInterval*8)), clamped to [3,10].
            const frames: u32 = @max(@as(u32, 1), @as(u32, b_interval));
            const microframes = frames * 8;
            var exp: u32 = 0;
            while ((@as(u32, 1) << @intCast(exp + 1)) <= microframes) exp += 1;
            return @max(@as(u32, 3), @min(exp, 10));
        },
    }
}

/// The bit for root port N (1-based) in the pending/owned bitmaps; 0 for a
/// port outside 1..32 so an out-of-range port id from the controller latches
/// nothing.
pub fn portBit(port: u32) u32 {
    if (port < 1 or port > 32) return 0;
    return @as(u32, 1) << @intCast(port - 1);
}

/// What a latched Port Status Change on a root port means, from the port's
/// current connect status and whether the port already owns an enumerated
/// device (Linux hub_event for the root hub):
///   - connected, not owned  → enumerate (new/late/bounced connect)
///   - disconnected, owned   → remove the port's devices
///   - connected, owned      → IGNORE: the boot resets themselves latch PSCEs;
///     without ownership tracking, a childless hub would be re-enumerated into
///     a DUPLICATE slot on the first post-boot poll.
///   - disconnected, not owned → ignore (nothing there, nothing tracked)
pub const PortChangeAction = enum { enumerate, remove, ignore };

pub fn portChangeAction(ccs: bool, owned: bool) PortChangeAction {
    if (ccs and !owned) return .enumerate;
    if (!ccs and owned) return .remove;
    return .ignore;
}

/// A root port that repeatedly fails to enumerate is eventually abandoned for the
/// rest of the boot: without a give-up, a port that can never come up re-arms a
/// change on every failure and is retried forever — a livelock that burns a
/// device slot per attempt and starves the session loop.
pub const PORT_GIVE_UP: u8 = 3;

/// What one enumeration attempt does to a root port's failure count.
///
/// `enumerated` MUST be the real outcome of the bring-up — a hub, a HID device and a
/// mass-storage device all count. Inferring it from a side effect that only moves for
/// SOME device classes (e.g. a HID-device counter) marks a healthy stick or an HID-less
/// hub as a FAILED enumeration, and enough of those blacklist the port for the boot.
pub const PortVerdict = enum { ok, fail, give_up };

pub fn portVerdict(enumerated: bool, fail_count: u8) PortVerdict {
    if (enumerated) return .ok; // resets the count — the port is fine
    return if (fail_count + 1 >= PORT_GIVE_UP) .give_up else .fail;
}

/// The failure count after applying a verdict. Success resets to zero: the count
/// means "failures IN A ROW", so one good enumeration clears the history.
pub fn portFailNext(v: PortVerdict, fail_count: u8) u8 {
    return switch (v) {
        .ok => 0,
        .fail, .give_up => fail_count +| 1,
    };
}
