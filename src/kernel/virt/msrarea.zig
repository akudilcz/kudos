//! The VM-entry/exit MSR-load/store area entry layout (Intel SDM Vol 3C §24.7.2,
//! "VM-Entry Controls for MSRs", and §24.8.2, "VM-Exit Controls for MSRs"). Pure
//! data: an entry is a 16-byte record the CPU decodes when it auto-loads a guest
//! MSR at VM entry or auto-stores/-loads one at VM exit. This module owns the byte
//! layout and nothing else, so it reads/writes no hardware and host-tests fully
//! (test/kernel/virt/msrarea_test.zig). The IO edge that allocates the physical areas and
//! programs their addresses/counts into the VMCS is virt/vcpu.zig.
//!
//! Not every guest MSR can live in a VMCS guest-state field: the SYSCALL target
//! MSRs (STAR/LSTAR/CSTAR/FMASK) and KERNEL_GS_BASE have no guest-state field, so
//! their values are carried across VM entry/exit through these areas — the CPU
//! loads the guest copy on entry and reloads the host copy on exit.

/// Size in bytes of one MSR-load/store entry (SDM Vol 3C Table 24-15). The CPU
/// steps the area pointer by exactly this many bytes per entry, so the record
/// layout below must match it exactly.
pub const ENTRY_SIZE: usize = 16;

/// One entry of a VM-entry MSR-load, VM-exit MSR-store, or VM-exit MSR-load area
/// (SDM Vol 3C Table 24-15, "Format of an MSR Entry"):
///   bytes 0..4   MSR index (the ECX value a RDMSR/WRMSR of this MSR would use)
///   bytes 4..8   reserved, must be zero
///   bytes 8..16  the 64-bit MSR value
/// `extern` pins the field order and offsets to this ABI so a slice of these is
/// exactly what the CPU walks.
pub const Entry = extern struct {
    index: u32,
    reserved: u32 = 0,
    data: u64,
};

comptime {
    // The CPU's fixed 16-byte stride is the contract; a layout drift here would
    // silently misfeed every entry past the first.
    if (@sizeOf(Entry) != ENTRY_SIZE) @compileError("MSR-area entry must be 16 bytes");
}

/// The raw 16 bytes the CPU reads for an entry loading/storing `index` with
/// `data`. The single home of the encoding, used by the host test to pin the
/// byte offsets and by callers that want the wire image without an Entry value.
pub fn encode(index: u32, data: u64) [ENTRY_SIZE]u8 {
    return @bitCast(Entry{ .index = index, .data = data });
}
