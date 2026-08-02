//! Per-core VMX bring-up: probe the capability MSRs, satisfy IA32_FEATURE_CONTROL,
//! apply the CR0/CR4 fixed bits, and enter VMX operation (VMXON). IO edge — no
//! host tests; the arithmetic it depends on is host-tested in vmxcaps.zig.
//!
//! Capability MSRs are read once (they are identical across cores) and shared with
//! the rest of the subsystem via `capabilities()`. A core that will host a vCPU
//! calls `enableOnCore` from that core's context; it also installs the per-core
//! TSS/GDT (cpu/gdt.zig) the VMX host-state TR field requires.

const std = @import("std");
const cpu = @import("../cpu/cpu.zig");
const pmm = @import("../memory/pmm.zig");
const percpu = @import("../sched/percpu.zig");
const klog = @import("../debug/klog.zig");
const gdt = @import("../cpu/gdt.zig");
const vmxcaps = @import("vmxcaps.zig");
const vmxasm = @import("vmxasm.zig");

const CR4_VMXE: u64 = 1 << 13; // enable VMX operation (SDM Vol 3C §23.7)

var caps: vmxcaps.CapMsrs = undefined;
var caps_valid: bool = false;
var vmxon_regions: [percpu.MAX_CPUS]u64 = [_]u64{0} ** percpu.MAX_CPUS;

/// How many guests currently need this core to be in VMX operation. VMXON is a
/// property of the CORE, not of a guest, and one core can host more than one
/// guest (the single-core build pumps every VM from core 0), so entering and
/// leaving are reference-counted: the first guest on a core does the VMXON, the
/// last one out does the VMXOFF. Without it the second guest's `enableOnCore`
/// would VMXON a core already in VMX operation (a #UD), and the first guest to
/// stop would VMXOFF from under the others. Written only by the owning core.
var vmxon_refs: [percpu.MAX_CPUS]u32 = [_]u32{0} ** percpu.MAX_CPUS;

pub const BringUpError = error{ NoVmx, FeatureControlLocked, NoVmxonRegion, VmxonFailed };

/// True when the CPU advertises VMX (CPUID.1:ECX[5]).
pub fn supported() bool {
    return cpu.hasVmx();
}

/// The capability MSRs, valid after `probe`. Used by the EPT builder and VMCS setup.
pub fn capabilities() *const vmxcaps.CapMsrs {
    return &caps;
}

/// Decoded EPT capabilities for the EPT builder.
pub fn eptCaps() vmxcaps.EptCaps {
    return vmxcaps.eptCaps(caps.ept_vpid);
}

/// Read the VMX capability MSRs once, choosing the TRUE_* control MSRs when the CPU
/// provides them (IA32_VMX_BASIC bit 55). Safe to call on any core.
pub fn probe() void {
    const basic = cpu.rdmsr(vmxcaps.IA32_VMX_BASIC);
    const t = vmxcaps.usesTrueControls(basic);
    caps = .{
        .basic = basic,
        .pinbased = cpu.rdmsr(if (t) vmxcaps.IA32_VMX_TRUE_PINBASED_CTLS else vmxcaps.IA32_VMX_PINBASED_CTLS),
        .procbased = cpu.rdmsr(if (t) vmxcaps.IA32_VMX_TRUE_PROCBASED_CTLS else vmxcaps.IA32_VMX_PROCBASED_CTLS),
        .procbased2 = cpu.rdmsr(vmxcaps.IA32_VMX_PROCBASED_CTLS2),
        .exit = cpu.rdmsr(if (t) vmxcaps.IA32_VMX_TRUE_EXIT_CTLS else vmxcaps.IA32_VMX_EXIT_CTLS),
        .entry = cpu.rdmsr(if (t) vmxcaps.IA32_VMX_TRUE_ENTRY_CTLS else vmxcaps.IA32_VMX_ENTRY_CTLS),
        .cr0_fixed0 = cpu.rdmsr(vmxcaps.IA32_VMX_CR0_FIXED0),
        .cr0_fixed1 = cpu.rdmsr(vmxcaps.IA32_VMX_CR0_FIXED1),
        .cr4_fixed0 = cpu.rdmsr(vmxcaps.IA32_VMX_CR4_FIXED0),
        .cr4_fixed1 = cpu.rdmsr(vmxcaps.IA32_VMX_CR4_FIXED1),
        .ept_vpid = cpu.rdmsr(vmxcaps.IA32_VMX_EPT_VPID_CAP),
    };
    caps_valid = true;
}

