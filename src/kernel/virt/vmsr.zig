//! Guest MSR policy. Pure router for RDMSR/WRMSR exits: `classify` tells the
//! machine model where an MSR access belongs, and the helpers here are the policy
//! for each destination. Host-tested (test/kernel/virt/vmsr_test.zig).
//!
//! Four destinations for an allowlisted MSR, so a guest WRMSR PERSISTS to the next
//! VM entry instead of being lost:
//!   - `guest_field`: the value lives in a VMCS guest-state field (EFER, FS/GS
//!     base, SYSENTER). A write is validated here and write-through by the caller
//!     to the field, so the next VM entry loads it; a read comes back from the
//!     field. `guestFieldWrite`/`guestFieldRead` name the field and sanitize the
//!     value.
//!   - `auto_msr`: the value has no guest-state field, so it rides the VM-entry
//!     MSR-load area (STAR/LSTAR/CSTAR/FMASK, KERNEL_GS_BASE). `AUTO_MSRS` /
//!     `autoIndexOf` place it and `autoWrite` validates it; the caller stores it
//!     into the area (virt/msrarea.zig) that the CPU loads on entry.
//!   - `handled_here`: fixed benign values we model no state for (PAT, MISC_ENABLE,
//!     DEBUGCTL, MCG, …) — `read` returns the value, `write` accepts and discards.
//!   - `apic`/`tsc_deadline`: the caller's x2APIC model owns it — this module must
//!     not import it, so the routing decision is the whole interface.
//! Everything outside the allowlist takes #GP(0), the architectural response to an
//! unimplemented MSR (SDM Vol 3B, RDMSR/WRMSR); Linux probes with rdmsrl_safe and
//! copes.
//!
//! MSR addresses and layouts: SDM Vol 4, Table 2-2 "IA-32 Architectural MSRs".

const vmcs = @import("vmcs.zig");

/// Time-stamp counter. Reads are satisfied by the machine model from the
/// passthrough TSC; the value here is a classifier convenience only. Writes
/// take #GP — the guest must not skew a passthrough counter. Public so the
/// machine model names the same MSR it substitutes rdtsc for.
pub const IA32_TIME_STAMP_COUNTER: u32 = 0x10;

/// Local-APIC base address and mode. Routed to the x2APIC model.
const IA32_APIC_BASE: u32 = 0x1B;

/// Hardware mitigation enumeration. Reads as zero: no mitigations are
/// enumerated, so the guest applies its own — safe, merely conservative.
const IA32_ARCH_CAPABILITIES: u32 = 0x10A;

/// Platform and TSC ratio information (MSR_PLATFORM_INFO). Reads as zero;
/// the guest gets its TSC frequency from CPUID leaf 15H instead.
const IA32_PLATFORM_INFO: u32 = 0xCE;

// SYSENTER call-gate target. Each has a VMCS guest-state field, so a guest write
// is written through and persists at the next entry (see `guestFieldWrite`).
const IA32_SYSENTER_CS: u32 = 0x174;
const IA32_SYSENTER_ESP: u32 = 0x175;
const IA32_SYSENTER_EIP: u32 = 0x176;

// Machine-check global registers. Both read as zero: zero banks, no
// machine-check state — matching vcpuid clearing the MCE/MCA feature bits.
const IA32_MCG_CAP: u32 = 0x179;
const IA32_MCG_STATUS: u32 = 0x17A;

/// Miscellaneous processor features. Only fast-strings enable (bit 0) is
/// reported, the power-on default the guest expects to find set. We model none of
/// its behaviour, so a guest write is accepted and discarded.
const IA32_MISC_ENABLE: u32 = 0x1A0;
const MISC_ENABLE_FAST_STRINGS: u64 = 1 << 0;

/// Debug-control (branch tracing, LBRs). Reads as zero; writes accepted and
/// discarded — no LBR/branch-trace model exists to apply them to.
const IA32_DEBUGCTL: u32 = 0x1D9;

