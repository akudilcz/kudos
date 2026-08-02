//! Guest-physical memory map and boot-artifact placement (the "what goes where"
//! for a Firecracker-style Linux boot). Pure: `plan` computes addresses and
//! validates fit; virt/linuxload.zig does the copying. Host-tested
//! (test/kernel/virt/layout_test.zig). One home for every guest GPA constant — nothing else in
//! the subsystem invents a guest address.
//!
//! The low megabyte holds the boot scaffolding we build (GDT, zero page, page
//! tables, command line); the protected-mode kernel loads at its preferred address
//! (16 MiB for a defconfig-ish kernel); the initramfs is placed as high as the
//! header permits. Two windows above RAM are deliberately left out of guest RAM
//! and unmapped in EPT, so that every guest access to either exits to the machine
//! model's device router: the virtio-mmio window at 0xFEB00000, and the local-APIC
//! window at 0xFEE00000 — which a guest DOES touch, whenever it is using its APIC
//! through memory rather than through MSRs (virt/x2apic.zig serves both).

const std = @import("std");
pub const bzimage = @import("bzimage.zig");

pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_2M: u64 = 2 * 1024 * 1024;
pub const GIB: u64 = 1024 * 1024 * 1024;

// Fixed low-memory scaffolding addresses (all page-aligned, all below 1 MiB).
pub const GDT_GPA: u64 = 0x6000; // guest boot GDT (null, 64-bit code, data)
pub const ZERO_PAGE_GPA: u64 = 0x7000; // boot_params ("zero page")
pub const PT_PML4_GPA: u64 = 0x9000; // guest boot page tables: PML4 …
pub const PT_PDPT_GPA: u64 = 0xA000; // … PDPT …
pub const PT_PD_BASE_GPA: u64 = 0xB000; // … and the first PD (one PD per GiB)
/// ACPI tables: RSDP + XSDT + MADT. Inside the reserved BIOS window above
/// e820.LOW_RAM_TOP, for two reasons. It is where the ACPI specification says an
/// RSDP lives (0xE0000–0xFFFFF), which is the only way a kernel older than 5.0
/// can find it — `boot_params.acpi_rsdp_addr` did not exist before then, and such
/// a guest that cannot find a MADT falls back to reading its APIC through memory
/// and describes itself as having no topology at all. And it is outside usable
/// RAM, so the guest's own allocator can never hand the page out and overwrite
/// the tables it is still reading.
pub const ACPI_GPA: u64 = 0xE_0000;
pub const CMDLINE_GPA: u64 = 0x2_0000; // kernel command line (128 KiB mark)

/// The local-APIC MMIO window — a hole in the guest map, never backed by RAM, so
/// the guest's loads and stores there exit to the APIC model. One home for the
/// address: virt/acpi.zig tells the guest the same number in its MADT, and
/// virt/x2apic.zig reports it in IA32_APIC_BASE.
pub const LAPIC_GPA: u64 = 0xFEE0_0000;
pub const LAPIC_END: u64 = LAPIC_GPA + 0x1000;

/// Base of the virtio-mmio window — like the LAPIC, a hole above guest RAM,
/// never backed by RAM and never mapped in EPT, so every guest access exits to
/// the machine model's MMIO router. Same base QEMU's microvm machine uses, so
/// Linux's virtio-mmio driver is well-exercised at this address.
pub const VIRTIO_MMIO_GPA: u64 = 0xFEB0_0000;

/// One virtio-mmio device per 4 KiB page within the window.
pub const VIRTIO_MMIO_STRIDE: u64 = 0x1000;

/// The guest-visible virtio device map: window slot and PIC interrupt line for
/// every device the hypervisor can offer. The map is fixed here — the machine
/// model wires a slot only when it instantiates that device, and the kernel
/// command line advertises exactly the wired slots (`virtio_mmio.device=`).
/// Lines 5–7 sit on the master 8259; 9–10 on the slave (2 is the cascade).
pub const VirtioSlot = enum(u3) {
    gpu = 0,
    keyboard = 1,
    tablet = 2,
    net = 3,
    blk = 4,

    pub fn gpa(self: VirtioSlot) u64 {
        return VIRTIO_MMIO_GPA + @intFromEnum(self) * VIRTIO_MMIO_STRIDE;
    }

    pub fn irq(self: VirtioSlot) u4 {
        return switch (self) {
            .gpu => 5,
            .keyboard => 6,
            .tablet => 7,
            .net => 9,
            .blk => 10,
        };
    }
};

/// First GPA past the virtio window; the machine model routes
/// [VIRTIO_MMIO_GPA, VIRTIO_MMIO_END) to the wired device slots.
pub const VIRTIO_MMIO_END: u64 =
    VIRTIO_MMIO_GPA + (@typeInfo(VirtioSlot).@"enum".fields.len) * VIRTIO_MMIO_STRIDE;

