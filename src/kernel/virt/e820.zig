//! The E820 memory map the guest kernel reads from boot_params (boot.rst
//! "The e820 memory map"; struct boot_e820_entry in
//! arch/x86/include/uapi/asm/bootparam.h). Pure: builds the entry array;
//! virt/bootparams.zig writes it into the zero page. Host-tested (test/kernel/virt/e820_test.zig).
//!
//! Firecracker-style layout: two usable-RAM regions with the legacy hole below
//! 1 MiB (0x9FC00–0x100000) omitted so the guest never treats the BIOS/EBDA area
//! as normal RAM.

pub const E820_RAM: u32 = 1;
pub const E820_RESERVED: u32 = 2;

/// One BIOS E820 entry as a plain value carrier. The guest ABI entry
/// (struct boot_e820_entry) is a packed 20 bytes; virt/bootparams.zig serializes
/// these fields at that 20-byte stride, so this struct's in-memory layout is not
/// itself the ABI and needs no packing.
pub const Entry = struct {
    addr: u64,
    size: u64,
    typ: u32,
};

/// Below the legacy 1 MiB, usable RAM ends at the top of conventional memory
/// (0x9FC00 = 639 KiB), leaving the EBDA/BIOS region out.
pub const LOW_RAM_TOP: u64 = 0x9FC00;
/// Extended memory starts at 1 MiB.
pub const HIGH_RAM_BASE: u64 = 0x10_0000;

/// Fill `buf` with the E820 map for `ram_bytes` of guest RAM and return the used
/// slice. `buf` must hold at least 2 entries. RAM at or below the 1 MiB extended-
/// memory base yields a single low region (rather than underflowing the high
/// region's size), so the function is safe for any `ram_bytes`.
pub fn forRam(ram_bytes: u64, buf: []Entry) []Entry {
    if (ram_bytes <= HIGH_RAM_BASE) {
        buf[0] = .{ .addr = 0, .size = @min(ram_bytes, LOW_RAM_TOP), .typ = E820_RAM };
        return buf[0..1];
    }
    buf[0] = .{ .addr = 0, .size = LOW_RAM_TOP, .typ = E820_RAM };
    buf[1] = .{ .addr = HIGH_RAM_BASE, .size = ram_bytes - HIGH_RAM_BASE, .typ = E820_RAM };
    return buf[0..2];
}
