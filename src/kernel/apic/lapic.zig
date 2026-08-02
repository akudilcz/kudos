//! Local APIC (xAPIC MMIO + x2APIC MSR): enable, EOI, IPIs (ICR), and the LAPIC
//! timer used for per-core preemption.
//!
//! Each core has its own LAPIC at the same architectural address; a core touches
//! only its own. The BSP uses the ICR here to send INIT-SIPI-SIPI to the APs.
//! Register offsets, the ICR bitfields, the x2APIC MSR mapping, and the timer
//! divide encoding are all cited in Intel SDM Vol 3A §10, cross-checked vs
//! Linux arch/x86/kernel/apic/.

const klog = @import("../debug/klog.zig");
const cpu = @import("../cpu/cpu.zig");
const mmio = @import("../../drivers/io/mmio.zig");
const acpi = @import("../acpi/acpi.zig");

// IA32_APIC_BASE MSR.
const IA32_APIC_BASE: u32 = 0x1B;
const APIC_BASE_X2APIC: u64 = 1 << 10; // EXTD
const APIC_BASE_ENABLE: u64 = 1 << 11; // EN (global)
const APIC_BASE_ADDR_MASK: u64 = 0xFFFFF000;

// xAPIC MMIO register offsets.
const REG_ID: u32 = 0x20;
const REG_VERSION: u32 = 0x30;
const REG_TPR: u32 = 0x80;
const REG_EOI: u32 = 0xB0;
const REG_SVR: u32 = 0xF0;
const REG_ICR_LO: u32 = 0x300;
const REG_ICR_HI: u32 = 0x310;
const REG_LVT_TIMER: u32 = 0x320;
const REG_LVT_LINT0: u32 = 0x350;
const REG_LVT_LINT1: u32 = 0x360;
const REG_LVT_ERROR: u32 = 0x370;

// SVR bits.
const SVR_ENABLE: u32 = 1 << 8; // APIC software enable
/// Vector the LAPIC delivers a spurious interrupt on (SVR bits[7:0], programmed in
/// enable()). The single owner of this value: isrDispatch imports it to recognize
/// (and deliberately NOT EOI) the spurious vector.
pub const SPURIOUS_VECTOR: u32 = 0xFF;

// LVT bits.
const LVT_MASKED: u32 = 1 << 16;
// LVT delivery modes for LINT0/LINT1 in a PIC-based system: the 8259 reaches the
// CPU through LINT0 as ExtINT, and the NMI line through LINT1. Masking LINT0
// would cut off ALL legacy-PIC interrupt delivery (incl. the timer), so the BSP
// keeps LINT0=ExtINT until the IO-APIC takes over IRQ routing.
const LVT_DELIVERY_EXTINT: u32 = 0b111 << 8;
const LVT_DELIVERY_NMI: u32 = 0b100 << 8;

// ICR bitfields.
pub const DELIVERY_FIXED: u32 = 0b000 << 8;
pub const DELIVERY_INIT: u32 = 0b101 << 8;
pub const DELIVERY_STARTUP: u32 = 0b110 << 8;
const ICR_LEVEL_ASSERT: u32 = 1 << 14;
const ICR_TRIGGER_LEVEL: u32 = 1 << 15;
const ICR_DELIVERY_STATUS: u32 = 1 << 12; // read: 0 = idle

// x2APIC MSR mapping: MSR = 0x800 + (xAPIC_offset >> 4).
const X2APIC_BASE_MSR: u32 = 0x800;
const X2APIC_ICR_MSR: u32 = 0x830;

// These two globals describe the LAPIC access method (MMIO base + xAPIC/x2APIC
// mode) and are architecturally identical on every core: the MADT lapic_address is
// one value system-wide and x2apicSupported() reads the same CPUID bit on all
// cores. enable() re-writes both from every AP, but always with the SAME values the
// BSP wrote, so they are effectively read-only after the BSP's enable() — every AP
// stores an identical value, never a conflicting one. Treat them as read-only after
// BSP bring-up; nothing in this module writes them divergently, so they need no lock.
var mmio_base: u64 = acpi.LAPIC_DEFAULT_BASE; // set from the MADT lapic_address in init()
var x2apic: bool = false; // true once enabled in x2APIC mode

// --- primitives ------------------------------------------------------------

/// Read an APIC register, abstracting xAPIC MMIO vs x2APIC MSR.
fn regRead(reg: u32) u32 {
    if (x2apic) return @truncate(cpu.rdmsr(X2APIC_BASE_MSR + (reg >> 4)));
    return mmio.read32(mmio_base + reg);
}

/// Write an APIC register, abstracting xAPIC MMIO vs x2APIC MSR.
fn regWrite(reg: u32, val: u32) void {
    if (x2apic) {
        cpu.wrmsr(X2APIC_BASE_MSR + (reg >> 4), val);
    } else {
        mmio.write32(mmio_base + reg, val);
    }
}

// --- public API ------------------------------------------------------------

