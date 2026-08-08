//! The guest's floating-point and vector register file, and where the host's
//! is parked while the guest runs (spec VIRT-034).
//!
//! A VM transition does not carry this register file. The processor saves and
//! restores the general registers and the control state named in the VMCS, and
//! leaves x87 and SSE entirely to software — so a VM exit leaves the guest's
//! values live in the processor, and the kernel that handles the exit then uses
//! those same registers, because the compiler emits SSE for `memcpy` and for
//! every struct copy. By the time the guest runs again they hold whatever the
//! host last put in them.
//!
//! The failure that causes never names itself. Every libc keeps pointers and
//! lengths in these registers, so a corrupted one becomes a wrong address and
//! the process dies dereferencing it, inside whichever library happened to run
//! first — which reads as a null-pointer bug in that library rather than as a
//! hypervisor that lost a register the guest never touched.
//!
//! Pure: layout and reset values only. vmentry.asm does the exchanging, in the
//! instructions either side of VMLAUNCH/VMRESUME.

/// The register file exactly as FXSAVE writes it (Intel SDM Vol 1
/// §10.5.1). FXSAVE and FXRSTOR fault unless the area is 16-byte aligned.
pub const FpuArea = extern struct {
    bytes: [FXSAVE_BYTES]u8 align(16),

    /// The area's size, fixed by the instruction.
    pub const FXSAVE_BYTES = 512;

    /// Where the two control words sit in the area. They are the only fields
    /// whose correct initial value is not zero.
    const OFF_FCW = 0;
    const OFF_MXCSR = 24;

    /// The x87 control word after RESET (SDM Vol 1 §8.1.5): every exception
    /// masked, round to nearest, extended precision.
    const FCW_RESET: u16 = 0x037F;
    /// The SSE control and status register after RESET (SDM Vol 1 §11.6.4):
    /// every exception masked, round to nearest.
    const MXCSR_RESET: u32 = 0x1F80;

    /// The register file a processor has at reset. An area of zeroes would be
    /// wrong in a way that is easy to miss: a zero MXCSR UNMASKS all six SIMD
    /// exceptions, and the guest would then trap on its first inexact result.
    pub fn atReset() FpuArea {
        var a: FpuArea = .{ .bytes = @splat(0) };
        a.bytes[OFF_FCW] = @truncate(FCW_RESET);
        a.bytes[OFF_FCW + 1] = @truncate(FCW_RESET >> 8);
        a.bytes[OFF_MXCSR] = @truncate(MXCSR_RESET);
        a.bytes[OFF_MXCSR + 1] = @truncate(MXCSR_RESET >> 8);
        a.bytes[OFF_MXCSR + 2] = @truncate(MXCSR_RESET >> 16);
        a.bytes[OFF_MXCSR + 3] = @truncate(MXCSR_RESET >> 24);
        return a;
    }
};

/// The two register files the entry trampoline exchanges around a VM
/// transition: one slot for each side of the transition, in the order
/// vmentry.asm addresses them.
pub const FpuSwap = extern struct {
    /// Where the host's file is parked while the guest runs.
    host: FpuArea,
    /// The guest's file, held here between its VM exits.
    guest: FpuArea,
};

comptime {
    // vmentry.asm reaches these areas by the constant offsets F_HOST and
    // F_GUEST, and FXSAVE/FXRSTOR fault on an area that is not 16-byte
    // aligned. A layout change would otherwise save each file over the other's
    // — silent corruption of exactly the kind this struct exists to prevent —
    // so the assembly's assumptions are checked by the compiler, here, rather
    // than described in a comment there.
    if (@offsetOf(FpuSwap, "host") != 0x000)
        @compileError("F_HOST in vmentry.asm no longer matches FpuSwap.host");
    if (@offsetOf(FpuSwap, "guest") != 0x200)
        @compileError("F_GUEST in vmentry.asm no longer matches FpuSwap.guest");
    if (@sizeOf(FpuArea) != FpuArea.FXSAVE_BYTES)
        @compileError("an FXSAVE area is 512 bytes and nothing else");
    if (@alignOf(FpuArea) < 16)
        @compileError("FXSAVE faults on an area that is not 16-byte aligned");
}
