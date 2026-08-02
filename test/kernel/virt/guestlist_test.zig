//! Host tests of src/kernel/virt/guestlist.zig — the `vm boot` image catalog.

const std = @import("std");
const guestlist = @import("testroot").kernel.guestlist;
const expect = std.testing.expect;

test "list numbering: 1 is the built-in, 2..COUNT are catalog entries, else null (VIRT-020)" {
    try expect(guestlist.COUNT == 1 + guestlist.CATALOG.len);
    try expect(guestlist.byNumber(0) == null);
    try expect(guestlist.byNumber(1) == null); // the staged built-in, not ours
    try expect(guestlist.byNumber(2).? == &guestlist.CATALOG[0]);
    try expect(guestlist.byNumber(guestlist.COUNT).? == &guestlist.CATALOG[guestlist.CATALOG.len - 1]);
    try expect(guestlist.byNumber(guestlist.COUNT + 1) == null);
}

test "every catalog entry is fetchable-shaped: plain http, both halves, sane RAM (VIRT-019)" {
    for (guestlist.CATALOG) |img| {
        // The background fetch path speaks plain HTTP only.
        try expect(std.mem.startsWith(u8, img.kernel_url, "http://"));
        try expect(std.mem.startsWith(u8, img.initramfs_url, "http://"));
        try expect(img.kernel_url.len > "http://x/".len);
        try expect(img.initramfs_url.len > "http://x/".len);
        try expect(img.name.len > 0);
        // An initramfs unpacks into RAM: the guest needs several times the
        // download; anything under the download size cannot boot.
        try expect(img.ram_mb >= img.approx_mb);
        // The serial console must be the LAST `console=` argument so it stays
        // /dev/console — that is the console the VM window mirrors (VIRT-010).
        const last_console = std.mem.lastIndexOf(u8, img.cmdline, "console=").?;
        try expect(std.mem.startsWith(u8, img.cmdline[last_console..], "console=ttyS0"));
    }
}
