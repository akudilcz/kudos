//! Emulated 8254 programmable interval timer (Intel 8254 datasheet), the
//! guest's legacy timer at I/O ports 0x40-0x43. Channel 0's output drives
//! IRQ 0 through the 8259 pair (i8259.zig), which is the ONLY timer a stock
//! distribution kernel has before it programs its local APIC — without it the
//! guest's jiffies never advance and early boot spins in `udelay` loops
//! forever, printing nothing.
//!
//! Pure state machine over a caller-supplied clock: the machine model routes
//! guest IN/OUT exits to `ioRead`/`ioWrite` and calls `expired` once per pump
//! slice with the current time, then raises IRQ 0 for each tick reported.
//! Nothing here reads a clock or touches hardware, so it is host-tested
//! (test/kernel/virt/i8254_test.zig).
//!
//! Modeled: channel 0 in modes 2 (rate generator) and 3 (square wave) — the
//! two Linux uses — plus mode 0 (interrupt on terminal count) for the
//! calibration path, the 16-bit LSB/MSB access sequence, latched counter
//! reads, and the read-back command. Channels 1 (DRAM refresh) and 2 (PC
//! speaker) accept writes and read back their counters but drive nothing:
//! no guest depends on their outputs, and pretending otherwise would invent
//! behavior. The BCD mode bit is rejected the way the hardware ignores it —
//! Linux never sets it.

/// Port map (8254 datasheet, "Programming the 8254").
pub const COUNTER0_PORT: u16 = 0x40;
pub const COUNTER1_PORT: u16 = 0x41;
pub const COUNTER2_PORT: u16 = 0x42;
pub const COMMAND_PORT: u16 = 0x43;

/// The PIT's input frequency: 1.193182 MHz on every PC, derived from the
/// 14.31818 MHz NTSC colour-burst crystal divided by 12. Linux hardcodes this
/// same constant (PIT_TICK_RATE), so the guest's arithmetic and ours agree.
pub const PIT_HZ: u64 = 1_193_182;

/// The master 8259 line channel 0's output is wired to on every PC.
pub const TIMER_IRQ: u4 = 0;

/// Control-word fields (8254 datasheet, "Control Word Format").
const CW_CHANNEL_SHIFT: u3 = 6; // bits 7:6 select the counter
const CW_ACCESS_SHIFT: u3 = 4; // bits 5:4 select the read/write sequence
const CW_MODE_SHIFT: u3 = 1; // bits 3:1 select the counting mode
const CW_BCD: u8 = 1 << 0; // bit 0 selects BCD counting (unused by any guest)

/// Bits 5:4 of the control word: how the 16-bit counter is accessed.
const Access = enum(u2) {
    /// 00: latch the counter for reading (a command, not a mode change).
    latch = 0,
    /// 01: read/write the low byte only.
    lsb_only = 1,
    /// 10: read/write the high byte only.
    msb_only = 2,
    /// 11: read/write low byte then high byte.
    lsb_then_msb = 3,
};

/// Which half of a two-byte access comes next.
const Phase = enum { lsb, msb };

/// A read-back command (control word with both channel-select bits set) asks
/// for status and/or count of the named counters instead of programming one.
const READBACK_SELECT: u8 = 0xC0;
const READBACK_LATCH_COUNT: u8 = 1 << 5; // bit 5 CLEAR latches the count
const READBACK_LATCH_STATUS: u8 = 1 << 4; // bit 4 CLEAR latches the status
const READBACK_CHANNEL0: u8 = 1 << 1;

/// A counter's full 16-bit reload value is written as 0, meaning 65536 — the
/// hardware wraps to its longest period rather than dividing by zero.
const RELOAD_ZERO_MEANS: u32 = 65536;

/// One counter. `count` is the programmed reload value (the divisor), not a
/// live countdown: the tick schedule is computed from the clock instead of
/// decremented, which is what keeps this pure and exit-free.
const Counter = struct {
    /// The reload value the guest programmed (1..65536).
    reload: u32 = RELOAD_ZERO_MEANS,
    mode: u3 = 0,
    access: Access = .lsb_then_msb,
    write_phase: Phase = .lsb,
    read_phase: Phase = .lsb,
    /// The partially written reload value between LSB and MSB writes.
    pending_lsb: u8 = 0,
    /// A latched counter value (`latch` access or a read-back), consumed by
    /// the next read.
    latched: ?u16 = null,
    /// Whether the guest has programmed this counter at all. An unprogrammed
    /// channel 0 must not manufacture interrupts.
    armed: bool = false,
    /// Status byte for a read-back: mode/access/BCD as last programmed, with
    /// the null-count flag clear (the count is always loaded once armed).
    fn status(self: Counter) u8 {
        return (@as(u8, @intFromEnum(self.access)) << CW_ACCESS_SHIFT) |
            (@as(u8, self.mode) << CW_MODE_SHIFT);
    }
};

