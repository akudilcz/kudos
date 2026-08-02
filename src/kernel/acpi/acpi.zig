//! ACPI table discovery + MADT parsing: find the CPUs and the I/O APIC.
//!
//! Walks RSDP -> RSDT/XSDT -> MADT ("APIC") to enumerate Local APICs (the CPU
//! cores) and I/O APICs. This is the first step of SMP bring-up — the BSP needs
//! the AP APIC ids before it can send INIT-SIPI-SIPI.
//!
//! Every offset, signature, and the Enabled/Online-Capable usability rule is
//! cited in ACPI 6.x §5.2, cross-checked against Linux arch/x86/kernel/acpi/boot.c.
//! All physical addresses are read directly: the low 4 GiB (and well beyond, via
//! 1 GiB pages) is identity-mapped by the boot trampoline, so phys == virt for
//! table access here.

const ilog = @import("ilog");

/// The local APIC's physical base address before any MADT override — the
/// IA32_APIC_BASE reset value (Intel SDM Vol 3A §11.4.4). ACPI owns the
/// constant because the MADT's Local Interrupt Controller Address field states
/// this same default; the APIC driver imports it from here.
pub const LAPIC_DEFAULT_BASE: u32 = 0xFEE00000;

/// Hard cap on cores we track. A fixed cap keeps the topology tables in .bss, so
/// MADT parsing runs before any allocator exists; 64 logical processors covers
/// the machines kudos targets.
///
/// VOCABULARY: a kudos "core" is one LOGICAL processor — one Local-APIC entry
/// in the MADT, i.e. one hardware thread. With hyperthreading enabled a
/// physical core presents two of them (SMT siblings) and both are counted;
/// kudos deliberately models the flat logical list and no package/core/thread
/// hierarchy — nothing here schedules SMT-aware, so the hierarchy would be
/// structure without a consumer.
pub const MAX_CPUS = 64;
pub const MAX_IOAPICS = 8;
pub const MAX_IRQ_OVERRIDES = 16; // one per ISA IRQ line is the most a MADT can say

/// One CPU core discovered in the MADT (Local APIC or x2APIC entry).
pub const Cpu = struct {
    acpi_uid: u32,
    apic_id: u32,
    usable: bool, // Enabled OR Online-Capable
};

/// One I/O APIC discovered in the MADT: its id, MMIO base, and GSI range start.
pub const IoApic = struct {
    id: u8,
    address: u32, // MMIO base
    gsi_base: u32,
};

/// One Interrupt Source Override from the MADT (type 2): ISA IRQ `source_irq`
/// actually arrives on Global System Interrupt `gsi`, with the given polarity
/// and trigger. Without an override an ISA IRQ maps to the GSI of the same
/// number, active-high, edge-triggered.
pub const IrqOverride = struct {
    source_irq: u8,
    gsi: u32,
    active_low: bool,
    level_triggered: bool,
};

pub const Topology = struct {
    cpus: [MAX_CPUS]Cpu,
    cpu_count: usize,
    ioapics: [MAX_IOAPICS]IoApic,
    ioapic_count: usize,
    irq_overrides: [MAX_IRQ_OVERRIDES]IrqOverride,
    irq_override_count: usize,
    lapic_address: u32, // LAPIC MMIO base (MADT local_apic_address, type-5 override)
    pic_compat: bool, // MADT flags bit0: dual-8259 present, must be masked

    /// Number of cores marked usable (Enabled or Online-Capable).
    pub fn usableCount(self: *const Topology) usize {
        var n: usize = 0;
        for (self.cpus[0..self.cpu_count]) |c| {
            if (c.usable) n += 1;
        }
        return n;
    }
};

// --- raw table layouts -----------------------------------------------------

const Rsdp = extern struct {
    signature: [8]u8, // "RSD PTR " (trailing space)
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,
    // ACPI 2.0+ (revision >= 2) extended fields:
    length: u32,
    xsdt_address: u64 align(4),
    extended_checksum: u8,
    reserved: [3]u8,
};

const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

