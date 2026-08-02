//! Guest CPUID policy. Pure filter over the host's CPUID result: the machine
//! model executes CPUID on the real CPU for the leaf the guest requested, then
//! calls `filter` to sanitize the registers before completing the VM exit.
//! Host-tested (test/kernel/virt/vcpuid_test.zig).
//!
//! The guest is a single-vCPU Linux booted directly in 64-bit mode: the local
//! APIC is an x2APIC emulated through MSR exits, the TSC is passed through at
//! a calibrated frequency, and there is no ACPI, no MTRR, no machine-check and
//! no nested VMX. Leaf 1 advertises exactly that feature set; leaves 15H/16H
//! are synthesized so the guest derives its TSC frequency arithmetically
//! instead of calibrating against a timer; leaf 4000_0000H names the
//! hypervisor, which both sets X86_FEATURE_HYPERVISOR and — see
//! HYPERVISOR_VENDOR — keeps the guest on the MSR-based APIC this hypervisor
//! actually serves.

/// The four registers CPUID returns (Intel SDM Vol 2A, CPUID).
pub const Regs = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

// Leaves this policy rewrites (SDM Vol 2A, CPUID, Table "Information Returned
// by CPUID Instruction").
const LEAF_FEATURES: u32 = 0x01; // basic feature flags in ECX/EDX
const LEAF_EXTENDED_FEATURES: u32 = 0x07; // structured extended feature flags
const LEAF_TSC_RATIO: u32 = 0x15; // TSC / core-crystal-clock ratio
const LEAF_CPU_FREQUENCY: u32 = 0x16; // processor frequency information
const LEAF_HYPERVISOR_BASE: u32 = 0x4000_0000; // hypervisor vendor + max leaf
const LEAF_HYPERVISOR_FEATURES: u32 = 0x4000_0001; // paravirtual feature bits
const LEAF_HYPERVISOR_LAST: u32 = 0x4000_FFFF; // end of the hypervisor range
const LEAF_EXTENDED_FEATURES_80000001: u32 = 0x8000_0001; // extended feature flags

// Leaf 01H ECX feature bits (SDM Vol 2A, CPUID, Figure "Feature Information
// Returned in the ECX Register").
const ECX_VMX: u32 = 1 << 5; // Virtual Machine Extensions
const ECX_X2APIC: u32 = 1 << 21; // x2APIC (MSR-based local APIC access)
const ECX_TSC_DEADLINE: u32 = 1 << 24; // TSC-deadline local-APIC timer mode
const ECX_XSAVE: u32 = 1 << 26; // XSAVE feature set (drives XSETBV/XSAVES)
const ECX_OSXSAVE: u32 = 1 << 27; // OS has enabled XSAVE (CR4.OSXSAVE)
const ECX_HYPERVISOR: u32 = 1 << 31; // running under a hypervisor

// Leaf 01H EBX: the initial local-APIC ID lives in bits 31:24.
const EBX_INITIAL_APIC_ID_MASK: u32 = 0xFF00_0000;

// Leaf 01H EDX feature bits (SDM Vol 2A, CPUID, Figure "Feature Information
// Returned in the EDX Register").
const EDX_MCE: u32 = 1 << 7; // Machine Check Exception
const EDX_APIC: u32 = 1 << 9; // on-chip local APIC
const EDX_MTRR: u32 = 1 << 12; // Memory Type Range Registers
const EDX_MCA: u32 = 1 << 14; // Machine Check Architecture
const EDX_ACPI: u32 = 1 << 22; // thermal monitor and clock-control MSRs

// Leaf 07H subleaf 0 EBX: INVPCID needs a VMX secondary control this vCPU does
// not enable, so it must not be advertised or the guest #UDs on it.
const EBX7_INVPCID: u32 = 1 << 10;

// Leaf 07H subleaf 0 ECX: two more features gated by VMX secondary controls this
// vCPU does not enable. TPAUSE/UMONITOR/UMWAIT (WAITPKG) and RDPID both raise
// #UD in VMX non-root operation unless their control is set, and a guest that
// sees them advertised WILL use them — Linux picks TPAUSE for its delay loop the
// moment the bit is there, and dies on the first delay after console setup.
const ECX7_WAITPKG: u32 = 1 << 5;
const ECX7_RDPID: u32 = 1 << 22;

// Leaf 8000_0001H EDX: RDTSCP likewise needs an unset VMX secondary control.
const EDX81_RDTSCP: u32 = 1 << 27;

/// The 12-byte hypervisor vendor string returned in leaf 4000_0000H
/// EBX:ECX:EDX, four bytes per register, little-endian — the same packing
/// CPUID leaf 0 uses for "GenuineIntel".
///
/// It spells the signature Linux's KVM paravirtualization probe looks for,
/// because to a Linux guest this string is not decoration — it is how the
/// guest decides whether it may keep using its x2APIC. Absent an IOMMU
/// advertising interrupt remapping, Linux keeps x2APIC only when
/// `x86_init.hyper.x2apic_available()` answers yes, and that hook is
/// installed by exactly one probe: the KVM one. A guest that gets no for an
/// answer logs "IRQ remapping doesn't support X2APIC mode", tears x2APIC
/// down, and switches the local APIC to the memory-mapped window at
/// acpi.LAPIC_MMIO_BASE — an address this hypervisor does not serve.
///
/// Claiming the signature commits us to nothing: every paravirtual feature
/// a Linux guest would then reach for is gated on a bit in
/// LEAF_HYPERVISOR_FEATURES, and this policy advertises none of them.
pub const HYPERVISOR_VENDOR = "KVMKVMKVM\x00\x00\x00";