/// The PIT: three counters plus the tick bookkeeping for channel 0.
pub const Pit = struct {
    counters: [3]Counter = .{ .{}, .{}, .{} },
    /// PIT-clock time (in PIT ticks since the machine started) at which
    /// channel 0's next output pulse is due. Only meaningful while armed.
    next_tick_pit: u64 = 0,
    /// Whether `next_tick_pit` has been seeded from a real clock reading.
    scheduled: bool = false,
    /// Output pulses that were due but not yet delivered as IRQ 0 — counted,
    /// never silently dropped, so a guest that was descheduled for a long
    /// while can be told how many ticks it missed (or have them coalesced by
    /// the caller, which is what Linux's lost-tick handling expects).
    pending_ticks: u64 = 0,
    /// Total pulses this PIT has produced — the counter a "is the guest's
    /// timer alive?" question is answered with.
    ticks_total: u64 = 0,

    /// Whether `port` belongs to the PIT.
    pub fn owns(port: u16) bool {
        return port >= COUNTER0_PORT and port <= COMMAND_PORT;
    }

    /// Guest OUT to a PIT port.
    pub fn ioWrite(self: *Pit, port: u16, val: u8) void {
        if (port == COMMAND_PORT) return self.writeControl(val);
        const idx: usize = port - COUNTER0_PORT;
        if (idx > 2) return;
        const c = &self.counters[idx];
        switch (c.access) {
            .lsb_only => self.loadReload(idx, val, 0),
            .msb_only => self.loadReload(idx, 0, val),
            .latch, .lsb_then_msb => switch (c.write_phase) {
                .lsb => {
                    c.pending_lsb = val;
                    c.write_phase = .msb;
                },
                .msb => {
                    c.write_phase = .lsb;
                    self.loadReload(idx, c.pending_lsb, val);
                },
            },
        }
    }

    /// Guest IN from a PIT port. The command port is write-only and reads as
    /// all-ones, like an unpopulated port.
    pub fn ioRead(self: *Pit, port: u16) u8 {
        if (port == COMMAND_PORT) return 0xFF;
        const idx: usize = port - COUNTER0_PORT;
        if (idx > 2) return 0xFF;
        const c = &self.counters[idx];
        const value: u16 = c.latched orelse @truncate(c.reload);
        switch (c.access) {
            .lsb_only => {
                c.latched = null;
                return @truncate(value);
            },
            .msb_only => {
                c.latched = null;
                return @truncate(value >> 8);
            },
            .latch, .lsb_then_msb => switch (c.read_phase) {
                .lsb => {
                    c.read_phase = .msb;
                    return @truncate(value);
                },
                .msb => {
                    c.read_phase = .lsb;
                    c.latched = null;
                    return @truncate(value >> 8);
                },
            },
        }
    }

    /// A control-port write: a read-back command, a latch command, or a
    /// counter's mode/access programming.
    fn writeControl(self: *Pit, val: u8) void {
        if (val & READBACK_SELECT == READBACK_SELECT) return self.readBack(val);
        const idx: usize = @as(u2, @truncate(val >> CW_CHANNEL_SHIFT));
        const c = &self.counters[idx];
        const access: Access = @enumFromInt(@as(u2, @truncate(val >> CW_ACCESS_SHIFT)));
        if (access == .latch) {
            c.latched = @truncate(c.reload);
            c.read_phase = .lsb;
            return;
        }
        c.access = access;
        c.mode = @truncate(val >> CW_MODE_SHIFT);
        c.write_phase = .lsb;
        c.read_phase = .lsb;
        // A mode write disarms the counter until its reload value is written:
        // the hardware's output is undefined until the count is loaded, and
        // manufacturing ticks from a half-programmed timer is worse than none.
        c.armed = false;
    }

    /// A read-back command: latch status and/or count for the named counters.
    /// Only channel 0's status is ever asked for in practice; the others are
    /// latched the same way for uniformity.
    fn readBack(self: *Pit, val: u8) void {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const selected = (val & (READBACK_CHANNEL0 << @as(u3, @intCast(i)))) != 0;
            if (!selected) continue;
            const c = &self.counters[i];
            if (val & READBACK_LATCH_STATUS == 0) {
                c.latched = c.status();
            } else if (val & READBACK_LATCH_COUNT == 0) {
                c.latched = @truncate(c.reload);
            }
            c.read_phase = .lsb;
        }
    }

    /// Load a counter's reload value and arm it. Channel 0's tick schedule
    /// restarts from the caller's next `expired` call.
    fn loadReload(self: *Pit, idx: usize, lsb: u8, msb: u8) void {
        const c = &self.counters[idx];
        const raw: u32 = (@as(u32, msb) << 8) | lsb;
        c.reload = if (raw == 0) RELOAD_ZERO_MEANS else raw;
        c.armed = true;
        if (idx == 0) self.scheduled = false; // reschedule from the next clock read
    }

    /// Channel 0's programmed period in PIT ticks. Mode 3 (square wave) pulses
    /// once per full reload period like mode 2 as far as the interrupt
    /// controller is concerned — the duty cycle differs, the interrupt rate
    /// does not.
    pub fn period(self: *const Pit) u64 {
        return self.counters[0].reload;
    }

    /// Advance channel 0 to `now_pit` (the current time expressed in PIT
    /// ticks) and report how many output pulses came due. Modes 2 and 3 are
    /// periodic; mode 0 fires exactly once per programmed count.
    ///
    /// Returns 0 whenever channel 0 is unprogrammed, so a guest that never
    /// touches the PIT sees no interrupts. `max_catch_up` bounds how many
    /// pulses one call may report: a guest descheduled for a second must not
    /// receive a thousand-interrupt storm, and the excess is left in
    /// `pending_ticks` rather than discarded silently.
    pub fn expired(self: *Pit, now_pit: u64, max_catch_up: u64) u64 {
        const c = &self.counters[0];
        if (!c.armed) return 0;
        if (!self.scheduled) {
            self.next_tick_pit = now_pit + self.period();
            self.scheduled = true;
            return 0;
        }
        while (now_pit >= self.next_tick_pit) {
            self.pending_ticks += 1;
            self.next_tick_pit += self.period();
            // Mode 0 fires once and then waits for a fresh count.
            if (c.mode == 0) {
                c.armed = false;
                break;
            }
        }
        const deliver = @min(self.pending_ticks, max_catch_up);
        self.pending_ticks -= deliver;
        self.ticks_total += deliver;
        return deliver;
    }
};
