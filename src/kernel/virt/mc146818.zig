//! Emulated MC146818 real-time clock and CMOS RAM (Motorola MC146818A
//! datasheet), the guest's wall clock at I/O ports 0x70/0x71. Every Linux reads
//! it once, early, to set the system time from the "persistent clock" — and the
//! read is not defensive. `mach_get_cmos_time` spins on the update-in-progress
//! bit with the RTC spinlock held and interrupts off:
//!
//!     while ((CMOS_READ(RTC_FREQ_SELECT) & RTC_UIP))
//!             cpu_relax();
//!
//! An unemulated port reads as all-ones, so UIP reads as permanently set and
//! that loop never ends. A guest with no RTC does not lose its clock; it stops
//! booting, silently, right after "NR_IRQS", with every VM exit for the rest of
//! time being an I/O read of port 0x71.
//!
//! Pure state machine over a caller-supplied instant: the machine model routes
//! guest IN/OUT exits here and passes the civil time the guest should believe.
//! Nothing here reads a clock, does calendar arithmetic, or touches hardware, so
//! it is host-tested (test/kernel/virt/mc146818_test.zig).
//!
//! Modeled: the ten time/date/status registers, the index latch, and the CMOS
//! RAM behind it. UIP always reads clear, because there is no update in progress
//! — the time registers are computed at the instant they are read, so they can
//! never be caught half-updated, which is the only thing UIP exists to warn
//! about. The periodic/alarm/update interrupt enables in status B are stored and
//! read back but drive no interrupt: no guest needs IRQ 8 to boot, and
//! pretending to deliver it would invent behavior.

/// The instant the clock should report, as a civil UTC date and time. The
/// caller does the calendar arithmetic — timer/caldate.zig owns that, and this
/// device has no business reaching into the kernel's own clock — and this device
/// owns the MC146818's register format it is encoded into.
pub const Time = struct {
    second: u8,
    minute: u8,
    hour: u8,
    /// 1 = Sunday … 7 = Saturday, as the day-of-week register numbers them.
    weekday: u8,
    day: u8,
    month: u8,
    /// The full year, e.g. 2026: the device splits it into the two-digit year
    /// register and the PC/AT century register.
    year: u16,
};

/// Port map (PC/AT): an index latch and the data window it selects.
pub const INDEX_PORT: u16 = 0x70;
pub const DATA_PORT: u16 = 0x71;

/// Register numbers (MC146818A datasheet, Table 2; the century register is the
/// PC/AT extension every PC BIOS places at 0x32).
const REG_SECONDS: u8 = 0x00;
const REG_MINUTES: u8 = 0x02;
const REG_HOURS: u8 = 0x04;
const REG_WEEKDAY: u8 = 0x06;
const REG_DAY_OF_MONTH: u8 = 0x07;
const REG_MONTH: u8 = 0x08;
const REG_YEAR: u8 = 0x09;
const REG_STATUS_A: u8 = 0x0A;
const REG_STATUS_B: u8 = 0x0B;
const REG_STATUS_C: u8 = 0x0C;
const REG_STATUS_D: u8 = 0x0D;
const REG_CENTURY: u8 = 0x32;

/// How many registers the index latch can select. The MC146818 has 64; the
/// PC/AT's 128-byte part is what carries the century register at 0x32.
pub const REGISTERS: usize = 128;

/// Bit 7 of the index port is the NMI-disable line on a PC, not part of the
/// register number.
const INDEX_MASK: u8 = 0x7F;

/// Status register A (datasheet, "Register A"). UIP is bit 7 — the bit a Linux
/// guest spins on. The divider bits select the 32.768 kHz time base, which is
/// the only setting a PC ever uses; a guest that reads them back and finds
/// anything else concludes its clock is not running.
pub const STATUS_A_UIP: u8 = 0x80;
pub const STATUS_A_DIVIDER_32KHZ: u8 = 0x20; // bits 6:4 = 0b010

