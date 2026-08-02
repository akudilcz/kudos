//! Thin wrappers around the VMX instructions (Intel SDM Vol 3C Ch. 30). The IO
//! edge of the hypervisor: everything here executes a privileged instruction that
//! only works in VMX operation, so nothing in this file is host-testable — the
//! logic it serves (field encodings, control math, EPT layout) lives in the pure
//! sibling modules that ARE tested.
//!
//! Each VMX instruction reports failure in RFLAGS (SDM Vol 3C §30.2): CF set is
//! VMfailInvalid (no current VMCS), ZF set is VMfailValid (a numeric error is
//! readable from the VM-instruction-error field). We capture RFLAGS right after
//! the instruction and translate to a Zig error so callers handle both shapes.

const vmcs = @import("vmcs.zig");
const ept = @import("ept.zig");

pub const VmxError = error{ FailInvalid, FailValid };

const RFLAGS_CF: u64 = 1 << 0;
const RFLAGS_ZF: u64 = 1 << 6;

/// RFLAGS as of the last checked VMX instruction. VMXON is the one instruction
/// whose failure carries no VM-instruction-error to read back (there is no
/// current VMCS to hold one), so its caller reports these flags instead.
pub var last_flags: u64 = 0;

fn check(flags: u64) VmxError!void {
    last_flags = flags;
    if (flags & RFLAGS_CF != 0) return error.FailInvalid;
    if (flags & RFLAGS_ZF != 0) return error.FailValid;
}

/// VMXON, VMCLEAR and VMPTRLD all take an `m64` operand: the CPU reads the
/// 64-bit PHYSICAL ADDRESS out of that memory location. The address is therefore
/// passed as a pointer to a local holding it, and the instruction dereferences
/// that pointer explicitly — `"m"` on the value itself yields a memory operand
/// holding the ADDRESS OF the slot, one level too deep, and the CPU then treats a
/// stack address as the region's physical address. That reads as a plain
/// "VMXON refused" and cost the subsystem its first working guest.
/// Enter VMX operation with `region_pa` as the VMXON region (revision ID already
/// stamped). SDM §30.3 "VMXON".
pub fn vmxon(region_pa: u64) VmxError!void {
    var pa = region_pa; // the m64 the instruction reads its address out of
    const flags = asm volatile (
        \\vmxon (%[pa])
        \\pushfq
        \\popq %[flags]
        : [flags] "=r" (-> u64),
        : [pa] "r" (&pa),
        : .{ .cc = true, .memory = true });
    return check(flags);
}

/// Leave VMX operation. SDM §30.3 "VMXOFF". Cannot fail meaningfully for our use.
pub fn vmxoff() void {
    asm volatile ("vmxoff" ::: .{ .cc = true, .memory = true });
}

/// Clear a VMCS to the "inactive, clear" state and flush it (SDM §30.3 "VMCLEAR").
/// Required before the first VMPTRLD of a freshly allocated VMCS.
pub fn vmclear(vmcs_pa: u64) VmxError!void {
    var pa = vmcs_pa; // the m64 the instruction reads its address out of
    const flags = asm volatile (
        \\vmclear (%[pa])
        \\pushfq
        \\popq %[flags]
        : [flags] "=r" (-> u64),
        : [pa] "r" (&pa),
        : .{ .cc = true, .memory = true });
    return check(flags);
}

/// Make `vmcs_pa` the current VMCS on this core (SDM §30.3 "VMPTRLD"). Subsequent
/// VMREAD/VMWRITE and VMLAUNCH operate on it.
pub fn vmptrld(vmcs_pa: u64) VmxError!void {
    var pa = vmcs_pa; // the m64 the instruction reads its address out of
    const flags = asm volatile (
        \\vmptrld (%[pa])
        \\pushfq
        \\popq %[flags]
        : [flags] "=r" (-> u64),
        : [pa] "r" (&pa),
        : .{ .cc = true, .memory = true });
    return check(flags);
}

/// Write a field of the current VMCS (SDM §30.3 "VMWRITE"). AT&T operand order is
/// value, field.
pub fn vmwrite(field: vmcs.Field, value: u64) VmxError!void {
    const flags = asm volatile (
        \\vmwrite %[value], %[field]
        \\pushfq
        \\popq %[flags]
        : [flags] "=r" (-> u64),
        : [value] "r" (value),
          [field] "r" (@as(u64, @intFromEnum(field))),
        : .{ .cc = true, .memory = true });
    return check(flags);
}

/// Read a field of the current VMCS (SDM §30.3 "VMREAD"). AT&T operand order is
/// field, destination.
pub fn vmread(field: vmcs.Field) VmxError!u64 {
    var value: u64 = undefined;
    var flags: u64 = undefined;
    asm volatile (
        \\vmread %[field], %[value]
        \\pushfq
        \\popq %[flags]
        : [value] "=r" (value),
          [flags] "=r" (flags),
        : [field] "r" (@as(u64, @intFromEnum(field))),
        : .{ .cc = true, .memory = true });
    try check(flags);
    return value;
}

/// The numeric VM-instruction error after a VMfailValid (SDM Vol 3C §30.4). Read
/// it when a VMX instruction returns error.FailValid.
pub fn instructionError() u64 {
    return vmread(.vm_instruction_error) catch 0;
}

/// Invalidate cached EPT translations (SDM §30.3 "INVEPT"). All-context after any
/// EPT structure edit; single-context is an optimization when supported.
pub fn invept(inv_type: u64, desc: *const ept.InveptDescriptor) void {
    asm volatile ("invept %[desc], %[type]"
        :
        : [desc] "m" (desc.*),
          [type] "r" (inv_type),
        : .{ .cc = true, .memory = true });
}
