//! PCI configuration space access + device enumeration.
//! Legacy CF8/CFC mechanism. Mainly used to find the NIC for networking.

const io = @import("../io/io.zig");
const klog = @import("../../kernel/debug/klog.zig");
const ipci = @import("ipci"); // publish the inventory for anything above the driver layer
const timer = @import("../../kernel/timer/timer.zig");

const CONFIG_ADDR: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

// PCI configuration-space register offsets (PCI Local Bus Spec 3.0 §6.1; kept in
// one place so the byte offsets below aren't bare hex at each use site).
const CFG_ENABLE: u32 = 0x80000000; // CONFIG_ADDR bit 31: enable config cycle
const REG_COMMAND: u8 = 0x04; // Command (lo 16) + Status (hi 16)
const REG_HEADER_TYPE: u8 = 0x0C; // BIST/Header/Latency/Cacheline dword
const REG_BAR0: u8 = 0x10; // first Base Address Register
const REG_CAP_PTR: u8 = 0x34; // capabilities-list pointer (offset of first cap)
const CMD_MEM_AND_MASTER: u32 = 0x06; // Command bits: Memory Space | Bus Master
const HEADER_MULTIFUNCTION: u8 = 0x80; // Header Type bit 7: multi-function device
const STATUS_CAP_LIST: u16 = 1 << 4; // Status bit 4: capabilities list present

// Type 1 (PCI-to-PCI bridge) header fields + Secondary Bus Reset, cross-checked
// against Linux pci_reset_secondary_bus and the scripts/gpu/sbr.sh procedure
// used on this machine.
const REG_BUS_NUMBERS: u8 = 0x18; // primary/secondary/subordinate bus + latency
const REG_BRIDGE_CONTROL: u8 = 0x3E; // Bridge Control (u16)
const BRIDGE_CTL_SBR: u16 = 1 << 6; // Secondary Bus Reset bit
const CLASS_BRIDGE: u8 = 0x06;
const SUBCLASS_PCI_BRIDGE: u8 = 0x04;
const CAP_ID_PCIE: u8 = 0x10; // PCI Express capability
// PCIe capability register offsets (from the capability base).
const PCIE_DEVCTL: u8 = 0x08; // Device Control (u16) — MPS/MRRS live here
const PCIE_LNKCTL: u8 = 0x10; // Link Control (u16)
const PCIE_DEVCTL2: u8 = 0x28; // Device Control 2 (u16)

