//! The guest's floating-point register file: the state it starts in, and the
//! layout vmentry.asm reaches into by constant offset.
//!
//! Both are the kind of fact that is correct when written and silently wrong
//! after an edit somewhere else, and both fail invisibly: a wrong control word
//! makes the guest trap on ordinary arithmetic, and a wrong offset makes each
//! side of a VM transition save its registers over the other's.

const std = @import("std");
const vfpu = @import("testroot").kernel.vfpu;

test "a guest starts with every floating-point exception masked (VIRT-034)" {
    const a = vfpu.FpuArea.atReset();

    // The x87 control word (SDM Vol 1 §8.1.5) and the SSE control and status
    // register (§11.6.4), at the offsets FXSAVE defines for them.
    const fcw = std.mem.readInt(u16, a.bytes[0..2], .little);
    const mxcsr = std.mem.readInt(u32, a.bytes[24..28], .little);

    try std.testing.expectEqual(@as(u16, 0x037F), fcw);
    try std.testing.expectEqual(@as(u32, 0x1F80), mxcsr);

    // The masks are the point: zeroed areas are the easy mistake, and a zero
    // MXCSR unmasks all six SIMD exceptions, so the guest would trap on its
    // first inexact result rather than rounding it.
    const MXCSR_EXCEPTION_MASKS: u32 = 0x1F80;
    try std.testing.expectEqual(MXCSR_EXCEPTION_MASKS, mxcsr & MXCSR_EXCEPTION_MASKS);
}

test "the rest of a reset register file is zero" {
    const a = vfpu.FpuArea.atReset();

    for (a.bytes, 0..) |b, i| {
        const is_control = (i < 2) or (i >= 24 and i < 28);
        if (is_control) continue;
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "the swap areas sit where vmentry.asm addresses them (VIRT-034)" {
    // F_HOST and F_GUEST in vmentry.asm, and the size FXSAVE writes. The
    // assembly cannot check these itself, so they are checked from the side
    // that owns the layout.
    try std.testing.expectEqual(@as(usize, 0x000), @offsetOf(vfpu.FpuSwap, "host"));
    try std.testing.expectEqual(@as(usize, 0x200), @offsetOf(vfpu.FpuSwap, "guest"));
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(vfpu.FpuArea));
    try std.testing.expectEqual(@as(usize, 1024), @sizeOf(vfpu.FpuSwap));
}

test "an area is aligned enough for FXSAVE" {
    // FXSAVE and FXRSTOR raise #GP on an area that is not 16-byte aligned, so
    // this alignment is a correctness requirement, not a performance choice.
    try std.testing.expect(@alignOf(vfpu.FpuArea) >= 16);
    try std.testing.expect(@alignOf(vfpu.FpuSwap) >= 16);
}
