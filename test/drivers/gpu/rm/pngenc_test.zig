//! Host tests of src/drivers/gpu/base/pngenc.zig — the PNG encoder round-trips
//! through the tree's own decoder (png.zig): what kudos writes, kudos reads.

const std = @import("std");
const pngenc = @import("pngenc");
const png = @import("png");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// DIAG-016: screenshots are NATIVE PNG — the round-trip through the tree's
// own decoder proves the encoder emits the standard format, losslessly.
test "encode → decode round-trip preserves every pixel" {
    const a = std.testing.allocator;
    // 3x2, distinct saturated colours (alpha in the source is dropped: RGB PNG).
    const src = [_]u32{
        0xFFFF0000, 0xFF00FF00, 0xFF0000FF,
        0xFF102030, 0xFFFFFFFF, 0xFF000000,
    };
    const bytes = try pngenc.encode(a, 3, 2, &src, 3);
    defer a.free(bytes);

    const img = try png.decode(a, bytes);
    defer img.deinit(a);
    try expectEqual(@as(u32, 3), @as(u32, @intCast(img.w)));
    try expectEqual(@as(u32, 2), @as(u32, @intCast(img.h)));
    // png.zig yields BGRA bytes rows top-down.
    for (src, 0..) |v, i| {
        const b = img.bgra[i * 4 ..][0..4];
        try expectEqual(@as(u8, @truncate(v)), b[0]); // B
        try expectEqual(@as(u8, @truncate(v >> 8)), b[1]); // G
        try expectEqual(@as(u8, @truncate(v >> 16)), b[2]); // R
        try expectEqual(@as(u8, 0xFF), b[3]); // opaque
    }
}

test "stride: only the leading w pixels of each row are encoded" {
    const a = std.testing.allocator;
    // 2x2 image inside a stride-3 buffer; the third column is poison.
    const src = [_]u32{
        0xFF111111, 0xFF222222, 0xFFDEADBE,
        0xFF333333, 0xFF444444, 0xFFDEADBE,
    };
    const bytes = try pngenc.encode(a, 2, 2, &src, 3);
    defer a.free(bytes);
    const img = try png.decode(a, bytes);
    defer img.deinit(a);
    try expectEqual(@as(u8, 0x44), img.bgra[(2 * 1 + 1) * 4]); // last pixel B
}

// Mirrors sched.STACK_SIZE (the owner, which freestanding-only sched.zig keeps
// host-unimportable): if kernel task stacks shrink, this budget must shrink too.
const KERNEL_TASK_STACK_BYTES: usize = 128 * 1024;

// IMG-002: images are ENCODED natively too — the screenshot path's PNG writer.
test "encode fits a kernel task stack (compressor state is heap-hosted)" {
    // The stack-fit claim is a RELEASE property: the kernel ships ReleaseFast
    // and stackframes.sh budgets those frames. Debug frames are fatter by
    // design (safety checks, no inlining), so under a Debug build — the
    // coverage instrument — this test's premise does not hold.
    if (@import("builtin").mode == .Debug) return error.SkipZigTest;
    // The module doc promises the deflate state lives on the caller's
    // allocator, never the stack — a stack-local `flate.Compress` (~225 KiB)
    // overflows a kernel task stack and resets real hardware. Host stacks are
    // MB-scale and hide that, so run encode on a thread given exactly a kernel
    // task's stack: a stack-local compressor faults here instead of on lemon.
    const Run = struct {
        fn run(ok: *bool) void {
            const a = std.testing.allocator;
            const w = 64;
            const h = 48;
            const px = a.alloc(u32, w * h) catch return;
            defer a.free(px);
            for (px, 0..) |*v, i| v.* = 0xFF000000 | @as(u32, @intCast(i & 0xFF));
            const bytes = pngenc.encode(a, w, h, px, w) catch return;
            a.free(bytes);
            ok.* = true;
        }
    };
    var ok = false;
    const t = try std.Thread.spawn(.{ .stack_size = KERNEL_TASK_STACK_BYTES }, Run.run, .{&ok});
    t.join();
    try expect(ok);
}

test "a screenshot-sized image encodes well under raw size" {
    const a = std.testing.allocator;
    const w = 640;
    const h = 480;
    const px = try a.alloc(u32, w * h);
    defer a.free(px);
    // A gradient-ish desktop stand-in (compressible, like real UI content).
    for (px, 0..) |*v, i| v.* = 0xFF000000 | @as(u32, @intCast((i / w) & 0xFF)) << 8 | @as(u32, @intCast(i % 17));
    const bytes = try pngenc.encode(a, w, h, px, w);
    defer a.free(bytes);
    try expect(bytes.len < w * h * 3 / 4); // ≥4x smaller than raw RGB
}
