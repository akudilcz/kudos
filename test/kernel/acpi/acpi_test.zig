//! Host tests of src/kernel/acpi/acpi.zig.

const std = @import("std");
const acpi = @import("acpi");
const MADT_LAPIC = acpi.MADT_LAPIC;
const MADT_IOAPIC = acpi.MADT_IOAPIC;
const MADT_LAPIC_ADDR_OVERRIDE = acpi.MADT_LAPIC_ADDR_OVERRIDE;
const MADT_X2APIC = acpi.MADT_X2APIC;
const MAX_CPUS = acpi.MAX_CPUS;
const MAX_IOAPICS = acpi.MAX_IOAPICS;
const RSDP_SIG = acpi.RSDP_SIG;
const findMadt = acpi.findMadt;
const parseMadt = acpi.parseMadt;
const scanForRsdp = acpi.scanForRsdp;
const testing = std.testing;

// The parser is pure over phys(u64), so these tests build byte-exact ACPI
// tables in host memory and hand their addresses in.

/// Stamp a 36-byte SDT header over buf[0..36] — signature, length — then set
/// the checksum byte (offset 9) so the whole `len` bytes sum to 0. Everything
/// after the header must already be in place.
fn testStampSdt(buf: []u8, sig: *const [4]u8, len: u32) void {
    @memcpy(buf[0..4], sig);
    std.mem.writeInt(u32, buf[4..8], len, .little);
    buf[9] = 0;
    var sum: u8 = 0;
    for (buf[0..len]) |b| sum +%= b;
    buf[9] = 0 -% sum;
}

/// A synthetic MADT built entry by entry, then finalized with the fixed
/// prologue (local_apic_address @36, flags @40) and a valid checksum.
const TestMadt = struct {
    buf: [1024]u8,
    len: usize,

    fn init() TestMadt {
        return .{ .buf = [_]u8{0} ** 1024, .len = 44 };
    }

    /// Append a raw {type, length, body…} entry (length = body.len + 2).
    fn entry(self: *TestMadt, etype: u8, body: []const u8) void {
        self.buf[self.len] = etype;
        self.buf[self.len + 1] = @intCast(body.len + 2);
        @memcpy(self.buf[self.len + 2 ..][0..body.len], body);
        self.len += body.len + 2;
    }

    /// Type-0 Processor Local APIC: {uid u8, apic_id u8, flags u32}.
    fn addLapic(self: *TestMadt, uid: u8, apic_id: u8, flags: u32) void {
        var b: [6]u8 = undefined;
        b[0] = uid;
        b[1] = apic_id;
        std.mem.writeInt(u32, b[2..6], flags, .little);
        self.entry(MADT_LAPIC, &b);
    }

    /// Type-9 Processor Local x2APIC: {reserved u16, x2apic_id u32, flags u32, uid u32}.
    fn addX2Apic(self: *TestMadt, uid: u32, x2apic_id: u32, flags: u32) void {
        var b: [14]u8 = [_]u8{0} ** 14;
        std.mem.writeInt(u32, b[2..6], x2apic_id, .little);
        std.mem.writeInt(u32, b[6..10], flags, .little);
        std.mem.writeInt(u32, b[10..14], uid, .little);
        self.entry(MADT_X2APIC, &b);
    }

    /// Type-1 I/O APIC: {id u8, reserved u8, address u32, gsi_base u32}.
    fn addIoApic(self: *TestMadt, id: u8, address: u32, gsi_base: u32) void {
        var b: [10]u8 = [_]u8{0} ** 10;
        b[0] = id;
        std.mem.writeInt(u32, b[2..6], address, .little);
        std.mem.writeInt(u32, b[6..10], gsi_base, .little);
        self.entry(MADT_IOAPIC, &b);
    }

    /// Type-2 Interrupt Source Override: {bus u8, source u8, gsi u32, flags u16}.
    fn addIrqOverride(self: *TestMadt, source_irq: u8, gsi: u32, flags: u16) void {
        var b: [8]u8 = [_]u8{0} ** 8;
        b[1] = source_irq;
        std.mem.writeInt(u32, b[2..6], gsi, .little);
        std.mem.writeInt(u16, b[6..8], flags, .little);
        self.entry(acpi.MADT_IRQ_OVERRIDE, &b);
    }

    /// Type-5 Local APIC Address Override: {reserved u16, address u64}.
    fn addLapicOverride(self: *TestMadt, address: u64) void {
        var b: [10]u8 = [_]u8{0} ** 10;
        std.mem.writeInt(u64, b[2..10], address, .little);
        self.entry(MADT_LAPIC_ADDR_OVERRIDE, &b);
    }

    /// Stamp the prologue + header/checksum; returns the table's "physical"
    /// (== host virtual) address for parseMadt/findMadt.
    fn finalize(self: *TestMadt, lapic_address: u32, madt_flags: u32) u64 {
        std.mem.writeInt(u32, self.buf[36..40], lapic_address, .little);
        std.mem.writeInt(u32, self.buf[40..44], madt_flags, .little);
        testStampSdt(&self.buf, "APIC", @intCast(self.len));
        return @intFromPtr(&self.buf);
    }
};

