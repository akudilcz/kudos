//! Host tests of src/kernel/virt/layout.zig — placement planning.

const std = @import("std");
const bzimage = layout.bzimage;
const layout = @import("testroot").kernel.layout;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn info() bzimage.BzInfo {
    return .{
        .setup_bytes = 2560,
        .version = 0x020F,
        .xlf_kernel_64 = true,
        .pref_address = 0x100_0000, // 16 MiB
        .init_size = 0x80_0000, // 8 MiB
        .initrd_addr_max = 0x7FFF_FFFF,
        .cmdline_size = 0x7FF,
    };
}

const RAM: u64 = 128 * 1024 * 1024;

test "plan places kernel, initramfs, and cmdline without overlap" {
    const lay = try layout.plan(RAM, info(), 4 * 1024 * 1024, 4 * 1024 * 1024, 40);
    try expectEqual(@as(u64, 0x100_0000), lay.kernel_gpa);
    try expectEqual(@as(u64, 0x100_0200), lay.entry_rip);
    try expectEqual(@as(u64, 0x180_0000), lay.kernel_end); // 16 MiB + 8 MiB
    try expectEqual(layout.CMDLINE_GPA, lay.cmdline_gpa);
    try expectEqual(layout.ZERO_PAGE_GPA, lay.boot_params_gpa);
    // initramfs placed high, page-aligned, clear of the kernel image.
    try std.testing.expect(lay.initrd_gpa >= lay.kernel_end);
    try std.testing.expect(lay.initrd_gpa % layout.PAGE_SIZE == 0);
    try std.testing.expect(lay.initrd_gpa + lay.initrd_len <= RAM);
}

test "initramfs sits below the header's initrd_addr_max" {
    var bz = info();
    bz.initrd_addr_max = 0x3FF_FFFF; // cap at 64 MiB − 1
    const lay = try layout.plan(RAM, bz, 1024 * 1024, 1024 * 1024, 10);
    try std.testing.expect(lay.initrd_gpa + lay.initrd_len <= 0x400_0000);
}

test "RAM that is not a whole number of 2 MiB pages is rejected" {
    try expectError(error.RamTooSmall, layout.plan(RAM + 4096, info(), 0, 0, 0));
}

test "RAM below the floor is rejected" {
    try expectError(error.RamTooSmall, layout.plan(16 * 1024 * 1024, info(), 0, 0, 0));
}

test "an over-long command line is rejected" {
    try expectError(error.CmdlineTooLong, layout.plan(RAM, info(), 0, 0, 0x800));
}

test "an initramfs too large to clear the kernel is rejected" {
    try expectError(error.NoFit, layout.plan(RAM, info(), 0, @intCast(RAM - 0x100_0000), 0));
}

test "a protected-mode payload larger than init_size is bounded against RAM" {
    // init_size claims 8 MiB but the on-disk payload is nearly all of RAM; validating
    // only init_size would let the copy run past guest RAM.
    try expectError(error.NoFit, layout.plan(RAM, info(), @intCast(RAM), 0, 0));
}

test "a kernel image that does not fit under the RAM ceiling is rejected" {
    var bz = info();
    bz.init_size = @intCast(RAM); // 128 MiB image at 16 MiB cannot fit in 128 MiB RAM
    try expectError(error.NoFit, layout.plan(RAM, bz, 0, 0, 0));
}

test "a pref_address inside the low scaffolding is rejected" {
    var bz = info();
    bz.pref_address = 0x1000; // below the command line / page tables
    try expectError(error.NoFit, layout.plan(RAM, bz, 0, 0, 0));
}

test "a pref_address that overflows the kernel span is rejected, not wrapped" {
    var bz = info();
    bz.pref_address = 0xFFFF_FFFF_FFFF_0000; // pref + init_size wraps u64
    try expectError(error.NoFit, layout.plan(RAM, bz, 0, 0, 0));
}

test "RAM reaching the virtio-mmio window is rejected" {
    // 4 GiB of RAM would bury the window (and the LAPIC hole above it) under
    // EPT-mapped memory, so no device access could ever exit.
    try expectError(error.NoFit, layout.plan(4 * layout.GIB, info(), 0, 0, 0));
}

test "RAM just below the virtio-mmio window is accepted" {
    const ram = layout.VIRTIO_MMIO_GPA & ~(layout.PAGE_2M - 1);
    const lay = try layout.plan(ram, info(), 1024 * 1024, 1024 * 1024, 10);
    try expectEqual(ram, lay.ram_bytes);
}

test "virtio slots step one stride apart with distinct, free interrupt lines" {
    try expectEqual(layout.VIRTIO_MMIO_GPA, layout.VirtioSlot.gpu.gpa());
    const slots = std.enums.values(layout.VirtioSlot);
    for (slots, 0..) |a, i| {
        try expectEqual(layout.VIRTIO_MMIO_GPA + i * layout.VIRTIO_MMIO_STRIDE, a.gpa());
        try std.testing.expect(a.gpa() + layout.VIRTIO_MMIO_STRIDE <= layout.VIRTIO_MMIO_END);
        // Never the serial line (4) or the 8259 cascade (2), never shared.
        try std.testing.expect(a.irq() != 4 and a.irq() != 2);
        for (slots[i + 1 ..]) |b| try std.testing.expect(a.irq() != b.irq());
    }
}

test "the low-memory scaffolding is laid out in order, with a page each" {
    // Everything the loader places below 1 MiB, in address order and clear of
    // each other. These are separate constants that only agree by intent, and
    // an overlap here is a guest whose page tables or command line get written
    // over by the next thing placed.
    try expectEqual(@as(u64, 0), layout.GDT_GPA % layout.PAGE_SIZE);
    try std.testing.expect(layout.GDT_GPA + layout.PAGE_SIZE <= layout.ZERO_PAGE_GPA);
    try std.testing.expect(layout.ZERO_PAGE_GPA + layout.PAGE_SIZE <= layout.PT_PML4_GPA);
    try std.testing.expect(layout.PT_PML4_GPA + layout.PAGE_SIZE <= layout.PT_PDPT_GPA);
    try std.testing.expect(layout.PT_PDPT_GPA + layout.PAGE_SIZE <= layout.PT_PD_BASE_GPA);
    try std.testing.expect(layout.PT_PD_BASE_GPA < layout.CMDLINE_GPA);
    // The command line comes last of the writable scaffolding, below the ACPI
    // tables, which sit in the reserved BIOS window above usable low RAM.
    try std.testing.expect(layout.CMDLINE_GPA < layout.ACPI_GPA);
    try std.testing.expect(layout.ACPI_GPA < 0x10_0000);
}