// MADT entry types.
pub const MADT_LAPIC: u8 = 0;
pub const MADT_IOAPIC: u8 = 1;
pub const MADT_IRQ_OVERRIDE: u8 = 2;
pub const MADT_LAPIC_ADDR_OVERRIDE: u8 = 5;
pub const MADT_X2APIC: u8 = 9;

// --- memory helpers --------------------------------------------------------

/// Typed, unaligned read handle for a physical address. ACPI tables are packed
/// and phys==virt here (identity-mapped), so alignment(1) lets us read any field
/// at its byte offset without a bus fault.
fn phys(comptime T: type, addr: u64) *align(1) const T {
    return @ptrFromInt(addr);
}

/// Read a little-endian u16 at physical `addr` (used for the EBDA segment word).
fn readU16(addr: u64) u16 {
    return phys(u16, addr).*;
}

/// Sum of `len` bytes at `addr`, truncated to u8. A valid ACPI table sums to 0.
fn checksum(addr: u64, len: usize) u8 {
    var sum: u8 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        sum +%= phys(u8, addr + i).*;
    }
    return sum;
}

// --- RSDP discovery --------------------------------------------------------

pub const RSDP_SIG = "RSD PTR ";

/// Does the byte string `sig` appear at physical `addr`? Used to match ACPI table
/// signatures ("RSD PTR ", "XSDT", "RSDT", "APIC").
fn sigMatches(addr: u64, sig: []const u8) bool {
    for (sig, 0..) |c, i| {
        if (phys(u8, addr + i).* != c) return false;
    }
    return true;
}

/// Scan a physical range [start, end) on 16-byte boundaries for the RSDP.
pub fn scanForRsdp(start: u64, end: u64) ?u64 {
    var a = start;
    while (a < end) : (a += 16) {
        if (!sigMatches(a, RSDP_SIG)) continue;
        // ACPI 1.0 checksum: first 20 bytes must sum to 0.
        if (checksum(a, 20) != 0) continue;
        const rsdp = phys(Rsdp, a);
        // ACPI 2.0+: the full 36-byte structure must also sum to 0.
        if (rsdp.revision >= 2 and checksum(a, rsdp.length) != 0) continue;
        return a;
    }
    return null;
}

// RSDP search locations (ACPI 6.x §5.2.5.1). Both are
// below 1 MiB and identity-mapped.
const EBDA_SEG_PTR: u64 = 0x40E; // BDA word holding the EBDA segment (paragraph)
const BIOS_ROM_START: u64 = 0xE0000; // start of the BIOS ROM area to scan
const BIOS_ROM_END: u64 = 0x100000; // 1 MiB — one past the BIOS ROM area

/// Locate the RSDP: the first 1 KiB of the EBDA (segment word at EBDA_SEG_PTR),
/// then the BIOS ROM area. Returns its physical address, or null if not found.
fn findRsdp() ?u64 {
    const ebda_seg = readU16(EBDA_SEG_PTR);
    const ebda: u64 = @as(u64, ebda_seg) << 4;
    if (ebda != 0) {
        if (scanForRsdp(ebda, ebda + 1024)) |a| return a;
    }
    return scanForRsdp(BIOS_ROM_START, BIOS_ROM_END);
}

// --- table walk ------------------------------------------------------------

/// Find the MADT physical address by walking the RSDT (u32 entries) or XSDT
/// (u64 entries) for a table whose signature is "APIC".
pub fn findMadt(rsdp_addr: u64) ?u64 {
    const rsdp = phys(Rsdp, rsdp_addr);

    // Prefer the XSDT (64-bit pointers) on ACPI 2.0+.
    const use_xsdt = rsdp.revision >= 2 and rsdp.xsdt_address != 0;
    const sdt_addr: u64 = if (use_xsdt) rsdp.xsdt_address else rsdp.rsdt_address;
    const hdr = phys(SdtHeader, sdt_addr);
    // Validate the root table before trusting its length: check the signature
    // ("XSDT"/"RSDT") and require a length at least the header, THEN the checksum.
    // A malformed root pointer with length < 36 would otherwise underflow the entry
    // `count` below to a near-2^64 value and walk arbitrary memory.
    if (!sigMatches(sdt_addr, if (use_xsdt) "XSDT" else "RSDT")) return null;
    if (hdr.length < @sizeOf(SdtHeader)) return null;
    if (checksum(sdt_addr, hdr.length) != 0) return null;

    const entry_size: usize = if (use_xsdt) 8 else 4;
    const entries_base = sdt_addr + @sizeOf(SdtHeader);
    const count = (hdr.length - @sizeOf(SdtHeader)) / entry_size;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const ea = entries_base + i * entry_size;
        const table_addr: u64 = if (use_xsdt) phys(u64, ea).* else phys(u32, ea).*;
        if (sigMatches(table_addr, "APIC")) return table_addr;
    }
    return null;
}