/// A zeroed Topology with the same pre-parse state discover() sets up
/// (parseMadt overwrites lapic_address/pic_compat from the table prologue).
fn testTopo() acpi.Topology {
    return .{
        .cpus = undefined,
        .cpu_count = 0,
        .ioapics = undefined,
        .ioapic_count = 0,
        .irq_overrides = undefined,
        .irq_override_count = 0,
        .lapic_address = 0,
        .pic_compat = false,
    };
}

test "parseMadt: mixed LAPIC + x2APIC entries, dedupe, prologue fields" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 1); // BSP, Enabled
    m.addLapic(1, 2, 1); // AP, Enabled
    m.addX2Apic(1, 2, 1); // same core again as x2APIC → deduped by apic id
    m.addX2Apic(7, 300, 1); // id > 255: only representable as x2APIC
    m.addIoApic(4, 0xFEC0_0000, 0);
    const addr = m.finalize(0xFEE0_0000, 1);

    var topo = testTopo();
    try testing.expect(parseMadt(addr, &topo));
    try testing.expectEqual(@as(usize, 3), topo.cpu_count);
    try testing.expectEqual(@as(u32, 0), topo.cpus[0].apic_id);
    try testing.expectEqual(@as(u32, 2), topo.cpus[1].apic_id);
    try testing.expectEqual(@as(u32, 300), topo.cpus[2].apic_id);
    try testing.expectEqual(@as(u32, 7), topo.cpus[2].acpi_uid);
    try testing.expectEqual(@as(usize, 3), topo.usableCount());
    try testing.expectEqual(@as(usize, 1), topo.ioapic_count);
    try testing.expectEqual(@as(u8, 4), topo.ioapics[0].id);
    try testing.expectEqual(@as(u32, 0xFEC0_0000), topo.ioapics[0].address);
    try testing.expectEqual(@as(u32, 0xFEE0_0000), topo.lapic_address);
    try testing.expect(topo.pic_compat);
}

test "parseMadt: disabled cores are recorded but unusable unless Online-Capable" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 0b01); // Enabled → usable
    m.addLapic(1, 1, 0b00); // neither → NOT usable (must be ignored for bring-up)
    m.addLapic(2, 2, 0b10); // Online-Capable only → usable (ACPI 6.3+, §5.2.12.2)
    const addr = m.finalize(0xFEE0_0000, 0);

    var topo = testTopo();
    try testing.expect(parseMadt(addr, &topo));
    try testing.expectEqual(@as(usize, 3), topo.cpu_count);
    try testing.expect(topo.cpus[0].usable);
    try testing.expect(!topo.cpus[1].usable);
    try testing.expect(topo.cpus[2].usable);
    try testing.expectEqual(@as(usize, 2), topo.usableCount());
    try testing.expect(!topo.pic_compat);
}

test "parseMadt: type-5 LAPIC address override wins over the 32-bit prologue" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 1);
    m.addLapicOverride(0x0000_0000_FEC1_2000);
    const addr = m.finalize(0xFEE0_0000, 0);

    var topo = testTopo();
    try testing.expect(parseMadt(addr, &topo));
    try testing.expectEqual(@as(u32, 0xFEC1_2000), topo.lapic_address);
}