/// Whether the CPU advertises x2APIC (CPUID.1:ECX bit 21).
pub fn x2apicSupported() bool {
    return (cpu.cpuid(1, 0).ecx & (1 << 21)) != 0;
}

/// Enable this core's Local APIC. `lapic_address` is the MADT base (used only in
/// xAPIC mode). Prefers x2APIC when available — it has no MMIO and a flat 32-bit
/// id space. Sets SVR software-enable + spurious vector. `is_bsp` keeps the
/// legacy-PIC delivery path open on the BSP (LINT0=ExtINT, LINT1=NMI) so the
/// existing PIC-routed timer/keyboard IRQs keep reaching the CPU; APs mask LINT0
/// since they never service legacy IRQs. Called once per core (BSP in init, each
/// AP in its apEntry).
pub fn enable(lapic_address: u32, is_bsp: bool) void {
    mmio_base = lapic_address;
    x2apic = x2apicSupported();

    // Enable the unit, keeping firmware's base-address bits (BSP flag is read-only).
    // Mode transitions are ORDERED: disabled(EN=0) -> xAPIC(EN=1) -> x2APIC(EN=1,
    // EXTD=1). EN=0,EXTD=1 is an architecturally invalid combination that #GPs on
    // real HW, so we must NOT pass through it. If firmware left the LAPIC
    // disabled, reach x2APIC in TWO writes: first set EN (xAPIC),
    // then add EXTD (x2APIC). If firmware already enabled xAPIC (EN=1), adding EXTD
    // in a single write is legal.
    const base = cpu.rdmsr(IA32_APIC_BASE);
    if ((base & APIC_BASE_ENABLE) == 0) {
        cpu.wrmsr(IA32_APIC_BASE, base | APIC_BASE_ENABLE); // step 1: enable xAPIC
    }
    if (x2apic) {
        // Now EN=1 (either firmware's or step 1's); adding EXTD is a legal one-step
        // xAPIC -> x2APIC transition.
        cpu.wrmsr(IA32_APIC_BASE, cpu.rdmsr(IA32_APIC_BASE) | APIC_BASE_X2APIC);
    }

    // Quiesce every LVT entry to a known-masked state BEFORE software-enabling the
    // unit. SDM §10.4.7.1 / Linux setup_local_APIC bring the LVTs to a known state
    // first, then enable: otherwise a warm boot where firmware (or a prior kernel)
    // left an LVT unmasked with a stale low vector could, the instant SVR enables the
    // APIC with TPR=0 (accept-all), deliver a stray interrupt on an uninitialized
    // vector — which dispatches as a CPU exception and halts the core. EVERY LVT must
    // therefore be masked here, including the timer's — none may be left at its reset
    // value for a later function to deal with. LINT0/LINT1 then take their per-core role.
    regWrite(REG_LVT_TIMER, LVT_MASKED);
    regWrite(REG_LVT_ERROR, LVT_MASKED);
    if (is_bsp) {
        regWrite(REG_LVT_LINT0, LVT_DELIVERY_EXTINT); // 8259 PIC reaches CPU here
        regWrite(REG_LVT_LINT1, LVT_DELIVERY_NMI);
    } else {
        regWrite(REG_LVT_LINT0, LVT_MASKED); // APs service no legacy PIC IRQs
        regWrite(REG_LVT_LINT1, LVT_MASKED);
    }

    // Now the LVTs are safe: accept all priorities, then software-enable the APIC and
    // set the spurious vector LAST so no interrupt can be delivered before the LVTs
    // above were programmed.
    regWrite(REG_TPR, 0);
    regWrite(REG_SVR, SVR_ENABLE | SPURIOUS_VECTOR);
}

/// This core's APIC id. In xAPIC the MMIO ID register holds it in bits[31:24];
/// in x2APIC the MSR holds the full 32-bit id directly.
pub fn id() u32 {
    const v = regRead(REG_ID);
    return if (x2apic) v else (v >> 24);
}

/// Signal end-of-interrupt to this core's LAPIC. Every APIC-delivered IRQ
/// handler must call this (except the spurious vector).
pub fn eoi() void {
    regWrite(REG_EOI, 0);
}

/// Whether x2APIC mode is active (selects the ICR write path for IPIs).
pub fn isX2() bool {
    return x2apic;
}

/// Restore LINT0 to ExtINT delivery on this core — the narrow inverse of
/// maskLint0, for the IO-APIC-routing failure path: put the legacy PIC's path
/// back without re-running the whole enable() sequence (which would also mask
/// the LVT timer out from under an armed TSC deadline).
pub fn extIntLint0() void {
    regWrite(REG_LVT_LINT0, LVT_DELIVERY_EXTINT);
}

/// Mask this core's LINT0. The BSP calls this when IRQ routing moves from the
/// legacy PIC (whose ExtINT delivery arrives here) to the IO-APIC: from that
/// point LINT0 is a stray-interrupt source, exactly as it always was on the APs.
pub fn maskLint0() void {
    regWrite(REG_LVT_LINT0, LVT_MASKED);
}

