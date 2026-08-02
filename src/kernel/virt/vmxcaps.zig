//! VMX capability-MSR arithmetic (Intel SDM Vol 3D Appendix A). Pure functions
//! over raw MSR values — this module never executes RDMSR itself; virt/vmx.zig
//! reads the MSRs once and passes the u64s in. Host-tested (test/kernel/virt/vmxcaps_test.zig)
//! against capability values snapshotted from the nested-KVM dev rig, because the
//! allowed-0/allowed-1 "adjust dance" is the classic place to invert a mask and
//! only discover it as a VM-entry failure under real VMX.

/// VMX capability MSR numbers (SDM Vol 3D Appendix A). Read by virt/vmx.zig.
pub const IA32_VMX_BASIC: u32 = 0x480;
pub const IA32_VMX_PINBASED_CTLS: u32 = 0x481;
pub const IA32_VMX_PROCBASED_CTLS: u32 = 0x482;
pub const IA32_VMX_EXIT_CTLS: u32 = 0x483;
pub const IA32_VMX_ENTRY_CTLS: u32 = 0x484;
pub const IA32_VMX_MISC: u32 = 0x485;
pub const IA32_VMX_CR0_FIXED0: u32 = 0x486;
pub const IA32_VMX_CR0_FIXED1: u32 = 0x487;
pub const IA32_VMX_CR4_FIXED0: u32 = 0x488;
pub const IA32_VMX_CR4_FIXED1: u32 = 0x489;
pub const IA32_VMX_PROCBASED_CTLS2: u32 = 0x48B;
pub const IA32_VMX_EPT_VPID_CAP: u32 = 0x48C;
pub const IA32_VMX_TRUE_PINBASED_CTLS: u32 = 0x48D;
pub const IA32_VMX_TRUE_PROCBASED_CTLS: u32 = 0x48E;
pub const IA32_VMX_TRUE_EXIT_CTLS: u32 = 0x48F;
pub const IA32_VMX_TRUE_ENTRY_CTLS: u32 = 0x490;

/// Non-VMX MSRs the bring-up path also needs.
pub const IA32_FEATURE_CONTROL: u32 = 0x3A;
pub const IA32_EFER: u32 = 0xC0000080;
pub const IA32_FS_BASE: u32 = 0xC0000100;
pub const IA32_GS_BASE: u32 = 0xC0000101;

/// IA32_FEATURE_CONTROL bits (SDM Vol 3C §23.7).
pub const FEATURE_CONTROL_LOCK: u64 = 1 << 0;
pub const FEATURE_CONTROL_VMX_IN_SMX: u64 = 1 << 1;
pub const FEATURE_CONTROL_VMX_OUTSIDE_SMX: u64 = 1 << 2;

/// The raw capability MSR values, read once at bring-up and shared subsystem-wide.
pub const CapMsrs = struct {
    basic: u64,
    pinbased: u64,
    procbased: u64,
    procbased2: u64,
    exit: u64,
    entry: u64,
    cr0_fixed0: u64,
    cr0_fixed1: u64,
    cr4_fixed0: u64,
    cr4_fixed1: u64,
    ept_vpid: u64,
};

/// VMCS revision identifier — IA32_VMX_BASIC bits 30:0. Stamped into the first
/// dword of every VMXON region and VMCS (SDM Vol 3C §24.2).
pub fn revisionId(basic: u64) u31 {
    return @truncate(basic);
}

/// VMCS/VMXON region size in bytes — IA32_VMX_BASIC bits 44:32 (SDM A.1).
pub fn regionSize(basic: u64) u32 {
    return @truncate((basic >> 32) & 0x1FFF);
}

/// True when the IA32_VMX_TRUE_* control MSRs are available (BASIC bit 55).
pub fn usesTrueControls(basic: u64) bool {
    return (basic >> 55) & 1 != 0;
}

/// Memory type the CPU wants for the VMCS region — BASIC bits 53:50 (6 = WB).
pub fn vmcsMemoryType(basic: u64) u4 {
    return @truncate((basic >> 50) & 0xF);
}

