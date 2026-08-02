//! Loads a Linux bzImage + initramfs into guest RAM and returns the initial vCPU
//! state for the 64-bit boot protocol. Pure: it operates on a `[]u8` that aliases
//! guest-physical memory (index == GPA), so it is host-tested (test/kernel/virt/linuxload_test.zig)
//! over an ordinary buffer with no hypervisor. virt/machine.zig owns the real guest
//! RAM and hands the slice in.
//!
//! Sequence: parse the header, plan placement, copy the protected-mode kernel to
//! its load address, place the initramfs high, write the command line, build the
//! zero page + E820 map, and build the guest's boot GDT and identity page tables.
//! The returned EntryState is what virt/vcpu.zig programs into guest VMCS state.

const std = @import("std");
const buildinfo = @import("buildinfo");
const klog = @import("../debug/klog.zig");
const bzimage = @import("bzimage.zig");
pub const layout = @import("layout.zig");
const e820 = @import("e820.zig");
const bootparams = @import("bootparams.zig");
const gpt = @import("gpt.zig");
const acpi = @import("acpi.zig");

/// The sole vCPU's local-APIC id, as the MADT must report it and as the
/// emulated APIC reports it through MSR_APIC_ID (virt/x2apic.zig). One fact:
/// a guest whose MADT disagrees with its APIC logs a firmware bug and
/// mis-describes its own topology.
const GUEST_APIC_ID: u8 = 0;

// Initial guest control-register / EFER state for a 64-bit-mode entry with paging
// on (Intel SDM Vol 3A; the VMX fixed-bit adjustment in vcpu.zig may add required
// bits, never remove these).
const CR0_PE: u64 = 1 << 0;
const CR0_NE: u64 = 1 << 5;
const CR0_PG: u64 = 1 << 31;
const CR4_PAE: u64 = 1 << 5;
const EFER_LME: u64 = 1 << 8;
const EFER_LMA: u64 = 1 << 10;

/// A safe initial guest stack pointer in free low RAM (below the command line at
/// 0x20000). The kernel resets RSP in startup_64 almost immediately, so this only
/// needs to be valid mapped memory.
const INITIAL_RSP: u64 = 0x1_0000;

/// The register/segment state the guest must start in for a 64-bit boot.
pub const EntryState = struct {
    rip: u64,
    rsi: u64, // boot_params pointer
    rsp: u64,
    cr0: u64,
    cr3: u64,
    cr4: u64,
    efer: u64,
    gdtr_base: u64,
    gdtr_limit: u32,
    cs_sel: u16,
    ds_sel: u16,
};

pub const LoadError = error{ Truncated, BadMagic, TooOld, Not64Bit, NoFit, CmdlineTooLong, RamTooSmall };

/// Load `bz_image` and `initrd` into `ram` with `cmdline`, returning the entry
/// state. `ram.len` is the guest RAM size; `cmdline` excludes the trailing NUL.
pub fn load(ram: []u8, bz_image: []const u8, initrd: []const u8, cmdline: []const u8) LoadError!EntryState {
    const bz = try bzimage.parse(bz_image);

    // The protected-mode kernel is everything past the setup area; plan validates
    // its actual length fits in guest RAM before we copy a byte.
    const pm = bz_image[bz.setup_bytes..];
    const lay = try layout.plan(ram.len, bz, pm.len, initrd.len, cmdline.len);

    copyInto(ram, lay.kernel_gpa, pm);

    // The initramfs, placed high by the planner.
    copyInto(ram, lay.initrd_gpa, initrd);

    // The command line, NUL-terminated.
    copyInto(ram, lay.cmdline_gpa, cmdline);
    ram[@intCast(lay.cmdline_gpa + cmdline.len)] = 0;

    // The zero page, from the image's setup header + the E820 map.
    var e820_buf: [8]e820.Entry = undefined;
    const entries = e820.forRam(ram.len, &e820_buf);
    const zp: *[4096]u8 = ram[@intCast(lay.boot_params_gpa)..][0..4096];
    bootparams.build(zp, bz_image, lay, entries);

    // The ACPI tables the zero page points at (see acpi.zig for why a guest
    // without them dies in native_init_IRQ).
    _ = acpi.build(ram[@intCast(lay.acpi_gpa)..][0..acpi.TOTAL_BYTES], lay.acpi_gpa, GUEST_APIC_ID);

    // The guest's own GDT and identity page tables.
    gpt.buildGdt(ram);
    gpt.buildIdentity(ram, ram.len);

    if (comptime buildinfo.test_hooks) {
        // What the guest will actually find: where its boot_params, command line
        // and initramfs were put, and the command line itself.
        var line: [200]u8 = undefined;
        const rec = std.fmt.bufPrint(&line, "virt: zp=0x{x} cl=0x{x} ird=0x{x}+{d}\n", .{
            lay.boot_params_gpa,
            lay.cmdline_gpa,
            lay.initrd_gpa,
            lay.initrd_len,
        }) catch "virt: load trace long\n";
        klog.puts(rec);
        const rec2 = std.fmt.bufPrint(&line, "virt: cmdline \"{s}\"\n", .{cmdline}) catch "virt: cmdline long\n";
        klog.puts(rec2);
    }

    return .{
        .rip = lay.entry_rip,
        .rsi = lay.boot_params_gpa,
        .rsp = INITIAL_RSP,
        .cr0 = CR0_PE | CR0_NE | CR0_PG,
        .cr3 = lay.pml4_gpa,
        .cr4 = CR4_PAE,
        .efer = EFER_LME | EFER_LMA,
        .gdtr_base = lay.gdt_gpa,
        .gdtr_limit = gpt.GDT_LIMIT,
        .cs_sel = gpt.SEL_CODE,
        .ds_sel = gpt.SEL_DATA,
    };
}

fn copyInto(ram: []u8, gpa: u64, src: []const u8) void {
    @memcpy(ram[@intCast(gpa)..][0..src.len], src);
}