/// The command-line fragment that tells Linux where a slot's device lives —
/// `virtio_mmio.device=<size>@<base>:<irq>`, the form
/// CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES parses. Generated from the same constants
/// the MMIO router decodes with, so the guest's view of the device map cannot
/// drift from the hypervisor's. There is no device tree and no PCI bus in a
/// kudos guest, so this is how a device is discovered at all.
pub fn cmdlineArg(comptime slot: VirtioSlot) []const u8 {
    return std.fmt.comptimePrint("virtio_mmio.device=4K@0x{x}:{d}", .{ slot.gpa(), slot.irq() });
}

/// Default guest RAM if the caller does not specify: 128 MiB, a whole number of
/// 2 MiB pages so the EPT builder uses large pages throughout.
pub const DEFAULT_RAM_BYTES: u64 = 128 * 1024 * 1024;

/// The resolved placement of every boot artifact in guest-physical memory.
pub const Layout = struct {
    ram_bytes: u64,
    kernel_gpa: u64,
    entry_rip: u64,
    kernel_end: u64,
    initrd_gpa: u64,
    initrd_len: usize,
    cmdline_gpa: u64,
    cmdline_len: usize,
    boot_params_gpa: u64,
    gdt_gpa: u64,
    pml4_gpa: u64,
    /// Where the guest's ACPI tables sit; handed to the kernel through
    /// `boot_params.acpi_rsdp_addr` so it needs no BIOS scan region.
    acpi_gpa: u64,
};

pub const PlanError = error{ NoFit, CmdlineTooLong, RamTooSmall };

/// Resolve where the kernel, initramfs, and command line land in `ram_bytes` of
/// guest RAM, given the parsed header. `pm_len` is the actual on-disk protected-mode
/// payload the loader will copy. Every field of `bz` is attacker-controlled, so this
/// is the single validating authority: it rejects rather than overlap or overflow,
/// and the loader trusts the returned placement without re-checking. The initramfs
/// is placed high but must clear the kernel image; everything must fit under the RAM
/// ceiling and the header's initrd address limit.
pub fn plan(ram_bytes: u64, bz: bzimage.BzInfo, pm_len: usize, initrd_len: usize, cmdline_len: usize) PlanError!Layout {
    if (ram_bytes % PAGE_2M != 0 or ram_bytes < 32 * 1024 * 1024) return error.RamTooSmall;
    if (cmdline_len + 1 > bzimage.effectiveCmdlineMax(bz)) return error.CmdlineTooLong;

    // Guest RAM must stop below the virtio-mmio window: the EPT offset map covers
    // exactly [0, ram_bytes), so RAM reaching the window would back the device
    // registers (and, further up, the LAPIC hole) with ordinary memory instead of
    // letting accesses exit to the MMIO router. This ceiling (< 4 GiB) also bounds
    // the boot page tables at four per-GiB page-directory pages from
    // PT_PD_BASE_GPA — nowhere near the command line at CMDLINE_GPA — and keeps
    // the single PDPT page within its 512 entries.
    if (ram_bytes > VIRTIO_MMIO_GPA) return error.NoFit;

    // The command line and its trailing NUL sit at CMDLINE_GPA; the kernel image
    // must load above the whole low scaffolding, not on top of it.
    const scaffold_top = CMDLINE_GPA + cmdline_len + 1;

    // The kernel occupies the larger of the header's init_size (text/data/bss/heap)
    // and the on-disk payload actually copied — validating only init_size would let
    // a small init_size hide a large payload and write past guest RAM. pref_address
    // is attacker-controlled, so guard the span add against u64 wrap.
    const kernel_gpa = bz.pref_address;
    if (kernel_gpa < scaffold_top) return error.NoFit;
    const kernel_span = @max(@as(u64, bz.init_size), @as(u64, pm_len));
    const kernel_end = std.math.add(u64, kernel_gpa, kernel_span) catch return error.NoFit;
    if (kernel_end > ram_bytes) return error.NoFit;

    // Place the initramfs at the top of usable RAM, page-aligned down, but no
    // higher than the header's initrd_addr_max.
    const ceiling = @min(ram_bytes, @as(u64, bz.initrd_addr_max) + 1);
    if (@as(u64, initrd_len) > ceiling) return error.NoFit;
    const initrd_gpa = alignDown(ceiling - initrd_len, PAGE_SIZE);
    if (initrd_gpa < kernel_end) return error.NoFit; // would clobber the kernel

    return .{
        .ram_bytes = ram_bytes,
        .kernel_gpa = kernel_gpa,
        .entry_rip = kernel_gpa + bzimage.ENTRY64_OFFSET,
        .kernel_end = kernel_end,
        .initrd_gpa = initrd_gpa,
        .initrd_len = initrd_len,
        .cmdline_gpa = CMDLINE_GPA,
        .cmdline_len = cmdline_len,
        .boot_params_gpa = ZERO_PAGE_GPA,
        .gdt_gpa = GDT_GPA,
        .pml4_gpa = PT_PML4_GPA,
        .acpi_gpa = ACPI_GPA,
    };
}

fn alignDown(v: u64, a: u64) u64 {
    return v & ~(a - 1);
}