test "parseMadt: bad checksum or bad signature rejected" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 1);
    const addr = m.finalize(0xFEE0_0000, 0);

    var topo = testTopo();
    m.buf[20] +%= 1; // corrupt one OEM byte → whole-table sum no longer 0
    try testing.expect(!parseMadt(addr, &topo));
    m.buf[20] -%= 1;
    try testing.expect(parseMadt(addr, &topo)); // restored: valid again
    m.buf[0] = 'X'; // signature no longer "APIC"
    try testing.expect(!parseMadt(addr, &topo));
}

test "parseMadt: truncated table (entry runs past header.length) ends cleanly" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 1);
    m.addLapic(1, 1, 1);
    const addr = m.finalize(0xFEE0_0000, 0);
    // Shorten the declared length so the second entry's body crosses the end;
    // restamp so only the truncation (not the checksum) is under test.
    testStampSdt(&m.buf, "APIC", @intCast(m.len - 4));

    var topo = testTopo();
    try testing.expect(parseMadt(addr, &topo));
    try testing.expectEqual(@as(usize, 1), topo.cpu_count); // first entry kept
}

test "parseMadt: entry length 0 terminates the walk instead of spinning" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 1);
    const zero_off = m.len;
    m.addLapic(1, 1, 1); // becomes unreachable once the len=0 entry precedes it
    m.buf[zero_off + 1] = 0; // corrupt: elen = 0
    const addr = m.finalize(0xFEE0_0000, 0);

    var topo = testTopo();
    try testing.expect(parseMadt(addr, &topo)); // returns (bounded), keeps prior entries
    try testing.expectEqual(@as(usize, 1), topo.cpu_count);
}

test "parseMadt: known-type entry shorter than its fixed layout fails the parse" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 1);
    // A type-9 x2APIC entry declaring only 8 of its 16 bytes (BAD_MADT_ENTRY).
    var b: [6]u8 = [_]u8{0} ** 6;
    m.entry(MADT_X2APIC, &b);
    const addr = m.finalize(0xFEE0_0000, 0);

    var topo = testTopo();
    try testing.expect(!parseMadt(addr, &topo));
}

test "parseMadt: more CPUs than MAX_CPUS caps at MAX_CPUS" {
    var m = TestMadt.init();
    var i: u8 = 0;
    while (i < MAX_CPUS + 4) : (i += 1) {
        m.addLapic(i, i, 1);
    }
    const addr = m.finalize(0xFEE0_0000, 0);

    var topo = testTopo();
    // Documented contract: addCpu drops cores beyond MAX_CPUS silently (fixed
    // .bss storage); the parse itself still succeeds.
    try testing.expect(parseMadt(addr, &topo));
    try testing.expectEqual(@as(usize, MAX_CPUS), topo.cpu_count);
    try testing.expectEqual(@as(usize, MAX_CPUS), topo.usableCount());
}

test "parseMadt: type-0 apic_id 0xFF is the x2APIC sentinel; x2APIC id 255 is real" {
    var m = TestMadt.init();
    m.addLapic(0, 0xFF, 1); // sentinel: "see the matching x2APIC entry" → skipped
    m.addX2Apic(9, 0xFF, 1); // a legitimate x2APIC id 255 → kept
    const addr = m.finalize(0xFEE0_0000, 0);

    var topo = testTopo();
    try testing.expect(parseMadt(addr, &topo));
    try testing.expectEqual(@as(usize, 1), topo.cpu_count);
    try testing.expectEqual(@as(u32, 0xFF), topo.cpus[0].apic_id);
    try testing.expectEqual(@as(u32, 9), topo.cpus[0].acpi_uid);
}

test "parseMadt: I/O APICs beyond MAX_IOAPICS are dropped, parse still succeeds" {
    var m = TestMadt.init();
    var i: u8 = 0;
    while (i < MAX_IOAPICS + 2) : (i += 1) {
        m.addIoApic(i, 0xFEC0_0000 + @as(u32, i) * 0x1000, @as(u32, i) * 24);
    }
    const addr = m.finalize(0xFEE0_0000, 0);

    var topo = testTopo();
    try testing.expect(parseMadt(addr, &topo));
    try testing.expectEqual(@as(usize, MAX_IOAPICS), topo.ioapic_count);
}