/// Parse the MADT into `out`. Returns false if the table is malformed (bad
/// signature/length/checksum) so the caller fails loudly rather than trusting
/// garbage core enumeration.
pub fn parseMadt(madt_addr: u64, out: *Topology) bool {
    const hdr = phys(SdtHeader, madt_addr);
    // Validate the MADT itself before consuming it: signature "APIC", a length that
    // covers the fixed header + local_apic_address + flags (44), and a whole-table
    // checksum of 0. findMadt matched the signature via the root table, but the MADT
    // bytes it points at are what we actually parse, so verify them here too.
    if (!sigMatches(madt_addr, "APIC")) return false;
    if (hdr.length < 44) return false;
    if (checksum(madt_addr, hdr.length) != 0) return false;

    // MADT header(36) + local_apic_address(u32 @36) + flags(u32 @40), then entries.
    out.lapic_address = phys(u32, madt_addr + 36).*;
    const flags = phys(u32, madt_addr + 40).*;
    out.pic_compat = (flags & 1) != 0;

    var off: u64 = 44;
    const end: u64 = madt_addr + hdr.length;
    while (madt_addr + off + 2 <= end) {
        const etype = phys(u8, madt_addr + off).*;
        const elen = phys(u8, madt_addr + off + 1).*;
        if (elen < 2) break; // malformed; avoid an infinite loop
        // The entry body must fit within the table — a firmware-declared elen that
        // runs past hdr.length would read the fields below out of bounds.
        if (madt_addr + off + elen > end) break;
        const e = madt_addr + off;

        // Per-type minimum length (mirroring Linux's BAD_MADT_ENTRY): a known-type
        // entry declaring fewer bytes than its fixed layout would have its fields
        // read from beyond the declared entry — and beyond the whole table when it
        // is the last one. Such an entry is firmware corruption: fail the parse
        // loudly rather than consume garbage topology. Types we skip need only
        // {type, length}.
        const min_len: u8 = switch (etype) {
            MADT_LAPIC => 8,
            MADT_IOAPIC => 12,
            MADT_IRQ_OVERRIDE => 10,
            MADT_LAPIC_ADDR_OVERRIDE => 12,
            MADT_X2APIC => 16,
            else => 2,
        };
        if (elen < min_len) return false;

        switch (etype) {
            MADT_LAPIC => {
                // {acpi_uid u8 @2, apic_id u8 @3, flags u32 @4}
                const uid = phys(u8, e + 2).*;
                const apic_id = phys(u8, e + 3).*;
                const lflags = phys(u32, e + 4).*;
                addCpu(out, uid, apic_id, lflags, false);
            },
            MADT_X2APIC => {
                // {reserved u16 @2, x2apic_id u32 @4, flags u32 @8, acpi_uid u32 @12}
                const x2id = phys(u32, e + 4).*;
                const lflags = phys(u32, e + 8).*;
                const uid = phys(u32, e + 12).*;
                addCpu(out, uid, x2id, lflags, true);
            },
            MADT_IOAPIC => {
                // {ioapic_id u8 @2, reserved u8 @3, address u32 @4, gsi_base u32 @8}
                if (out.ioapic_count < MAX_IOAPICS) {
                    out.ioapics[out.ioapic_count] = .{
                        .id = phys(u8, e + 2).*,
                        .address = phys(u32, e + 4).*,
                        .gsi_base = phys(u32, e + 8).*,
                    };
                    out.ioapic_count += 1;
                }
            },
            MADT_IRQ_OVERRIDE => {
                // {bus u8 @2, source_irq u8 @3, gsi u32 @4, flags u16 @8}.
                // Flags encode polarity (bits 1:0) and trigger (bits 3:2):
                // 0b00 = conforms to ISA (high/edge), 0b01 = high/edge,
                // 0b11 = low/level.
                const oflags = phys(u16, e + 8).*;
                if (out.irq_override_count < MAX_IRQ_OVERRIDES) {
                    out.irq_overrides[out.irq_override_count] = .{
                        .source_irq = phys(u8, e + 3).*,
                        .gsi = phys(u32, e + 4).*,
                        .active_low = (oflags & 0b11) == 0b11,
                        .level_triggered = ((oflags >> 2) & 0b11) == 0b11,
                    };
                    out.irq_override_count += 1;
                }
            },
            MADT_LAPIC_ADDR_OVERRIDE => {
                // {reserved u16 @2, address u64 @4} — overrides the 32-bit base.
                // A base above 4 GiB cannot be stored (and no real part maps the
                // LAPIC there); refuse it loudly rather than truncate silently.
                const a64 = phys(u64, e + 4).*;
                if (a64 > 0xFFFF_FFFF) {
                    ilog.puts("acpi: MADT LAPIC override above 4 GiB ignored\n");
                } else {
                    out.lapic_address = @intCast(a64);
                }
            },
            else => {},
        }
        off += elen;
    }
    return true;
}

