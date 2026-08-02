//! Host tests of src/kernel/virt/exitinfo.zig — exit-qualification decoders.

const std = @import("std");
const exitinfo = @import("exitinfo");
const expectEqual = std.testing.expectEqual;

test "I/O exit: OUT byte to port 0x3F8 (serial THR)" {
    // size=0 (1 byte), dir=0 (OUT), not string, DX operand, port 0x3F8.
    const qual: u64 = (@as(u64, 0x3F8) << 16) | 0b000_000;
    const io = exitinfo.IoInfo.decode(qual);
    try expectEqual(@as(u8, 1), io.size);
    try expectEqual(false, io.is_in);
    try expectEqual(false, io.is_string);
    try expectEqual(@as(u16, 0x3F8), io.port);
}

test "I/O exit: IN dword from port 0xCF8, immediate operand" {
    // size=3 (4 bytes), dir=1 (IN), immediate operand bit set, port 0xCF8.
    const qual: u64 = (@as(u64, 0xCF8) << 16) | (1 << 6) | (1 << 3) | 0b011;
    const io = exitinfo.IoInfo.decode(qual);
    try expectEqual(@as(u8, 4), io.size);
    try expectEqual(true, io.is_in);
    try expectEqual(true, io.is_immediate);
    try expectEqual(@as(u16, 0xCF8), io.port);
}

test "EPT violation: guest write to an unmapped, currently-RWX-absent page" {
    // write access (bit1), no current EPT permissions, linear address valid.
    const qual: u64 = (1 << 1) | (1 << 7);
    const v = exitinfo.EptViolation.decode(qual);
    try expectEqual(false, v.read);
    try expectEqual(true, v.write);
    try expectEqual(false, v.fetch);
    try expectEqual(false, v.ept_readable);
    try expectEqual(true, v.linear_valid);
}

test "EPT violation: instruction fetch from executable page" {
    const qual: u64 = (1 << 2) | (1 << 3) | (1 << 5); // fetch, ept readable+executable
    const v = exitinfo.EptViolation.decode(qual);
    try expectEqual(true, v.fetch);
    try expectEqual(true, v.ept_executable);
}

test "CR access: MOV to CR3 from R8" {
    // cr=3, kind=0 (mov to cr), gp register 8.
    const qual: u64 = (@as(u64, 8) << 8) | (0 << 4) | 3;
    const cr = exitinfo.CrAccess.decode(qual);
    try expectEqual(@as(u4, 3), cr.cr);
    try expectEqual(exitinfo.CrAccess.Kind.mov_to_cr, cr.kind);
    try expectEqual(@as(u4, 8), cr.gp_register);
}

test "basic exit reason strips the entry-failure flag (VIRT-007: exits decode as pure values, no allocation)" {
    const raw: u64 = 0x8000_0021; // entry failure + reason 33
    try expectEqual(@as(u16, 33), exitinfo.basicExitReason(raw));
    try expectEqual(true, exitinfo.isEntryFailure(raw));
    try expectEqual(false, exitinfo.isEntryFailure(0x21));
}
