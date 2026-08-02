//! Host tests of src/kernel/virt/vmcheck.zig.
//!
//! A known-good 64-bit flat guest shadow must pass with zero violations; then each
//! check is proven by reintroducing exactly the defect it guards against and
//! confirming that named violation appears. This is the mutation discipline
//! CLAUDE.md requires — a validity check that never fires is a comment.

const std = @import("std");
const vmcheck = @import("vmcheck");
const vmcs = vmcheck.vmcs;
const expectEqual = std.testing.expectEqual;

/// A minimal but VM-entry-legal 64-bit flat guest, mirroring what vcpu.zig writes
/// for the stub guest: paging on, long mode active, flat CS, a busy 64-bit TSS.
fn goodShadow() vmcheck.GuestShadow {
    return .{
        .cr0 = 0x8000_0021, // PE | NE | PG
        .cr3 = 0x9000,
        .cr4 = 0x20, // PAE
        .efer = 0x500, // LME | LMA
        .rflags = 0x2, // reserved bit 1 set, nothing else
        .rip = 0x10_0200,
        .rsp = 0x8_0000,
        .cs_selector = 0x08,
        .cs_base = 0,
        .cs_limit = 0xFFFFF,
        .cs_ar = 0xA09B, // present, code, S=1, L=1, D=0, G=1
        .tr_selector = 0x18,
        .tr_base = 0x6000,
        .tr_limit = 0x67,
        .tr_ar = 0x8B, // present, system, type 11 (64-bit busy TSS)
        .gdtr_base = 0x6000,
        .gdtr_limit = 0x1F,
        .idtr_base = 0,
        .idtr_limit = 0,
        .entry_controls = vmcs.ENTRY_IA32E_MODE_GUEST,
    };
}

fn hasViolation(s: *const vmcheck.GuestShadow, name: []const u8) bool {
    var buf: [16]vmcheck.Violation = undefined;
    const n = vmcheck.checkGuestState(s, &buf);
    for (buf[0..@min(n, buf.len)]) |v| {
        if (std.mem.eql(u8, v.check, name)) return true;
    }
    return false;
}

test "the known-good shadow passes with zero violations" {
    var buf: [16]vmcheck.Violation = undefined;
    try expectEqual(@as(usize, 0), vmcheck.checkGuestState(&goodShadow(), &buf));
}

test "CR0.PG without CR0.PE is caught" {
    var s = goodShadow();
    s.cr0 &= ~@as(u64, 1 << 0); // clear PE, keep PG
    try std.testing.expect(hasViolation(&s, "CR0.PG set without CR0.PE"));
}

test "IA-32e guest without CR4.PAE is caught" {
    var s = goodShadow();
    s.cr4 &= ~@as(u64, 1 << 5);
    try std.testing.expect(hasViolation(&s, "IA-32e guest without CR4.PAE"));
}

test "EFER.LMA disagreeing with the entry control is caught" {
    var s = goodShadow();
    s.entry_controls = 0; // no IA-32e, but EFER.LMA still set
    try std.testing.expect(hasViolation(&s, "EFER.LMA disagrees with IA-32e entry control"));
}

test "RFLAGS with bit 1 clear is caught" {
    var s = goodShadow();
    s.rflags = 0;
    try std.testing.expect(hasViolation(&s, "RFLAGS bit 1 not set"));
}

test "RFLAGS with a reserved bit set is caught" {
    var s = goodShadow();
    s.rflags |= 1 << 3; // reserved-zero bit
    try std.testing.expect(hasViolation(&s, "RFLAGS reserved bit set"));
}

test "a 64-bit guest with CS.L clear is caught" {
    var s = goodShadow();
    s.cs_ar &= ~@as(u32, 1 << 13); // clear L
    try std.testing.expect(hasViolation(&s, "64-bit guest with CS.L clear"));
}

test "CS.L and CS.D both set is caught" {
    var s = goodShadow();
    s.cs_ar |= 1 << 14; // set D while L is set
    try std.testing.expect(hasViolation(&s, "CS.L and CS.D both set"));
}

test "TR that is not a 64-bit busy TSS is caught" {
    var s = goodShadow();
    s.tr_ar = (s.tr_ar & ~@as(u32, 0xF)) | 3; // type 3 instead of 11
    try std.testing.expect(hasViolation(&s, "TR type is not 64-bit busy TSS (11)"));
}

test "a non-canonical TR base is caught" {
    var s = goodShadow();
    s.tr_base = 0x0000_8000_0000_0000; // bit 47 clear, bit 48 set → non-canonical
    try std.testing.expect(hasViolation(&s, "TR base not canonical"));
}

test "a non-canonical RIP is caught" {
    var s = goodShadow();
    s.rip = 0x0000_8000_0000_0000;
    try std.testing.expect(hasViolation(&s, "RIP not canonical"));
}

test "IA-32e guest without CR0.PG is caught" {
    var s = goodShadow();
    s.cr0 &= ~@as(u64, 1 << 31); // clear PG while the entry control still says IA-32e
    try std.testing.expect(hasViolation(&s, "IA-32e guest without CR0.PG"));
}

test "IA-32e guest without EFER.LMA is caught" {
    var s = goodShadow();
    s.efer &= ~@as(u64, 1 << 10); // clear LMA
    try std.testing.expect(hasViolation(&s, "IA-32e guest without EFER.LMA"));
}

test "EFER.LME disagreeing with EFER.LMA under paging is caught" {
    var s = goodShadow();
    s.efer &= ~@as(u64, 1 << 8); // clear LME, keep LMA and PG
    try std.testing.expect(hasViolation(&s, "EFER.LME disagrees with EFER.LMA under paging"));
}

test "RFLAGS.VM set in IA-32e mode is caught" {
    var s = goodShadow();
    s.rflags |= 1 << 17; // VM
    try std.testing.expect(hasViolation(&s, "RFLAGS.VM set in IA-32e mode"));
}

test "an unusable CS is caught" {
    var s = goodShadow();
    s.cs_ar |= 1 << 16; // unusable
    try std.testing.expect(hasViolation(&s, "CS marked unusable"));
}

test "a not-present CS is caught" {
    var s = goodShadow();
    s.cs_ar &= ~@as(u32, 1 << 7); // clear present
    try std.testing.expect(hasViolation(&s, "CS not present"));
}

test "a CS that is not a code/data descriptor is caught" {
    var s = goodShadow();
    s.cs_ar &= ~@as(u32, 1 << 4); // clear S
    try std.testing.expect(hasViolation(&s, "CS not a code/data descriptor"));
}

test "an unusable TR is caught" {
    var s = goodShadow();
    s.tr_ar |= 1 << 16; // unusable
    try std.testing.expect(hasViolation(&s, "TR marked unusable"));
}

test "a non-canonical GDTR base is caught" {
    var s = goodShadow();
    s.gdtr_base = 0x0000_8000_0000_0000;
    try std.testing.expect(hasViolation(&s, "GDTR base not canonical"));
}

test "a non-canonical IDTR base is caught" {
    var s = goodShadow();
    s.idtr_base = 0x0000_8000_0000_0000;
    try std.testing.expect(hasViolation(&s, "IDTR base not canonical"));
}

test "a GDTR limit above 0xFFFF is caught" {
    var s = goodShadow();
    s.gdtr_limit = 0x1_0000;
    try std.testing.expect(hasViolation(&s, "GDTR limit exceeds 0xFFFF"));
}
