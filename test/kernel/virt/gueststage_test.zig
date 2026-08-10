//! Reachability of the VM boot path: the guest staged into this build
//! (src/kernel/virt/gueststage.zig) is the exact image `vm boot` hands the
//! loader, so parsing its header here through the loader's front door proves the
//! run path can now consume a real staged image — the gap the virt commit left
//! open ("compiles and is tested but is not reachable from a boot caller, no
//! guest image staged"). Whether a guest is staged is a build-time fact
//! (assets/virt present or not); the test asserts the right thing either way, so
//! a fresh checkout with no guest and a full build with one both pass.

const std = @import("std");
const gueststage = @import("testroot").kernel.gueststage;

test "a staged guest is a well-formed 64-bit bzImage the loader accepts" {
    const bz = gueststage.bzImage();
    const initrd = gueststage.initramfs();

    if (bz.len == 0 or initrd.len == 0) {
        // No guest staged in this build: gueststage must agree it is not staged,
        // which is what makes `vm boot` (via virt.bootStaged → error.NotStaged)
        // report "no guest image staged" rather than loading empty bytes.
        try std.testing.expect(!gueststage.staged());
        try std.testing.expect(gueststage.header() == null);
        return;
    }

    // A guest IS staged: its header must parse as a 64-bit Linux boot image, the
    // exact gate virt/linuxload.zig runs before placing it in guest RAM.
    const h = gueststage.header() orelse return error.StagedGuestDoesNotParse;
    try std.testing.expect(h.xlf_kernel_64);
    try std.testing.expect(h.setup_bytes > 0);
    try std.testing.expect(h.setup_bytes < bz.len); // a protected-mode payload follows the setup area
    try std.testing.expect(h.init_size > 0);

    // ...and gueststage must therefore report it reachable, so virt.bootStaged
    // proceeds instead of returning error.NotStaged.
    try std.testing.expect(gueststage.staged());
}

test "every bakeable name is a catalog id, and every catalog id is bakeable (VIRT-019)" {
    // build.zig has to repeat this list — a build script cannot read Zig source
    // — so this is the only thing standing between the two. A name in one and
    // not the other is a guest that cannot be baked, or an embed nothing reads.
    const guestlist = @import("testroot").kernel.guestlist;
    try std.testing.expectEqual(guestlist.CATALOG.len, gueststage.BAKEABLE.len);
    for (guestlist.CATALOG) |img| {
        var found = false;
        for (gueststage.BAKEABLE) |id| found = found or std.mem.eql(u8, id, img.id);
        try std.testing.expect(found);
    }
}

test "a baked guest is offered only when BOTH halves are in this build (VIRT-019)" {
    // Half an image is not an image: a build that embedded a kernel and no root
    // must fetch, not hand the loader an empty initramfs.
    for (gueststage.BAKEABLE) |id| {
        const b = gueststage.bakedFor(id) orelse continue;
        try std.testing.expect(b.bzimage.len > 0);
        try std.testing.expect(b.initramfs.len > 0);
    }
    try std.testing.expect(gueststage.bakedFor("no-such-guest") == null);
}