/// Page-attribute table. Reads as the power-on default — entries
/// WB, WT, UC-, UC repeated (SDM Vol 3A, "IA32_PAT MSR"). Writes are accepted and
/// discarded: the guest runs with the host PAT (VM entry does not reload it), and
/// the power-on default is a valid PAT the guest's own setup matches for the WB
/// entries that matter.
const IA32_PAT: u32 = 0x277;
const PAT_POWER_ON_DEFAULT: u64 = 0x0007040600070406;

/// Local-APIC timer deadline. Routed to the caller's x2APIC model.
const IA32_TSC_DEADLINE: u32 = 0x6E0;

// The x2APIC register space: MSRs 800H–83FH map the local-APIC registers
// (SDM Vol 3A, "x2APIC Register Address Space"). Routed to the x2APIC model.
const X2APIC_MSR_FIRST: u32 = 0x800;
const X2APIC_MSR_LAST: u32 = 0x83F;

// Extended-feature enables (long mode, NX, SYSCALL). Held in the VMCS guest-state
// field GUEST_IA32_EFER, which VM entry loads (ENTRY_LOAD_IA32_EFER is set), so a
// guest write is validated and written through to that field and persists. The
// long-mode bits are protected against a hostile write (see `eferWrite`).
const IA32_EFER: u32 = 0xC000_0080;
pub const EFER_SCE: u64 = 1 << 0; // SYSCALL enable
pub const EFER_LME: u64 = 1 << 8; // long-mode enable
pub const EFER_LMA: u64 = 1 << 10; // long-mode active (processor-managed)
pub const EFER_NXE: u64 = 1 << 11; // no-execute enable
const EFER_KNOWN: u64 = EFER_SCE | EFER_LME | EFER_LMA | EFER_NXE;

// SYSCALL setup. No VMCS guest-state field exists for these, so they ride the
// VM-entry MSR-load area (see `AUTO_MSRS`): the CPU loads the guest copy on entry
// and the host copy back on exit. STAR is a selector pair, FMASK a flag mask,
// LSTAR/CSTAR the 64-bit entry addresses.
const IA32_STAR: u32 = 0xC000_0081;
const IA32_LSTAR: u32 = 0xC000_0082;
const IA32_CSTAR: u32 = 0xC000_0083;
const IA32_FMASK: u32 = 0xC000_0084;

// Segment-base MSRs. FS_BASE and GS_BASE have VMCS guest-state fields and are
// written through to them; KERNEL_GS_BASE (the swapgs shadow) has none and rides
// the VM-entry MSR-load area with the SYSCALL MSRs.
const IA32_FS_BASE: u32 = 0xC000_0100;
const IA32_GS_BASE: u32 = 0xC000_0101;
const IA32_KERNEL_GS_BASE: u32 = 0xC000_0102;

const CR0_PG: u64 = 1 << 31; // paging enable (SDM Vol 3A §2.5)

/// The MSRs carried across VM entry/exit through the MSR-load areas, in the fixed
/// order their entries occupy in the areas. The single home of that set and its
/// ordering: virt/vcpu.zig builds the areas from it and `autoIndexOf` maps an MSR
/// to its slot, so an area entry and its index never disagree.
pub const AUTO_MSRS = [_]u32{ IA32_STAR, IA32_LSTAR, IA32_CSTAR, IA32_FMASK, IA32_KERNEL_GS_BASE };

/// Where a guest MSR access is handled.
pub const Class = enum {
    /// Local-APIC MSR — the caller's x2APIC model owns it.
    apic,
    /// IA32_TSC_DEADLINE — the caller's x2APIC timer owns it.
    tsc_deadline,
    /// Backed by a VMCS guest-state field — the caller writes through / reads back
    /// via `guestFieldWrite` / `guestFieldRead`.
    guest_field,
    /// Backed by the VM-entry MSR-load area — the caller stores it via
    /// `autoIndexOf` + `autoWrite` and reads it back from the area.
    auto_msr,
    /// This module's fixed-value `read`/`write` policy applies.
    handled_here,
    /// Unimplemented — inject #GP(0).
    gp,
};