/// Status register B (datasheet, "Register B"): how the value registers are
/// encoded. The same two bits timer/rtc_decode.zig reads off real hardware.
pub const STATUS_B_24H: u8 = 0x02; // hours are 0..23, not 1..12 + a PM flag
pub const STATUS_B_BINARY: u8 = 0x04; // values are binary, not BCD

/// Status register D bit 7: the clock's battery is good and its RAM is valid.
/// Linux's rtc_cmos driver reports "broken or not accessible" without it.
pub const STATUS_D_VALID: u8 = 0x80;

pub const Cmos = struct {
    /// The register the data port currently addresses.
    index: u8 = 0,
    /// CMOS RAM. The time/date/status registers are computed on read rather
    /// than stored, so their slots here are unused; the rest is ordinary RAM
    /// that a guest may write and read back. Zero is the right initial value:
    /// the memory-size and equipment bytes a guest might read are ones no
    /// modern kernel consults (it has the E820 map), and zero is the honest
    /// answer for a machine that has no floppy drive and no PS/2 mouse.
    ram: [REGISTERS]u8 = .{0} ** REGISTERS,
    /// Status register B as the guest last wrote it. Starts at 24-hour BCD —
    /// the form this device encodes in and every PC BIOS leaves behind.
    status_b: u8 = STATUS_B_24H,

    pub fn owns(port: u16) bool {
        return port == INDEX_PORT or port == DATA_PORT;
    }

    /// Guest OUT to the index or data port.
    pub fn ioWrite(self: *Cmos, port: u16, val: u8) void {
        if (port == INDEX_PORT) {
            self.index = val & INDEX_MASK;
            return;
        }
        switch (self.index) {
            // The time and date are the host's, not the guest's: a guest that
            // sets its own clock changes only its own idea of the time, which
            // is a userspace matter. Accepting the write and then reporting the
            // real time back would be a lie; dropping it leaves the guest's
            // read-back consistent with what this clock actually is.
            REG_SECONDS, REG_MINUTES, REG_HOURS => {},
            REG_WEEKDAY, REG_DAY_OF_MONTH, REG_MONTH, REG_YEAR, REG_CENTURY => {},
            REG_STATUS_A, REG_STATUS_C, REG_STATUS_D => {},
            REG_STATUS_B => self.status_b = val,
            else => self.ram[self.index] = val,
        }
    }

    /// Guest IN from the index or data port. `now` is the instant the guest
    /// should read out of the clock.
    pub fn ioRead(self: *Cmos, port: u16, now: Time) u8 {
        // Reading the index port back is not something the hardware defines;
        // returning the latched index is at least self-consistent.
        if (port == INDEX_PORT) return self.index;
        return switch (self.index) {
            REG_SECONDS => bcd(now.second),
            REG_MINUTES => bcd(now.minute),
            REG_HOURS => bcd(now.hour),
            // 1..7 needs no BCD conversion: one digit encodes as itself.
            REG_WEEKDAY => now.weekday,
            REG_DAY_OF_MONTH => bcd(now.day),
            REG_MONTH => bcd(now.month),
            REG_YEAR => bcd(@intCast(now.year % 100)),
            REG_CENTURY => bcd(@intCast(now.year / 100)),
            // UIP clear, always: see the module comment. This is the read that
            // decides whether the guest boots.
            REG_STATUS_A => STATUS_A_DIVIDER_32KHZ,
            REG_STATUS_B => self.status_b,
            // Reading status C acknowledges and clears the interrupt flags.
            // Nothing here raises any, so it is always already clear.
            REG_STATUS_C => 0,
            REG_STATUS_D => STATUS_D_VALID,
            else => self.ram[self.index],
        };
    }
};

/// Pack a value below 100 as two binary-coded-decimal digits, which is how every
/// MC146818 time register reads unless a guest asks for binary (this one always
/// reports BCD, and says so in status B).
fn bcd(v: u8) u8 {
    return (v / 10) << 4 | (v % 10);
}
