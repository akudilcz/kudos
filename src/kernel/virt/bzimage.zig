//! Linux/x86 bzImage boot-protocol header parser (Documentation/x86/boot.rst).
//! Pure: it reads the setup header out of a kernel image and reports where the
//! protected-mode kernel lives and how the guest must be entered — it copies
//! nothing and touches no guest memory (virt/linuxload.zig does that). Host-tested
//! (test/kernel/virt/bzimage_test.zig) with synthetic headers, so a wrong offset is caught off
//! hardware rather than as a guest that never prints.
//!
//! kudos boots the guest through the 64-bit boot protocol only: the protected-mode
//! kernel is placed at its preferred address and entered at `pref_address + 0x200`
//! (startup_64) with the guest already in 64-bit mode — no real-mode setup code
//! runs, so only the header fields the loader needs are decoded.

const std = @import("std");

// Setup-header field offsets within the image (boot.rst "The Real-Mode Kernel
// Header" — the header begins at 0x1F1 and fields are named by their absolute
// image offset).
const OFF_SETUP_SECTS: usize = 0x1F1;
const OFF_BOOT_FLAG: usize = 0x1FE;
const OFF_HEADER_MAGIC: usize = 0x202;
const OFF_VERSION: usize = 0x206;
const OFF_LOADFLAGS: usize = 0x211;
const OFF_INITRD_ADDR_MAX: usize = 0x22C;
const OFF_XLOADFLAGS: usize = 0x236;
const OFF_CMDLINE_SIZE: usize = 0x238;
const OFF_PREF_ADDRESS: usize = 0x258;
const OFF_INIT_SIZE: usize = 0x260;

/// The setup header starts here; virt/bootparams.zig copies from this offset
/// through the end of the header into the boot_params zero page.
pub const SETUP_HEADER_OFFSET: usize = 0x1F1;

// Magic values.
const BOOT_FLAG: u16 = 0xAA55; // at 0x1FE, present on every bootable image
const HEADER_MAGIC: u32 = 0x53726448; // "HdrS" little-endian at 0x202
const MIN_VERSION: u16 = 0x020C; // 2.12 — first protocol with xloadflags
const XLF_KERNEL_64: u16 = 1 << 0; // 64-bit entry at pref_address+0x200 exists

/// The 64-bit kernel entry point is this far past the protected-mode load address
/// (startup_64 sits at the start of the pm kernel + 0x200). boot.rst §"64-bit BOOT
/// PROTOCOL".
pub const ENTRY64_OFFSET: u64 = 0x200;

/// What the loader needs from the header to place and enter the kernel.
pub const BzInfo = struct {
    /// Byte offset within the image where the protected-mode kernel begins, i.e.
    /// the size of the boot sector plus setup sectors.
    setup_bytes: usize,
    /// Protocol version (major.minor packed, e.g. 0x020F).
    version: u16,
    /// The image supports the 64-bit entry (XLF_KERNEL_64). Required by kudos.
    xlf_kernel_64: bool,
    /// Preferred (and, for us, actual) load address of the protected-mode kernel.
    pref_address: u64,
    /// Total memory the kernel needs at the load address for text/data/bss/heap.
    init_size: u32,
    /// Highest address the initramfs may occupy.
    initrd_addr_max: u32,
    /// Maximum kernel command-line length the kernel accepts (excluding the NUL).
    cmdline_size: u32,
};

pub const ParseError = error{ Truncated, BadMagic, TooOld, Not64Bit };

/// Parse the setup header. `image` must contain at least the full setup area; a
/// few KiB of head is enough because every field read here lives below 0x268.
pub fn parse(image: []const u8) ParseError!BzInfo {
    if (image.len < 0x268) return error.Truncated;
    if (rd16(image, OFF_BOOT_FLAG) != BOOT_FLAG) return error.BadMagic;
    if (rd32(image, OFF_HEADER_MAGIC) != HEADER_MAGIC) return error.BadMagic;

    const version = rd16(image, OFF_VERSION);
    if (version < MIN_VERSION) return error.TooOld;

    const xlf = rd16(image, OFF_XLOADFLAGS);
    if (xlf & XLF_KERNEL_64 == 0) return error.Not64Bit;

    // setup_sects == 0 historically means 4 (boot.rst).
    var setup_sects: usize = image[OFF_SETUP_SECTS];
    if (setup_sects == 0) setup_sects = 4;
    const setup_bytes = (setup_sects + 1) * 512; // +1 for the boot sector itself
    if (image.len < setup_bytes) return error.Truncated;

    return .{
        .setup_bytes = setup_bytes,
        .version = version,
        .xlf_kernel_64 = true,
        .pref_address = rd64(image, OFF_PREF_ADDRESS),
        .init_size = rd32(image, OFF_INIT_SIZE),
        .initrd_addr_max = rd32(image, OFF_INITRD_ADDR_MAX),
        .cmdline_size = rd32(image, OFF_CMDLINE_SIZE),
    };
}

/// The command-line length limit the header declares, clamped to a sane floor for
/// older headers that leave it zero (boot.rst: protocols < 2.06 imply 255).
pub fn effectiveCmdlineMax(info: BzInfo) usize {
    return if (info.cmdline_size == 0) 255 else info.cmdline_size;
}

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}