// --- IPIs (used by SMP bring-up) -------------------------------------------

/// Send an IPI to a specific destination APIC id. `cmd` carries the delivery
/// mode + vector + level/trigger bits. In xAPIC the destination goes in ICR-high
/// then writing ICR-low fires it; in x2APIC the whole thing is one 64-bit MSR.
pub fn sendIpi(dest_apic_id: u32, cmd: u32) void {
    if (x2apic) {
        // x2APIC: dest in high 32 bits, cmd in low; single atomic MSR write, no
        // delivery-status poll needed (the wrmsr is serializing and synchronous).
        cpu.wrmsr(X2APIC_ICR_MSR, (@as(u64, dest_apic_id) << 32) | cmd);
        return;
    }
    // xAPIC: poll delivery-status to idle BEFORE issuing this IPI, so a still-pending
    // PREVIOUS IPI is not clobbered by overwriting the ICR.
    // Polling after the write would let the NEXT caller race the in-flight send; the
    // contract is "ensure idle before you write". A stuck delivery-status means the
    // prior IPI never left — that is a hard fault of the interrupt fabric, so we
    // panic LOUDLY rather than silently proceed to stomp a pending IPI (project
    // no-fallback rule).
    var spins: u32 = 0;
    while ((mmio.read32(mmio_base + REG_ICR_LO) & ICR_DELIVERY_STATUS) != 0) : (spins += 1) {
        if (spins >= 1_000_000) @panic("lapic.sendIpi: ICR delivery-status stuck busy (prior IPI never delivered)");
    }
    mmio.write32(mmio_base + REG_ICR_HI, dest_apic_id << 24);
    mmio.write32(mmio_base + REG_ICR_LO, cmd);
}

/// INIT the AP into wait-for-SIPI: the canonical targeted sequence is a
/// level-triggered INIT-*assert* followed by a level-triggered INIT-*deassert*
/// (SDM §8.4.4.1). This matches Linux's
/// `wakeup_secondary_cpu_via_init`, which sends both unconditionally. The deassert
/// is a legacy requirement (no-op on P6+) but is harmless and keeps the full
/// sequence rather than a stripped-down assert-only variant. Each IPI's
/// delivery-status is polled to idle by sendIpi BEFORE the next ICR write.
pub fn sendInit(dest_apic_id: u32) void {
    sendIpi(dest_apic_id, DELIVERY_INIT | ICR_TRIGGER_LEVEL | ICR_LEVEL_ASSERT);
    sendIpi(dest_apic_id, DELIVERY_INIT | ICR_TRIGGER_LEVEL); // deassert: level=0
}

/// Cross-core scheduler wakeup IPI vector. A fixed-delivery IPI core 0 sends to a
/// parked AP to pull a blocked task back onto that AP's run queue (sched.wake).
/// Distinct from the timer vector (0x40) and spurious (0xFF).
pub const WAKEUP_VECTOR: u8 = 0x41;

/// Send a fixed-delivery IPI carrying `vector` to `dest_apic_id` (assert, edge).
/// Used for the scheduler wakeup IPI: it interrupts the target core, waking it
/// from `hlt` so its handler can run a now-runnable task.
pub fn sendFixedIpi(dest_apic_id: u32, vector: u8) void {
    sendIpi(dest_apic_id, DELIVERY_FIXED | ICR_LEVEL_ASSERT | vector);
}

/// Startup IPI carrying the real-mode trampoline page number as its vector.
/// `trampoline_page` is the physical trampoline address >> 12 (must be < 0x100).
pub fn sendStartup(dest_apic_id: u32, trampoline_page: u8) void {
    sendIpi(dest_apic_id, DELIVERY_STARTUP | ICR_LEVEL_ASSERT | trampoline_page);
}

// --- LAPIC timer (per-core preemption) -------------------------------------

/// LVT timer mode = TSC-deadline (bits[18:17] = 10).
const LVT_TIMER_TSC_DEADLINE: u32 = 0b10 << 17;

/// Put this core's LAPIC timer into TSC-deadline mode delivering `vector`. The
/// timer then fires once when the TSC reaches the value written to the
/// IA32_TSC_DEADLINE MSR (cpu/tsc.armDeadline); the Initial/Current count
/// registers are unused. Mode + vector persist; only the MSR is rewritten per
/// deadline.
pub fn useTscDeadline(vector: u8) void {
    regWrite(REG_LVT_TIMER, LVT_TIMER_TSC_DEADLINE | vector);
    // Fence the mode switch off from the caller's first tsc.armDeadline. Without
    // this the store that selects TSC-deadline mode and the subsequent MSR write
    // that arms the first deadline are unordered; a stale IA32_TSC_DEADLINE value
    // left from a prior mode could deliver a spurious timer event in the window
    // right after the mode takes effect but before the first real deadline is
    // programmed. mfence forbids that reorder (SDM Vol 3B §18.17.4).
    asm volatile ("mfence" ::: .{ .memory = true });
}