/// Enter VMX operation on the calling core on behalf of one guest: unlock/enable
/// VMX in IA32_FEATURE_CONTROL if the firmware left it unlocked, install this
/// core's TSS/GDT, force the CR0/CR4 fixed bits and CR4.VMXE, allocate a VMXON
/// region with the revision identifier stamped, and execute VMXON.
///
/// Reference-counted (see `vmxon_refs`): a second guest on a core already in VMX
/// operation just takes a reference. Pair every successful call with exactly one
/// `disableOnCore`.
pub fn enableOnCore() BringUpError!void {
    if (!cpu.hasVmx()) return error.NoVmx;
    if (!caps_valid) probe();

    const core = percpu.indexOrBsp();
    if (vmxon_refs[core] > 0) {
        vmxon_refs[core] += 1; // already in VMX operation on this core
        return;
    }

    var fc = cpu.rdmsr(vmxcaps.IA32_FEATURE_CONTROL);
    if (fc & vmxcaps.FEATURE_CONTROL_LOCK == 0) {
        // Firmware left it unlocked: enable VMX outside SMX and lock it ourselves.
        fc |= vmxcaps.FEATURE_CONTROL_LOCK | vmxcaps.FEATURE_CONTROL_VMX_OUTSIDE_SMX;
        cpu.wrmsr(vmxcaps.IA32_FEATURE_CONTROL, fc);
    } else if (fc & vmxcaps.FEATURE_CONTROL_VMX_OUTSIDE_SMX == 0) {
        return error.FeatureControlLocked; // locked with VMX disabled — cannot proceed
    }

    gdt.installForThisCore();

    cpu.writeCr0(vmxcaps.applyCrFixed(cpu.readCr0(), caps.cr0_fixed0, caps.cr0_fixed1));
    const cr4 = cpu.readCr4() | CR4_VMXE;
    cpu.writeCr4(vmxcaps.applyCrFixed(cr4, caps.cr4_fixed0, caps.cr4_fixed1));

    const region = pmm.alloc() orelse return error.NoVmxonRegion;
    // Zeroed for the same reason the VMCS is (see vcpu.initVmcs): the frame
    // allocator hands back whatever the last owner left, and the processor's use
    // of this region beyond the revision identifier is its own business.
    @memset(@as([*]u8, @ptrFromInt(region))[0..pmm.FRAME_SIZE], 0);
    // The VMXON region's first dword is the VMCS revision identifier (SDM §24.11.5).
    @as(*volatile u32, @ptrFromInt(region)).* = vmxcaps.revisionId(caps.basic);

    vmxasm.vmxon(region) catch |e| {
        // VMXON reports failure only in RFLAGS, and the VM-instruction-error
        // field it would otherwise name is unreadable without a current VMCS. So
        // record the inputs the CPU judged instead — the MSRs, control registers
        // and region contents that decide whether VMXON is legal. Recorded once,
        // where both this trace line and the `vm` status line read it from.
        recordVmxonFailure(region);
        klog.puts("virt: VMXON REFUSED (");
        klog.puts(@errorName(e));
        klog.puts(") ");
        klog.puts(vmxonDiag());
        klog.puts("\n");
        pmm.free(region);
        return error.VmxonFailed;
    };
    vmxon_regions[core] = region;
    vmxon_refs[core] = 1;
    klog.puts("virt: vmxon ok on this core\n");
}

/// The machine state VMXON was refused with, for a report that can name a cause.
/// VMfailInvalid on VMXON means exactly one of a misaligned region, a region past
/// the physical-address width, a revision identifier that does not match
/// vmx_basic, an unlocked feature-control MSR, or control registers outside the
/// VMX fixed bits — so every one of those inputs is here to tell them apart.
var vmxon_diag: [256]u8 = undefined;
var vmxon_diag_len: usize = 0;

pub fn vmxonDiag() []const u8 {
    return vmxon_diag[0..vmxon_diag_len];
}

fn recordVmxonFailure(region: usize) void {
    const s = std.fmt.bufPrint(&vmxon_diag, "rev={x} rgnrev={x} rgn={x} rflags={x} basic={x} feature_control={x} cr0={x} cr4={x}", .{
        vmxcaps.revisionId(caps.basic),
        @as(*volatile u32, @ptrFromInt(region)).*,
        region,
        vmxasm.last_flags,
        caps.basic,
        cpu.rdmsr(vmxcaps.IA32_FEATURE_CONTROL),
        cpu.readCr0(),
        cpu.readCr4(),
    }) catch "";
    vmxon_diag_len = s.len;
}

/// Drop one guest's reference to VMX operation on the calling core; the last one
/// out executes VMXOFF and frees the core's VMXON region. Idempotent on a core
/// that is not in VMX operation.
pub fn disableOnCore() void {
    const core = percpu.indexOrBsp();
    if (vmxon_refs[core] == 0) return;
    vmxon_refs[core] -= 1;
    if (vmxon_refs[core] != 0) return; // another guest still runs here
    vmxasm.vmxoff();
    if (vmxon_regions[core] != 0) {
        pmm.free(vmxon_regions[core]);
        vmxon_regions[core] = 0;
    }
}
