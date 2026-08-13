//! IO-APIC: deliver device interrupts (Global System Interrupts) to the LAPICs.
//!
//! kudos routes exactly one line through here today — the PIT wall-clock tick —
//! and fans it across every online core by rotating the redirection entry's
//! destination one core forward on each delivery (KRN-012: a device's
//! interrupts reach any online core, confined to none). Rotation uses physical
//! destinations, which mean the same thing in xAPIC and x2APIC mode and under
//! both QEMU and real chipsets; lowest-priority arbitration does not (its
//! logical destinations change encoding in x2APIC mode and cap out at eight
//! cores in flat model).
//!
//! Register model (Intel 82093AA / ICH datasheets, cross-checked vs Linux
//! arch/x86/kernel/apic/io_apic.c): an index register at base+0x00 selects a
//! 32-bit register, read/written through the window at base+0x10. Redirection
//! entry N is the register pair 0x10+2N (low dword: vector, delivery mode,
//! polarity, trigger, mask) and 0x11+2N (high dword: destination in bits
//! 31:24).

const acpi = @import("../acpi/acpi.zig");
const mmio = @import("../io/mmio.zig");
const SpinLock = @import("../sync/spinlock.zig").SpinLock;

/// Vector the IO-APIC delivers the rotating wall-clock tick on. Above the LAPIC
/// timer (0x40, isr.LAPIC_TIMER_VECTOR) and the scheduler wakeup IPI (0x41,
/// lapic.WAKEUP_VECTOR); below the MSI range (0x50+). The single owner of this
/// value — isrDispatch imports it to route the tick arm.
pub const TICK_VECTOR: u8 = 0x42;

// Index/window access ports, relative to an IO-APIC's MMIO base.
const REG_SELECT: u64 = 0x00;
const REG_WINDOW: u64 = 0x10;

// Selectable registers.
const REG_VERSION: u32 = 0x01; // bits 23:16 = max redirection entry index
const REG_REDIR_BASE: u32 = 0x10; // entry N = registers 0x10+2N (lo), +1 (hi)

// Redirection-entry low-dword bits.
const RTE_ACTIVE_LOW: u32 = 1 << 13;
const RTE_LEVEL_TRIGGERED: u32 = 1 << 15;
const RTE_MASKED: u32 = 1 << 16;
// Delivery mode fixed (000) and physical destination mode (0) are the zero
// encodings, so an unmasked RTE low dword is just the flag bits above + vector.

/// The largest APIC id a redirection entry's 8-bit physical destination can
/// name without interrupt remapping (0xFF is the broadcast encoding).
const MAX_RTE_DEST_ID: u32 = 0xFE;

// The IO-APICs discovered by the MADT, recorded by init(). Written once at
// bring-up on the BSP, read-only afterwards.
var ioapics: [acpi.MAX_IOAPICS]acpi.IoApic = undefined;
var ioapic_count: usize = 0;
var overrides: [acpi.MAX_IRQ_OVERRIDES]acpi.IrqOverride = undefined;
var override_count: usize = 0;

// The tick rotation: the APIC ids of every core eligible to service the
// wall-clock tick (membership is JOIN-based — each core enrols itself in
// joinRotation once its scheduler is up, so an id in here is never an
// uninitialized per-CPU read), the index of the entry the tick is currently
// aimed at, and the GSI being rotated.
//
// `lock` serializes EVERYTHING here AND every IO-APIC index/window access:
// rotate() runs in interrupt context on whichever core took the tick while
// dropFromRotation runs on a faulting core and join/enable run at bring-up —
// three cores can race the shared select register and the rotation state, and
// an interleaved drop-vs-rotate could re-aim the tick at the core that is
// about to park masked, stalling tick delivery forever (the wall clock itself
// is TSC-derived — timer.millis via uptime.zig — so time survives, but every
// cadence denominated in raw ticks, timer.now, would freeze). One lock closes
// both races; every critical section is a handful of MMIO accesses.
var lock: SpinLock = .{};
var targets: [acpi.MAX_CPUS]u32 = undefined;
var target_count: usize = 0;
var next: usize = 0;
var tick_gsi: u32 = 0;
var tick_vector_lo: u32 = 0; // the RTE low dword the rotation programmed
var rotating: bool = false;

/// Record the MADT's IO-APICs and interrupt-source overrides. Called once on
/// the BSP before any routing.
pub fn init(topo: *const acpi.Topology) void {
    ioapic_count = topo.ioapic_count;
    for (topo.ioapics[0..topo.ioapic_count], 0..) |a, i| ioapics[i] = a;
    override_count = topo.irq_override_count;
    for (topo.irq_overrides[0..topo.irq_override_count], 0..) |o, i| overrides[i] = o;
}

/// Whether the MADT described at least one IO-APIC. Without one the PIC path
/// stays in place (a true system boundary, same as missing ACPI).
pub fn available() bool {
    return ioapic_count > 0;
}

/// The GSI an ISA IRQ actually arrives on, with its polarity/trigger: the
/// MADT override when one names this IRQ, else the identity mapping with ISA
/// defaults (active-high, edge).
pub fn isaRoute(irq: u8) acpi.IrqOverride {
    for (overrides[0..override_count]) |o| {
        if (o.source_irq == irq) return o;
    }
    return .{ .source_irq = irq, .gsi = irq, .active_low = false, .level_triggered = false };
}