/// Record a CPU, deduplicating by APIC id (a core can appear as both a type-0
/// Local APIC and a type-9 x2APIC entry). `from_x2apic` distinguishes the entry
/// type: a type-0 Local APIC with `apic_id == 0xFF` is the "see the matching
/// x2APIC entry" sentinel and is always skipped; a type-9 x2APIC id of 0x000000FF
/// is a *legitimate* 255 and must be kept. The distinction must come from the
/// entry type, not from position in the table, which MADT does not constrain.
fn addCpu(out: *Topology, uid: u32, apic_id: u32, flags: u32, from_x2apic: bool) void {
    if (!from_x2apic and apic_id == 0xFF) return; // type-0 "defer to x2APIC" sentinel
    for (out.cpus[0..out.cpu_count]) |c| {
        if (c.apic_id == apic_id) return; // already recorded (dedupe)
    }
    if (out.cpu_count >= MAX_CPUS) return;
    // Usable if Enabled (bit0) OR Online-Capable (bit1).
    const usable = (flags & 0b11) != 0;
    out.cpus[out.cpu_count] = .{ .acpi_uid = uid, .apic_id = apic_id, .usable = usable };
    out.cpu_count += 1;
}

// --- public API ------------------------------------------------------------

/// Discover the CPU/IO-APIC topology from ACPI. Returns null if ACPI tables are
/// absent or malformed — the caller (SMP root) then runs single-core (BSP only).
pub fn discover() ?Topology {
    var topo: Topology = .{
        .cpus = undefined,
        .cpu_count = 0,
        .ioapics = undefined,
        .ioapic_count = 0,
        .irq_overrides = undefined,
        .irq_override_count = 0,
        .lapic_address = LAPIC_DEFAULT_BASE, // architectural default until the MADT says otherwise
        .pic_compat = true,
    };

    const rsdp = findRsdp() orelse {
        ilog.puts("acpi: no RSDP found\n");
        return null;
    };
    const madt = findMadt(rsdp) orelse {
        ilog.puts("acpi: no MADT (APIC table) found\n");
        return null;
    };
    if (!parseMadt(madt, &topo)) return null;

    var msg: [96]u8 = undefined;
    ilog.puts(fmtLine(&msg, "acpi: {d} CPUs ({d} usable), {d} IO-APIC(s), LAPIC @", .{
        topo.cpu_count, topo.usableCount(), topo.ioapic_count,
    }));
    ilog.putHex(topo.lapic_address);
    ilog.puts("\n");
    return topo;
}

// Small local wrapper so the import of std.fmt stays in one place.
const std = @import("std");
/// bufPrint that returns a fixed error string instead of propagating, so the one
/// diagnostic log line in discover() needs no error handling at the call site.
fn fmtLine(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch "acpi: (fmt error)";
}