/// Route one MSR address to the destination that handles it.
pub fn classify(msr: u32) Class {
    return switch (msr) {
        IA32_APIC_BASE, X2APIC_MSR_FIRST...X2APIC_MSR_LAST => .apic,
        IA32_TSC_DEADLINE => .tsc_deadline,
        IA32_EFER,
        IA32_FS_BASE,
        IA32_GS_BASE,
        IA32_SYSENTER_CS,
        IA32_SYSENTER_ESP,
        IA32_SYSENTER_EIP,
        => .guest_field,
        IA32_STAR, IA32_LSTAR, IA32_CSTAR, IA32_FMASK, IA32_KERNEL_GS_BASE => .auto_msr,
        else => switch (read(msr)) {
            .value => .handled_here,
            .gp => .gp,
        },
    };
}

/// True when `addr` is canonical: bits 63:47 are a sign-extension of bit 47 (SDM
/// Vol 1 §3.3.7.1). A real WRMSR of a non-canonical address to a base/entry MSR
/// takes #GP, and the VMCS guest-state checks reject a non-canonical base at VM
/// entry — so a hostile value is rejected here rather than written through.
pub fn isCanonical(addr: u64) bool {
    const hi = addr >> 47;
    return hi == 0 or hi == 0x1_FFFF;
}

// --- guest-field MSRs (VMCS guest-state resident) --------------------------

/// The VMCS guest-state field a RDMSR of `msr` reads back, or null when `msr` is
/// not a guest-field MSR.
pub fn guestFieldRead(msr: u32) ?vmcs.Field {
    return switch (msr) {
        IA32_EFER => .guest_ia32_efer,
        IA32_FS_BASE => .guest_fs_base,
        IA32_GS_BASE => .guest_gs_base,
        IA32_SYSENTER_CS => .guest_ia32_sysenter_cs,
        IA32_SYSENTER_ESP => .guest_ia32_sysenter_esp,
        IA32_SYSENTER_EIP => .guest_ia32_sysenter_eip,
        else => null,
    };
}

/// Guest CPU state a guest-field WRMSR is validated against.
pub const WriteCtx = struct {
    /// Current GUEST_IA32_EFER — the EFER validity check compares against it.
    efer: u64,
    /// Current GUEST_CR0 — its PG bit decides whether EFER.LME may change.
    cr0: u64,
};

/// A validated guest-field write: the field to VMWRITE and the sanitized value, or
/// `.gp` when the guest value is illegal.
pub const FieldWrite = union(enum) {
    write: struct { field: vmcs.Field, value: u64 },
    gp,
};

/// Validate a guest WRMSR to a guest-field MSR and name the VMCS field to write.
/// EFER goes through the long-mode-consistency check; the base/entry MSRs must be
/// canonical; SYSENTER_CS keeps only its 32-bit field.
pub fn guestFieldWrite(msr: u32, value: u64, ctx: WriteCtx) FieldWrite {
    return switch (msr) {
        IA32_EFER => switch (eferWrite(ctx.efer, value, (ctx.cr0 & CR0_PG) != 0)) {
            .value => |v| .{ .write = .{ .field = .guest_ia32_efer, .value = v } },
            .gp => .gp,
        },
        IA32_FS_BASE => canonicalField(.guest_fs_base, value),
        IA32_GS_BASE => canonicalField(.guest_gs_base, value),
        IA32_SYSENTER_ESP => canonicalField(.guest_ia32_sysenter_esp, value),
        IA32_SYSENTER_EIP => canonicalField(.guest_ia32_sysenter_eip, value),
        IA32_SYSENTER_CS => .{ .write = .{ .field = .guest_ia32_sysenter_cs, .value = value & 0xFFFF_FFFF } },
        else => .gp,
    };
}

fn canonicalField(field: vmcs.Field, value: u64) FieldWrite {
    if (!isCanonical(value)) return .gp;
    return .{ .write = .{ .field = field, .value = value } };
}

/// Outcome of validating a guest EFER write.
pub const EferWrite = union(enum) { value: u64, gp };