pub const Device = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,

    /// 32-bit config-space read at `offset` (must be 4-byte aligned).
    pub fn read32(self: Device, offset: u8) u32 {
        return cfgRead(self.bus, self.slot, self.func, offset);
    }
    /// 32-bit config-space write at `offset` (must be 4-byte aligned).
    pub fn write32(self: Device, offset: u8, value: u32) void {
        cfgWrite(self.bus, self.slot, self.func, offset, value);
    }
    /// Raw contents of BAR `n` (undecoded — includes the low type/flag bits).
    pub fn bar(self: Device, n: u2) u32 {
        return self.read32(REG_BAR0 + @as(u8, n) * 4);
    }

    /// 16-bit config read at `offset` (must be 2-byte aligned). Derived from the
    /// 32-bit mechanism: read the containing dword, select the half.
    pub fn read16(self: Device, offset: u8) u16 {
        const dw = self.read32(offset & 0xFC);
        return @truncate(dw >> (@as(u5, @intCast(offset & 2)) * 8));
    }

    /// 16-bit config write at `offset` (must be 2-byte aligned): read-modify-write
    /// the containing dword.
    pub fn write16(self: Device, offset: u8, value: u16) void {
        const base = offset & 0xFC;
        const shift: u5 = @intCast((offset & 2) * 8);
        const dw = self.read32(base);
        const cleared = dw & ~(@as(u32, 0xFFFF) << shift);
        self.write32(base, cleared | (@as(u32, value) << shift));
    }

    /// Walk the PCI capability list for a capability with id `cap_id` (e.g.
    /// 0x05 MSI, 0x11 MSI-X, 0x10 PCIe). Returns the config-space offset of the
    /// capability's first byte, or null if absent / no capability list.
    pub fn findCapability(self: Device, cap_id: u8) ?u8 {
        const status: u16 = @truncate(self.read32(REG_COMMAND) >> 16);
        if (status & STATUS_CAP_LIST == 0) return null; // no capabilities list
        var ptr: u8 = @truncate(self.read32(REG_CAP_PTR) & 0xFC); // cap pointer
        var guard: u8 = 0; // bounded walk: list is at most 48 entries
        while (ptr != 0 and guard < 48) : (guard += 1) {
            const header = self.read32(ptr);
            const id: u8 = @truncate(header);
            if (id == cap_id) return ptr;
            ptr = @truncate((header >> 8) & 0xFC); // next pointer
        }
        return null;
    }
    /// Enable memory space + bus mastering (required for NIC DMA).
    pub fn enableBusMaster(self: Device) void {
        const cmd = self.read32(REG_COMMAND);
        self.write32(REG_COMMAND, cmd | CMD_MEM_AND_MASTER);
    }

    /// Transition the device to PCI power state D0 (fully on). A device left in
    /// D3 has powered-down register blocks (engine MMIO reads return error
    /// poison), so this is required before touching engine registers. Uses the
    /// PCI Power Management capability (id 0x01): PMCSR is at cap+4, power state
    /// in bits[1:0]. No-op if there's no PM cap or it's already D0.
    pub fn setPowerStateD0(self: Device) void {
        const pm = self.findCapability(0x01) orelse return;
        const pmcsr_off = pm + 4;
        const pmcsr = self.read16(pmcsr_off);
        if (pmcsr & 0x3 == 0) return; // already D0
        self.write16(pmcsr_off, pmcsr & ~@as(u16, 0x3));
    }

    /// Snapshot the config state a bus reset destroys: the 16 header dwords
    /// (BARs, Command, interrupt line…) and, when the device is PCIe, the
    /// Device Control / Link Control / Device Control 2 words (an MPS mismatch
    /// after reset corrupts TLPs). Mirror of Linux pci_save_state() at the
    /// depth kudos needs.
    pub fn saveConfig(self: Device) ConfigState {
        var st = ConfigState{ .header = undefined, .pcie_cap = self.findCapability(CAP_ID_PCIE), .devctl = 0, .lnkctl = 0, .devctl2 = 0 };
        var i: u8 = 0;
        while (i < 16) : (i += 1) st.header[i] = self.read32(i * 4);
        if (st.pcie_cap) |cap| {
            st.devctl = self.read16(cap + PCIE_DEVCTL);
            st.lnkctl = self.read16(cap + PCIE_LNKCTL);
            st.devctl2 = self.read16(cap + PCIE_DEVCTL2);
        }
        return st;
    }

    /// Restore a saveConfig snapshot after a bus reset. PCIe control words
    /// first, then the header dwords in REVERSE order so the BARs are back
    /// before the Command register re-enables decode/mastering — the Linux
    /// pci_restore_state ordering.
    pub fn restoreConfig(self: Device, st: ConfigState) void {
        if (st.pcie_cap) |cap| {
            self.write16(cap + PCIE_DEVCTL, st.devctl);
            self.write16(cap + PCIE_LNKCTL, st.lnkctl);
            self.write16(cap + PCIE_DEVCTL2, st.devctl2);
        }
        var i: u8 = 16;
        while (i > 0) {
            i -= 1;
            self.write32(i * 4, st.header[i]);
        }
    }
};

/// Config state captured by Device.saveConfig / reapplied by restoreConfig.
pub const ConfigState = struct {
    header: [16]u32, // config dwords 0x00–0x3C
    pcie_cap: ?u8, // PCIe capability offset (null: legacy device)
    devctl: u16,
    lnkctl: u16,
    devctl2: u16,
};

/// The Type 1 bridge whose SECONDARY bus is `dev`'s bus — the port a Secondary
/// Bus Reset for `dev` must be issued on. Null when `dev` sits on the root bus
/// (bus 0 has no parent bridge to reset through).
pub fn findParentBridge(dev: Device) ?Device {
    for (list()) |d| {
        if (d.class != CLASS_BRIDGE or d.subclass != SUBCLASS_PCI_BRIDGE) continue;
        const secondary: u8 = @truncate(d.read32(REG_BUS_NUMBERS) >> 8);
        if (secondary == dev.bus) return d;
    }
    return null;
}

/// Secondary Bus Reset: pulse BRIDGE_CONTROL bit 6 on `bridge`, resetting every
/// device below it. Timings are the caller's, grounded in its reference (the
/// 4090 uses scripts/gpu/sbr.sh's proven 50 ms hold + 1000 ms settle; the PCI
/// spec floor is 1 ms hold). After the settle, polls `below`'s vendor ID until
/// the device answers config cycles again; returns false (fail loudly, caller
/// decides) if it never comes back within ~1 s more.
pub fn secondaryBusReset(bridge: Device, below: Device, hold_ms: u64, settle_ms: u64) bool {
    const ctl = bridge.read16(REG_BRIDGE_CONTROL);
    bridge.write16(REG_BRIDGE_CONTROL, ctl | BRIDGE_CTL_SBR);
    timer.sleep(hold_ms);
    bridge.write16(REG_BRIDGE_CONTROL, ctl);
    timer.sleep(settle_ms);
    var waited: u64 = 0;
    while (below.read32(0x00) & 0xFFFF == 0xFFFF) {
        if (waited >= 1000) return false;
        timer.sleep(10);
        waited += 10;
    }
    return true;
}

