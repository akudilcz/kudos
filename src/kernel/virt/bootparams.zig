//! The boot_params "zero page" builder (Linux/x86 boot protocol; struct
//! boot_params in arch/x86/include/uapi/asm/bootparam.h). Pure: it fills a
//! 4 KiB page the guest kernel reads from RSI at entry. Host-tested
//! (test/kernel/virt/bootparams_test.zig) by asserting the byte-exact field offsets, because a
//! misplaced field is a boot the guest silently fails.
//!
//! The zero page is the setup header copied out of the kernel image, with the
//! loader-owned fields overwritten: loader type, the LOADED_HIGH flag, the
//! command-line pointer, the initramfs location, and the E820 table.

const std = @import("std");
pub const layout = @import("layout.zig");
pub const e820 = @import("e820.zig");

// boot_params field offsets (bootparam.h). The setup header is embedded at 0x1F1.
const OFF_ACPI_RSDP_ADDR: usize = 0x070; // __u64 physical address of the ACPI RSDP
const OFF_E820_ENTRIES: usize = 0x1E8; // __u8 count
const OFF_SETUP_HEADER: usize = 0x1F1;
const OFF_HEADER_END_MARKER: usize = 0x201; // byte whose value + 0x202 ends the header
const OFF_TYPE_OF_LOADER: usize = 0x210;
const OFF_LOADFLAGS: usize = 0x211;
const OFF_RAMDISK_IMAGE: usize = 0x218;
const OFF_RAMDISK_SIZE: usize = 0x21C;
const OFF_CMD_LINE_PTR: usize = 0x228;
const OFF_E820_TABLE: usize = 0x2D0; // array of 20-byte boot_e820_entry

const LOADFLAG_LOADED_HIGH: u8 = 1 << 0;
const LOADER_TYPE_UNDEFINED: u8 = 0xFF; // "undefined bootloader" — accepted by Linux
const E820_ENTRY_BYTES: usize = 20;

/// Build the zero page from the kernel image's setup header and the resolved
/// layout. `image` is the whole bzImage (the header lives in its first sector);
/// `entries` is the E820 map from e820.forRam.
pub fn build(zero_page: *[4096]u8, image: []const u8, lay: layout.Layout, entries: []const e820.Entry) void {
    @memset(zero_page, 0);

    // Copy the setup header verbatim. Its end is 0x202 + the byte at 0x201
    // (boot.rst); clamp to the image and page in case of a short header.
    const hdr_end = @min(@min(0x202 + @as(usize, image[OFF_HEADER_END_MARKER]), image.len), zero_page.len);
    if (hdr_end > OFF_SETUP_HEADER) {
        @memcpy(zero_page[OFF_SETUP_HEADER..hdr_end], image[OFF_SETUP_HEADER..hdr_end]);
    }

    // Loader-owned overrides.
    zero_page[OFF_TYPE_OF_LOADER] = LOADER_TYPE_UNDEFINED;
    zero_page[OFF_LOADFLAGS] |= LOADFLAG_LOADED_HIGH;
    wr32(zero_page, OFF_CMD_LINE_PTR, @truncate(lay.cmdline_gpa));
    // Point the kernel straight at the ACPI RSDP (Linux >= 5.0). Without a
    // MADT the guest's `init_bsp_APIC` reaches for the xAPIC MMIO window it
    // never mapped and dies before it has a console — see virt/acpi.zig.
    wr64(zero_page, OFF_ACPI_RSDP_ADDR, lay.acpi_gpa);
    wr32(zero_page, OFF_RAMDISK_IMAGE, @truncate(lay.initrd_gpa));
    wr32(zero_page, OFF_RAMDISK_SIZE, @truncate(lay.initrd_len));

    // E820 table.
    zero_page[OFF_E820_ENTRIES] = @truncate(entries.len);
    for (entries, 0..) |e, i| {
        const off = OFF_E820_TABLE + i * E820_ENTRY_BYTES;
        wr64(zero_page, off, e.addr);
        wr64(zero_page, off + 8, e.size);
        wr32(zero_page, off + 16, e.typ);
    }
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn wr64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}