/// Reconcile desired VM-execution/exit/entry controls against a capability MSR.
///
/// The MSR's low 32 bits are the allowed-0 settings — a set bit there means the
/// control **must be 1** — and the high 32 bits are the allowed-1 settings — a
/// clear bit there means the control **must be 0** (SDM Vol 3D §A.3.1). The result
/// forces every required-1 bit on and every not-allowed bit off. Returns
/// `error.Unsupported` when a bit the caller needs on cannot be set, or a bit the
/// caller needs off is forced on — either way the intended configuration is
/// impossible on this CPU and the caller must not launch.
pub fn adjustControls(cap_msr: u64, want_set: u32, want_clear: u32) error{Unsupported}!u32 {
    const must_be_1: u32 = @truncate(cap_msr); // low: allowed-0 (1 ⇒ must be 1)
    const may_be_1: u32 = @truncate(cap_msr >> 32); // high: allowed-1 (0 ⇒ must be 0)
    var ctl = want_set;
    ctl &= may_be_1; // cannot set a bit the CPU forbids being 1
    ctl |= must_be_1; // must set a bit the CPU requires being 1
    if (want_set & ~ctl != 0) return error.Unsupported; // a wanted-on bit is unsettable
    if (want_clear & ctl != 0) return error.Unsupported; // a wanted-off bit is forced on
    return ctl;
}

/// Force CR0 (or CR4) to a VMX-legal value: OR in the must-be-1 bits from FIXED0,
/// AND away the must-be-0 bits absent from FIXED1 (SDM Vol 3C §23.8). This is the
/// rule for the HOST's own control registers, and for a guest running without
/// unrestricted-guest mode.
pub fn applyCrFixed(cr: u64, fixed0: u64, fixed1: u64) u64 {
    return (cr | fixed0) & fixed1;
}

/// CR0.PE and CR0.PG, the two bits IA32_VMX_CR0_FIXED0 requires of a guest only
/// while unrestricted-guest mode is off (SDM Vol 3C §23.8).
const CR0_PE: u64 = 1 << 0;
const CR0_PG: u64 = 1 << 31;

/// Force a GUEST CR0 to a VMX-legal value with the unrestricted-guest control
/// enabled: the same rule as `applyCrFixed`, except that PE and PG are exempt
/// from the must-be-1 set, which is precisely what unrestricted-guest buys. A
/// guest may then sit in protected mode with paging off — where every Linux
/// before ~6.1 spends its decompressor trampoline — instead of taking a #GP on
/// the write that gets it there.
pub fn applyGuestCr0Fixed(cr0: u64, fixed0: u64, fixed1: u64) u64 {
    return applyCrFixed(cr0, fixed0 & ~(CR0_PE | CR0_PG), fixed1);
}

/// The CR0 bits the hypervisor must OWN rather than let the guest write: the
/// must-be-1 bits that unrestricted-guest mode does NOT exempt. On every current
/// Intel part that is CR0.NE alone, but it is read from the CPU rather than
/// spelled out, because the one home for "which CR0 bits are pinned" is the MSR
/// that pins them.
///
/// These become the CR0 guest/host mask, so a guest write that disagrees with the
/// read shadow on one of them exits to be emulated instead of raising a #GP the
/// guest is in no position to handle. Linux's decompressor writes CR0 = PG|PE
/// flat, with NE clear, in exactly such a place.
pub fn guestCr0PinnedBits(fixed0: u64) u64 {
    return fixed0 & ~(CR0_PE | CR0_PG);
}

/// Decoded EPT/VPID capabilities — IA32_VMX_EPT_VPID_CAP (SDM Vol 3D A.10). Drives
/// which EPT page sizes virt/ept.zig may use and which INVEPT forms are legal.
pub const EptCaps = struct {
    execute_only: bool,
    walk_length_4: bool,
    memtype_wb: bool,
    page_2m: bool,
    page_1g: bool,
    invept_supported: bool,
    ad_bits: bool,
    invept_single: bool,
    invept_all: bool,
};

/// Decode IA32_VMX_EPT_VPID_CAP into the capability flags the EPT builder needs.
pub fn eptCaps(cap: u64) EptCaps {
    return .{
        .execute_only = bit(cap, 0),
        .walk_length_4 = bit(cap, 6),
        .memtype_wb = bit(cap, 14),
        .page_2m = bit(cap, 16),
        .page_1g = bit(cap, 17),
        .invept_supported = bit(cap, 20),
        .ad_bits = bit(cap, 21),
        .invept_single = bit(cap, 25),
        .invept_all = bit(cap, 26),
    };
}

fn bit(v: u64, n: u6) bool {
    return (v >> n) & 1 != 0;
}