/// The IO-APIC whose redirection range contains `gsi`, or null. Range width
/// comes from the version register's max-entry field.
fn ioapicFor(gsi: u32) ?*const acpi.IoApic {
    for (ioapics[0..ioapic_count]) |*a| {
        const max_entry = (regRead(a.address, REG_VERSION) >> 16) & 0xFF;
        if (gsi >= a.gsi_base and gsi <= a.gsi_base + max_entry) return a;
    }
    return null;
}

fn regRead(base: u32, reg: u32) u32 {
    mmio.write32(@as(u64, base) + REG_SELECT, reg);
    return mmio.read32(@as(u64, base) + REG_WINDOW);
}

fn regWrite(base: u32, reg: u32, val: u32) void {
    mmio.write32(@as(u64, base) + REG_SELECT, reg);
    mmio.write32(@as(u64, base) + REG_WINDOW, val);
}

/// Program `gsi`'s redirection entry under the module lock: fixed delivery of
/// `vector` to physical APIC id `dest_apic_id`, unmasked. Returns false if no
/// IO-APIC covers the GSI or the id does not fit an 8-bit physical destination.
fn routeLocked(gsi: u32, lo: u32, dest_apic_id: u32) bool {
    if (dest_apic_id > MAX_RTE_DEST_ID) return false;
    const a = ioapicFor(gsi) orelse return false;
    const entry = REG_REDIR_BASE + 2 * (gsi - a.gsi_base);
    // Mask while both halves are rewritten so a tick cannot fire between the
    // destination taking effect and the vector taking effect.
    regWrite(a.address, entry, lo | RTE_MASKED);
    regWrite(a.address, entry + 1, dest_apic_id << 24);
    regWrite(a.address, entry, lo);
    return true;
}

/// Re-aim `gsi` at another core (lock held). Only the high dword changes — one
/// 32-bit write, safe against an in-flight edge (the entry stays valid).
fn retargetLocked(gsi: u32, dest_apic_id: u32) void {
    const a = ioapicFor(gsi) orelse return;
    const entry = REG_REDIR_BASE + 2 * (gsi - a.gsi_base);
    regWrite(a.address, entry + 1, dest_apic_id << 24);
}

/// Enrol the calling core in the tick rotation. Each core calls this from its
/// own scheduler start — the one point where its LAPIC id is certainly its own
/// published value — so the rotation can never capture an uninitialized id,
/// and a core whose scheduler comes up AFTER the rotation was enabled still
/// joins it (KRN-012 holds for stragglers). An id an RTE cannot address is
/// refused (never true on real parts below 255 cores).
pub fn joinRotation(apic_id: u32) void {
    if (apic_id > MAX_RTE_DEST_ID) return;
    const if_was = lock.acquireIrqSave();
    defer lock.releaseIrqRestore(if_was);
    for (targets[0..target_count]) |t| {
        if (t == apic_id) return; // already enrolled
    }
    if (target_count == targets.len) return;
    targets[target_count] = apic_id;
    target_count += 1;
}

/// Start rotating `gsi` across the cores that have joined (joinRotation),
/// aiming first at the first joiner. Returns false — leaving the caller's
/// delivery path in place — when nobody joined or no IO-APIC covers the GSI.
/// Called once on the BSP at scheduler bring-up.
pub fn enableTickRotation(gsi: u32, vector: u8, active_low: bool, level_triggered: bool) bool {
    const if_was = lock.acquireIrqSave();
    defer lock.releaseIrqRestore(if_was);
    if (target_count == 0) return false;
    var lo: u32 = vector;
    if (active_low) lo |= RTE_ACTIVE_LOW;
    if (level_triggered) lo |= RTE_LEVEL_TRIGGERED;
    next = 0;
    tick_gsi = gsi;
    tick_vector_lo = lo;
    if (!routeLocked(gsi, lo, targets[0])) return false;
    rotating = true;
    return true;
}

/// Advance the rotation one core: called from the tick handler, on whichever
/// core just serviced it, so over any window of `target_count` ticks every
/// enrolled core sees the device once (KRN-012). The whole step — pick and
/// retarget — happens under the lock, so it cannot interleave with a faulting
/// core's dropFromRotation and resurrect an id the drop just removed.
pub fn rotate() void {
    const if_was = lock.acquireIrqSave();
    defer lock.releaseIrqRestore(if_was);
    if (!rotating or target_count == 0) return;
    next = (next + 1) % target_count;
    retargetLocked(tick_gsi, targets[next]);
}

/// Remove `apic_id` from the tick rotation — a faulting core evacuating itself
/// before it parks with interrupts masked forever. If the tick is currently
/// aimed here, re-aim it immediately: a tick delivered to a parked core would
/// never be serviced and never rotate onward, stalling delivery (and every
/// raw-tick cadence) for good — the wall clock itself rides the TSC and
/// survives (timer.millis via uptime.zig). Under the same lock as rotate(), so
/// no concurrent step can re-aim the RTE at the departing core after this
/// retarget.
pub fn dropFromRotation(apic_id: u32) void {
    const if_was = lock.acquireIrqSave();
    defer lock.releaseIrqRestore(if_was);
    if (!rotating) return;
    var i: usize = 0;
    while (i < target_count) {
        if (targets[i] == apic_id) {
            target_count -= 1;
            targets[i] = targets[target_count];
            continue;
        }
        i += 1;
    }
    if (target_count == 0) return; // last core standing keeps the RTE it has
    next %= target_count;
    retargetLocked(tick_gsi, targets[next]);
}
