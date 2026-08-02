//! Host tests of src/drivers/gl/ada/ctx_init_full.zig.

const std = @import("std");
const ctx_init_full = @import("ctx_init_full");
const emit = ctx_init_full.emit;
const hostpush = ctx_init_full.hostpush;

test "emit fits a page" {
    var buf: [1024]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    emit(&p, 0x0138_0000);
    try std.testing.expect(p.bytes() > 0);
    try std.testing.expect(p.bytes() < 4096);
    // Every header targets subchannel 0 with a valid SEC_OP (INC or IMMD).
    var k: usize = 0;
    while (k < p.bytes() / 4) {
        const w = buf[k];
        const secop = w >> 29;
        try std.testing.expect(secop == 1 or secop == 4);
        try std.testing.expectEqual(@as(u32, 0), (w >> 13) & 0x7);
        k += 1 + if (secop == 1) (w >> 16) & 0x1fff else 0;
    }
}