/// Sanitize a guest WRMSR to IA32_EFER. `current` is the guest's live EFER,
/// `paging` its CR0.PG. Rejects reserved bits and an LME toggle while paging is on
/// (SDM Vol 3A §4.1.2), and forces the processor-managed LMA bit to LME & paging so
/// the written value cannot make the VMCS guest state fail the VM-entry EFER checks.
pub fn eferWrite(current: u64, written: u64, paging: bool) EferWrite {
    // Reserved bits (anything this Intel vCPU does not model, including the AMD
    // SVME/FFXSR/TCE bits) must be zero — a real WRMSR takes #GP otherwise.
    if (written & ~EFER_KNOWN != 0) return .gp;
    // LME may change only while paging is off. The guest runs with paging on, so a
    // WRMSR that flips LME is illegal.
    if (paging and ((written ^ current) & EFER_LME != 0)) return .gp;
    // LMA is processor-managed (read-only to software): force it to LME & paging so
    // the VMCS guest EFER stays consistent with the guest's actual mode.
    var v = written & ~EFER_LMA;
    if ((v & EFER_LME != 0) and paging) v |= EFER_LMA;
    return .{ .value = v };
}

// --- auto MSRs (VM-entry MSR-load area resident) ---------------------------

/// The slot `msr` occupies in the MSR-load areas, or null when it is not an auto
/// MSR. Callers index the area entry with this and read/update its data field.
pub fn autoIndexOf(msr: u32) ?usize {
    for (AUTO_MSRS, 0..) |m, i| if (m == msr) return i;
    return null;
}

/// Outcome of validating a guest write to an auto MSR.
pub const AutoWrite = union(enum) { value: u64, gp };

/// Validate a guest WRMSR to an auto MSR before it is stored into the MSR-load
/// area. LSTAR/CSTAR are SYSCALL entry addresses and KERNEL_GS_BASE is a segment
/// base, so all three must be canonical or a real WRMSR takes #GP; STAR is a
/// selector pair and FMASK a flag mask, neither an address.
pub fn autoWrite(msr: u32, value: u64) AutoWrite {
    const needs_canonical = switch (msr) {
        IA32_LSTAR, IA32_CSTAR, IA32_KERNEL_GS_BASE => true,
        else => false,
    };
    if (needs_canonical and !isCanonical(value)) return .gp;
    return .{ .value = value };
}

// --- handled-here MSRs (fixed benign values) -------------------------------

/// Outcome of a guest RDMSR handled here.
pub const RdResult = union(enum) { value: u64, gp };

/// The value a guest RDMSR of a handled-here MSR returns, or `.gp` when the MSR is
/// not one this module models a fixed value for. This switch is the single home of
/// the fixed-value allowlist; `classify` derives the `handled_here` class from it.
pub fn read(msr: u32) RdResult {
    return switch (msr) {
        IA32_TIME_STAMP_COUNTER => .{ .value = 0 }, // machine model substitutes rdtsc
        IA32_MISC_ENABLE => .{ .value = MISC_ENABLE_FAST_STRINGS },
        IA32_PAT => .{ .value = PAT_POWER_ON_DEFAULT },
        IA32_PLATFORM_INFO,
        IA32_ARCH_CAPABILITIES,
        IA32_MCG_CAP,
        IA32_MCG_STATUS,
        IA32_DEBUGCTL,
        => .{ .value = 0 },
        else => .gp,
    };
}

/// Outcome of a guest WRMSR handled here.
pub const WrResult = enum { ok, gp };

/// Accept (and discard) a guest WRMSR to a handled-here MSR: we model no state for
/// these (DEBUGCTL/MISC_ENABLE/PAT/…), so the written value has nothing to apply
/// to and the read-back stays the fixed value. The passthrough TSC refuses writes
/// — the guest must not skew a counter it shares with the host.
pub fn write(msr: u32, value: u64) WrResult {
    _ = value;
    if (msr == IA32_TIME_STAMP_COUNTER) return .gp;
    return switch (read(msr)) {
        .value => .ok,
        .gp => .gp,
    };
}
