//! 8042 controller ports + status bits. kudos takes no PS/2 input (keyboard and
//! mouse are USB HID); the 8042 survives ONLY as a CPU-reset mechanism —
//! kernel/power/reboot.zig pulses it as the first step of its reset chain. This
//! is the single home for those port numbers and the input-buffer-drain check.

const io = @import("io.zig");

pub const DATA: u16 = 0x60; // 8042 data port (unused for input; kept for completeness)
pub const STATUS: u16 = 0x64; // read controller status register
pub const COMMAND: u16 = 0x64; // write controller commands (same port as STATUS)

// Status-register bits.
const STR_IBF: u8 = 0x02; // input buffer full — not safe to write yet

/// Input buffer empty: it is safe to write the next byte to DATA/COMMAND.
pub fn inputEmpty() bool {
    return (io.inb(STATUS) & STR_IBF) == 0;
}