/// The synthesized bus (reference) clock reported in leaf 16H ECX, in MHz.
/// 100 MHz is the ubiquitous value on real parts; nothing in the guest keys
/// off it beyond informational display.
const BUS_CLOCK_MHZ: u32 = 100;

const HZ_PER_MHZ: u64 = 1_000_000;

fn vendorWord(comptime offset: usize) u32 {
    const b = HYPERVISOR_VENDOR[offset .. offset + 4];
    return @as(u32, b[0]) | @as(u32, b[1]) << 8 | @as(u32, b[2]) << 16 | @as(u32, b[3]) << 24;
}

/// A frequency in Hz clamped into the 32-bit CPUID field (leaf 15H ECX).
fn hzToU32(hz: u64) u32 {
    return @intCast(@min(hz, 0xFFFF_FFFF));
}

/// Sanitize the host's CPUID result for `leaf` before it reaches the guest.
/// `tsc_hz` is the calibrated TSC frequency the passthrough TSC actually
/// ticks at. Leaves this policy does not rewrite pass through unchanged.
pub fn filter(host: Regs, leaf: u32, subleaf: u32, tsc_hz: u64) Regs {
    return switch (leaf) {
        LEAF_FEATURES => .{
            .eax = host.eax,
            // The sole vCPU is local-APIC ID 0 (matching the x2APIC model), so
            // clear the host core's initial APIC ID from bits 31:24.
            .ebx = host.ebx & ~EBX_INITIAL_APIC_ID_MASK,
            // Advertise the virtual platform: hypervisor present, x2APIC and
            // TSC-deadline (both emulated via MSR exits). Hide VMX (no nested
            // virtualization) and the XSAVE feature set — XSETBV/XSAVES are not
            // virtualized and would exit-to-shutdown or #UD in the guest.
            .ecx = (host.ecx | ECX_HYPERVISOR | ECX_X2APIC | ECX_TSC_DEADLINE) & ~(ECX_VMX | ECX_XSAVE | ECX_OSXSAVE),
            // Hide what has no MSR backing: machine-check (MCE/MCA), the
            // ACPI thermal MSRs and the MTRRs. The local APIC stays
            // advertised — it is the emulated x2APIC.
            .edx = (host.edx | EDX_APIC) & ~(EDX_MCE | EDX_MCA | EDX_ACPI | EDX_MTRR),
        },
        // Leaf 07H subleaf 0 carries the structured extended-feature EBX flags;
        // higher subleaves report other data and pass through. Mask INVPCID.
        LEAF_EXTENDED_FEATURES => if (subleaf == 0) .{
            .eax = host.eax,
            .ebx = host.ebx & ~EBX7_INVPCID,
            .ecx = host.ecx & ~(ECX7_WAITPKG | ECX7_RDPID),
            .edx = host.edx,
        } else host,
        // Extended features: mask RDTSCP; the rest (NX, long mode, 1 GiB pages)
        // pass through unchanged.
        LEAF_EXTENDED_FEATURES_80000001 => .{
            .eax = host.eax,
            .ebx = host.ebx,
            .ecx = host.ecx,
            .edx = host.edx & ~EDX81_RDTSCP,
        },
        // Leaf 15H: EAX = ratio denominator, EBX = numerator, ECX = crystal
        // frequency in Hz; TSC = crystal * EBX / EAX (SDM Vol 2A). A 1/1
        // ratio makes the crystal frequency the TSC frequency directly, so
        // Linux skips TSC calibration. Saturate rather than wrap a ≥ 4.29 GHz
        // counter into the 32-bit field.
        LEAF_TSC_RATIO => .{ .eax = 1, .ebx = 1, .ecx = hzToU32(tsc_hz), .edx = 0 },
        // Leaf 16H: base/max frequency in MHz, bus frequency in MHz
        // (SDM Vol 2A). Informational; derived from the same tsc_hz.
        LEAF_CPU_FREQUENCY => .{
            .eax = @truncate(tsc_hz / HZ_PER_MHZ),
            .ebx = @truncate(tsc_hz / HZ_PER_MHZ),
            .ecx = BUS_CLOCK_MHZ,
            .edx = 0,
        },
        // Hypervisor identification: EAX = the highest hypervisor leaf that
        // means anything, then the vendor string. The feature leaf exists (a
        // guest reads it to learn which paravirtual services are offered), so
        // it is the highest, even though every bit in it is clear.
        LEAF_HYPERVISOR_BASE => .{
            .eax = LEAF_HYPERVISOR_FEATURES,
            .ebx = vendorWord(0),
            .ecx = vendorWord(4),
            .edx = vendorWord(8),
        },
        // The feature leaf and the rest of the hypervisor range: all zeros —
        // no paravirtual feature is advertised, and nothing leaks from
        // whatever the host CPU returned for these reserved leaves.
        LEAF_HYPERVISOR_BASE + 1...LEAF_HYPERVISOR_LAST => .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 },
        else => host,
    };
}