/// Encode a bus/slot/func/offset into the CONFIG_ADDR dword for a config cycle
/// (enable bit set; offset forced to 4-byte alignment).
fn address(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    return CFG_ENABLE |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (offset & 0xFC);
}

/// Read a config-space dword via the CF8/CFC mechanism.
fn cfgRead(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    io.outl(CONFIG_ADDR, address(bus, slot, func, offset));
    return io.inl(CONFIG_DATA);
}

/// Write a config-space dword via the CF8/CFC mechanism.
fn cfgWrite(bus: u8, slot: u8, func: u8, offset: u8, value: u32) void {
    io.outl(CONFIG_ADDR, address(bus, slot, func, offset));
    io.outl(CONFIG_DATA, value);
}

var devices: [64]Device = undefined;
var count: usize = 0;

/// Probe one bus/slot/func: if a device is present (vendor != 0xFFFF), record it
/// (vendor/device/class/subclass/prog-if) in `devices`. Silently skips empty
/// functions; a device found once the fixed `devices` array is full is LOGGED
/// as dropped — losing one silently would surface only as an unexplained dead
/// NIC/xHCI far from the cause (fail-loudly rule).
fn probe(bus: u8, slot: u8, func: u8) void {
    const id = cfgRead(bus, slot, func, 0x00);
    const vendor: u16 = @truncate(id & 0xFFFF);
    if (vendor == 0xFFFF) return;
    const classreg = cfgRead(bus, slot, func, 0x08);
    if (count >= devices.len) {
        klog.puts("pci: device table FULL, dropping ");
        klog.putHex(bus);
        klog.putc(':');
        klog.putHex(slot);
        klog.putc('.');
        klog.putHex(func);
        klog.puts(" vendor ");
        klog.putHex(vendor);
        klog.puts(" device ");
        klog.putHex(id >> 16);
        klog.putc('\n');
        return;
    }
    devices[count] = .{
        .bus = bus,
        .slot = slot,
        .func = func,
        .vendor = vendor,
        .device = @truncate(id >> 16),
        .class = @truncate(classreg >> 24),
        .subclass = @truncate((classreg >> 16) & 0xFF),
        .prog_if = @truncate((classreg >> 8) & 0xFF),
    };
    count += 1;
}

/// Brute-force enumerate every bus/slot (and the extra functions of multi-function
/// devices), populating the `devices` table. Run once at boot before any lookup.
pub fn init() void {
    count = 0;
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var slot: u8 = 0;
        while (slot < 32) : (slot += 1) {
            const b: u8 = @intCast(bus);
            if (cfgRead(b, slot, 0, 0x00) & 0xFFFF == 0xFFFF) continue;
            probe(b, slot, 0);
            const header: u8 = @truncate(cfgRead(b, slot, 0, REG_HEADER_TYPE) >> 16);
            if (header & HEADER_MULTIFUNCTION != 0) {
                var func: u8 = 1;
                while (func < 8) : (func += 1) probe(b, slot, func);
            }
        }
    }
    publish();
}

/// All devices discovered by `init`.
pub fn list() []const Device {
    return devices[0..count];
}

/// Identity of every device found, for anything above the driver layer.
///
/// A projection, not a copy of the driver's state: `Device` here can also read and
/// write config space, which is port IO and stays in this group. What crosses the seam
/// is the part of a device that means something WITHOUT a bus transaction.
var ids: [devices.len]ipci.Device = undefined;

fn publish() void {
    for (devices[0..count], 0..) |d, i| {
        ids[i] = .{
            .bus = d.bus,
            .slot = d.slot,
            .func = d.func,
            .vendor = d.vendor,
            .device = d.device,
            .class = d.class,
            .subclass = d.subclass,
            .prog_if = d.prog_if,
        };
    }
    ipci.devices = ids[0..count];
}

/// Find the first device with the given vendor+device id, or null.
pub fn findByIds(vendor: u16, device: u16) ?Device {
    for (devices[0..count]) |d| {
        if (d.vendor == vendor and d.device == device) return d;
    }
    return null;
}

/// Find the first device matching a class/subclass/prog-if (e.g. xHCI =
/// 0x0C/0x03/0x30). Works across vendors (QEMU vs Intel) by class, not IDs.
pub fn findClass(class: u8, subclass: u8, prog_if: u8) ?Device {
    for (devices[0..count]) |d| {
        if (d.class == class and d.subclass == subclass and d.prog_if == prog_if) return d;
    }
    return null;
}

/// Read BAR `n` as a (possibly 64-bit) memory base, masking the low flag bits.
pub fn bar64(self: Device, n: u2) u64 {
    const lo = self.read32(0x10 + @as(u8, n) * 4);
    const base: u64 = lo & ~@as(u32, 0xF);
    if ((lo & 0x6) == 0x4) { // 64-bit memory BAR -> high half in the next BAR
        const hi = self.read32(0x10 + (@as(u8, n) + 1) * 4);
        return (@as(u64, hi) << 32) | base;
    }
    return base;
}
