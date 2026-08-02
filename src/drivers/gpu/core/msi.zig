//! MSI interrupt setup for the GPU — the kudos side of the RM's ISR registration.
//! kudos has no MSI allocator, so one lives here, under src/drivers/gpu/: find the
//! device MSI capability, program its message address/data to deliver a chosen IDT
//! vector to the BSP LAPIC, and route that vector to the RM's ISR via
//! isr.registerMsi (the MSI vector range, LAPIC-EOI'd — distinct from the PIC IRQ
//! table).
//!
//! Reuses pci.Device's capability walk (pci.findCapability) and 16-bit config
//! access; modifies no other module.
//!
//! M9 scope: MSI (cap 0x05) only. The GSP needs a single interrupt source, which
//! one MSI vector serves. MSI-X (cap 0x11) requires mapping a table in a BAR and
//! is deferred until a device or a later milestone actually requires it.

const pci = @import("../../pci/pci.zig");
const isr = @import("../../../kernel/interrupts/isr.zig");
const lapic = @import("../../../kernel/apic/lapic.zig");
const calc = @import("../base/calc.zig");

const MSI_CAP_ID: u8 = 0x05;

// Message Control bits within the PCI MSI capability.
const MC_ENABLE: u16 = 1 << 0;
const MC_64BIT: u16 = 1 << 7;
// Multiple-Message-Enable is bits[6:4]; writing 0 requests exactly one vector.
const MC_MME_MASK: u16 = 0x7 << 4;

/// The RM's interrupt service routine, invoked from our vector handler. Returns
/// true if the interrupt was the GPU's (RM `nvidia_isr` equivalent).
pub const IsrFn = *const fn () bool;

/// A configured MSI vector for the GPU.
pub const Msi = struct {
    vector: u8,
    dev: pci.Device,
};

// IRQ-table slot the registered handler is stored under. The MSI vector is
// chosen in the device-IRQ range; we register the handler at (vector - 0x20),
// matching how the IDT maps device IRQs to vector 0x20+irq. Set by setup().
var rm_isr: ?IsrFn = null;

/// Vector-handler trampoline registered with the IDT. Forwards to the RM ISR and
/// signals EOI to the LAPIC (every APIC-delivered handler must).
fn trampoline() void {
    if (rm_isr) |f| _ = f();
    lapic.eoi();
}

/// Find the device's MSI capability, program it to deliver `vector` to the BSP
/// LAPIC (physical destination, fixed/edge), enable it, and register `handler`.
/// Fails loudly if the device has no MSI capability — no silent "interrupts off"
/// mode (CLAUDE.md no-fallbacks). `vector` must be in the device-IRQ range so
/// (vector - 0x20) is a valid IRQ slot.
pub fn setup(dev: pci.Device, vector: u8, handler: IsrFn) Msi {
    const cap = dev.findCapability(MSI_CAP_ID) orelse
        @panic("gpu.msi: device has no MSI capability (MSI-X not yet supported, M9)");

    // x86 message address/data, composed in calc.zig (host-unit-tested).
    // Physical destination to the BSP.
    const addr: u32 = calc.msiAddress(lapic.id());
    const data: u16 = calc.msiData(vector);

    const ctrl = dev.read16(cap + 0x02);

    // Program address (low, and high if 64-bit capable) and data. The data-register
    // offset depends on the 64-bit-capable bit: 0x0C when 64-bit, else 0x08.
    dev.write32(cap + 0x04, addr);
    if (ctrl & MC_64BIT != 0) {
        dev.write32(cap + 0x08, 0); // address high (LAPIC is below 4 GiB)
        dev.write16(cap + 0x0C, data);
    } else {
        dev.write16(cap + 0x08, data);
    }

    // Request exactly one vector (MME=0) and set the master enable.
    const new_ctrl = (ctrl & ~MC_MME_MASK) | MC_ENABLE;
    dev.write16(cap + 0x02, new_ctrl);

    // Route the vector to the RM ISR. MSIs are LAPIC-delivered, so register in
    // the MSI handler table (not the PIC IRQ table) — isr.registerMsi dispatches
    // the trampoline, which owns the LAPIC EOI. registerMsi bounds-checks the
    // vector against the MSI range and panics on a bad one.
    rm_isr = handler;
    isr.registerMsi(vector, trampoline);

    return .{ .vector = vector, .dev = dev };
}
