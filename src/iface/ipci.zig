//! IPci — the machine's PCI devices, as anything above the driver layer sees them.
//!
//! This is a list of facts, not a vtable, because that is all the need is: a diagnostic
//! that prints the hardware inventory wants to NAME each device, not TALK to it.
//! Talking to one means config-space reads and writes, which are port IO, which stay in
//! `drivers/pci/` where the rest of the port IO lives.
//!
//! The PCI driver fills `devices` in once, during its bus scan. Nothing else writes it.
//!
//! LEAF module: plain data, so the kernel and the host tests both compile it.

/// One device, identified. These are the fields printed by an inventory and matched on
/// by a driver looking for its own hardware — the parts of a PCI device that mean
/// something without a bus transaction.
pub const Device = struct {
    /// Where it sits on the bus.
    bus: u8,
    slot: u8,
    func: u8,
    /// Who made it, and which part it is. `vendor` is assigned by the PCI-SIG; the pair
    /// is what a driver matches on (0x8086:0x125c is Intel's I226-V; 0x10de:0x2684 is
    /// the RTX 4090).
    vendor: u16,
    device: u16,
    /// What kind of thing it is, coarse to fine. A driver that wants "any NVMe disk"
    /// matches on these instead of on a vendor pair it would have to keep updating.
    class: u8,
    subclass: u8,
    prog_if: u8,
};

/// Every device found during the bus scan. Empty until the PCI driver has run.
pub var devices: []const Device = &.{};