test "findMadt: XSDT walk finds the APIC table; malformed roots are rejected" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 1);
    const madt_addr = m.finalize(0xFEE0_0000, 0);

    // XSDT: 36-byte header + one u64 entry pointing at the MADT.
    var xsdt: [44]u8 = [_]u8{0} ** 44;
    std.mem.writeInt(u64, xsdt[36..44], madt_addr, .little);
    testStampSdt(&xsdt, "XSDT", 44);

    // ACPI 2.0 RSDP referencing the XSDT: 20-byte checksum + 36-byte extended.
    var rsdp: [36]u8 = [_]u8{0} ** 36;
    @memcpy(rsdp[0..8], RSDP_SIG);
    rsdp[15] = 2; // revision
    std.mem.writeInt(u32, rsdp[20..24], 36, .little); // length
    std.mem.writeInt(u64, rsdp[24..32], @intFromPtr(&xsdt), .little);
    var sum20: u8 = 0;
    for (rsdp[0..20]) |b| sum20 +%= b;
    rsdp[8] = 0 -% sum20;
    var sum36: u8 = 0;
    for (rsdp[0..36]) |b| sum36 +%= b;
    rsdp[32] = 0 -% sum36;

    try testing.expectEqual(@as(?u64, madt_addr), findMadt(@intFromPtr(&rsdp)));

    // Corrupt the XSDT checksum: the root is rejected → no MADT.
    xsdt[35] +%= 1;
    try testing.expectEqual(@as(?u64, null), findMadt(@intFromPtr(&rsdp)));
    xsdt[35] -%= 1;

    // Root length below the 36-byte header: rejected (would underflow the count).
    std.mem.writeInt(u32, xsdt[4..8], 35, .little);
    try testing.expectEqual(@as(?u64, null), findMadt(@intFromPtr(&rsdp)));
    testStampSdt(&xsdt, "XSDT", 44); // restore

    // Root signature not "XSDT": rejected.
    xsdt[0] = 'Y';
    try testing.expectEqual(@as(?u64, null), findMadt(@intFromPtr(&rsdp)));
}

test "scanForRsdp: finds a checksummed RSDP on a 16-byte boundary, rejects corruption" {
    // The scan probes 16-byte boundaries, so the arena is 16-aligned and the
    // RSDP is planted one paragraph in.
    var area: [64]u8 align(16) = [_]u8{0} ** 64;
    const rsdp = area[16..36];
    @memcpy(rsdp[0..8], RSDP_SIG);
    rsdp[15] = 0; // ACPI 1.0: only the 20-byte checksum applies
    var sum: u8 = 0;
    for (rsdp[0..20]) |b| sum +%= b;
    rsdp[8] = 0 -% sum;

    const base = @intFromPtr(&area);
    try testing.expectEqual(@as(?u64, base + 16), scanForRsdp(base, base + area.len));

    // Corrupt the checksum: the candidate is skipped → not found.
    rsdp[10] +%= 1;
    try testing.expectEqual(@as(?u64, null), scanForRsdp(base, base + area.len));
}

test "parseMadt: interrupt source overrides carry GSI, polarity and trigger" {
    var m = TestMadt.init();
    m.addLapic(0, 0, 1);
    m.addIoApic(1, 0xFEC0_0000, 0);
    // The classic PC wiring: ISA IRQ0 (the PIT) arrives on GSI 2 with
    // conforms-to-ISA flags (0), and ACPI's SCI (IRQ9) is level/low (0b1111).
    m.addIrqOverride(0, 2, 0);
    m.addIrqOverride(9, 9, 0b1111);
    var topo = testTopo();
    try testing.expect(acpi.parseMadt(m.finalize(0xFEE0_0000, 1), &topo));

    try testing.expectEqual(@as(usize, 2), topo.irq_override_count);
    try testing.expectEqual(@as(u8, 0), topo.irq_overrides[0].source_irq);
    try testing.expectEqual(@as(u32, 2), topo.irq_overrides[0].gsi);
    try testing.expect(!topo.irq_overrides[0].active_low); // conforms = ISA high
    try testing.expect(!topo.irq_overrides[0].level_triggered); // conforms = edge
    try testing.expectEqual(@as(u32, 9), topo.irq_overrides[1].gsi);
    try testing.expect(topo.irq_overrides[1].active_low);
    try testing.expect(topo.irq_overrides[1].level_triggered);
}
