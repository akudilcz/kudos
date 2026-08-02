//! Host tests of src/kernel/virt/insn.zig — the MOV-subset decoder for MMIO
//! exits. Each accepted pattern is captioned with the accessor it compiles
//! from; the reject cases pin the subset's edges (prefixes outside the set,
//! register-direct operands, AH-family byte registers, truncated fetches).

const std = @import("std");
const insn = @import("insn");
const expectEqual = std.testing.expectEqual;

fn expectLoad(bytes: []const u8, reg: u4, size: u8, ext: insn.Ext, len: u8) !void {
    const d = insn.decode(bytes) orelse return error.TestExpectedDecode;
    try expectEqual(len, d.len);
    switch (d.op) {
        .load => |l| {
            try expectEqual(reg, l.reg);
            try expectEqual(size, l.size);
            try expectEqual(ext, l.ext);
        },
        else => return error.TestExpectedLoad,
    }
}

fn expectStoreReg(bytes: []const u8, reg: u4, size: u8, len: u8) !void {
    const d = insn.decode(bytes) orelse return error.TestExpectedDecode;
    try expectEqual(len, d.len);
    switch (d.op) {
        .store => |s| {
            try expectEqual(size, s.size);
            try expectEqual(reg, s.src.reg);
        },
        else => return error.TestExpectedStore,
    }
}

fn expectStoreImm(bytes: []const u8, imm: u64, size: u8, len: u8) !void {
    const d = insn.decode(bytes) orelse return error.TestExpectedDecode;
    try expectEqual(len, d.len);
    switch (d.op) {
        .store => |s| {
            try expectEqual(size, s.size);
            try expectEqual(imm, s.src.imm);
        },
        else => return error.TestExpectedStore,
    }
}

fn expectReject(bytes: []const u8) !void {
    try expectEqual(@as(?insn.Decoded, null), insn.decode(bytes));
}

test "loads: the readb/w/l/q shapes" {
    // readl: mov (%rax),%edx
    try expectLoad(&.{ 0x8B, 0x10 }, 2, 4, .zero, 2);
    // readq: mov (%rax),%rdx
    try expectLoad(&.{ 0x48, 0x8B, 0x10 }, 2, 8, .zero, 3);
    // readw as movzwl (%rcx),%eax
    try expectLoad(&.{ 0x0F, 0xB7, 0x01 }, 0, 2, .zero, 3);
    // readb as movzbl 0x8(%rax),%edx
    try expectLoad(&.{ 0x0F, 0xB6, 0x50, 0x08 }, 2, 1, .zero, 4);
    // mov (%rbx),%al — byte load merges into RAX's low byte
    try expectLoad(&.{ 0x8A, 0x03 }, 0, 1, .none, 2);
    // mov (%rax),%cx — 16-bit load merges into RCX's low word
    try expectLoad(&.{ 0x66, 0x8B, 0x08 }, 1, 2, .none, 3);
    // mov (%rax),%r9d — REX.R extends the destination
    try expectLoad(&.{ 0x44, 0x8B, 0x08 }, 9, 4, .zero, 3);
}

test "stores: the writeb/w/l/q shapes" {
    // writel: mov %esi,(%rax)
    try expectStoreReg(&.{ 0x89, 0x30 }, 6, 4, 2);
    // writeq: mov %rbp,(%rax)
    try expectStoreReg(&.{ 0x48, 0x89, 0x28 }, 5, 8, 3);
    // writeb on a REX register: mov %r9b,(%rdi)
    try expectStoreReg(&.{ 0x44, 0x88, 0x0F }, 9, 1, 3);
    // writew on a REX register: mov %r8w,(%rax)
    try expectStoreReg(&.{ 0x66, 0x44, 0x89, 0x00 }, 8, 2, 4);
}

test "addressing forms contribute length only" {
    // mov (%rax,%rbx,4),%ecx — SIB byte
    try expectLoad(&.{ 0x8B, 0x0C, 0x98 }, 1, 4, .zero, 3);
    // mov 0x1234(,%rbx,4),%ecx — SIB with no base: disp32 follows
    try expectLoad(&.{ 0x8B, 0x0C, 0x9D, 0x34, 0x12, 0x00, 0x00 }, 1, 4, .zero, 7);
    // mov 0x10(%rip),%eax — RIP-relative disp32
    try expectLoad(&.{ 0x8B, 0x05, 0x10, 0x00, 0x00, 0x00 }, 0, 4, .zero, 6);
    // mov %edx,0x100(%rax) — disp32
    try expectStoreReg(&.{ 0x89, 0x90, 0x00, 0x01, 0x00, 0x00 }, 2, 4, 6);
    // Trailing bytes past the instruction are ignored; len is the true length.
    try expectLoad(&.{ 0x8B, 0x10, 0xCC, 0xCC, 0xCC }, 2, 4, .zero, 2);
}

test "immediate stores, including REX.W sign-extension" {
    // movb $0x5,(%rax)
    try expectStoreImm(&.{ 0xC6, 0x00, 0x05 }, 0x5, 1, 3);
    // movl $0x12345678,(%rax)
    try expectStoreImm(&.{ 0xC7, 0x00, 0x78, 0x56, 0x34, 0x12 }, 0x1234_5678, 4, 6);
    // movw $0x1234,(%rax)
    try expectStoreImm(&.{ 0x66, 0xC7, 0x00, 0x34, 0x12 }, 0x1234, 2, 5);
    // movq $-1,(%rax) — imm32 sign-extends to the 64-bit operand
    try expectStoreImm(&.{ 0x48, 0xC7, 0x00, 0xFF, 0xFF, 0xFF, 0xFF }, 0xFFFF_FFFF_FFFF_FFFF, 8, 7);
}

test "rejects: prefixes outside the subset" {
    try expectReject(&.{ 0xF3, 0x8B, 0x10 }); // REP
    try expectReject(&.{ 0xF0, 0x89, 0x10 }); // LOCK
    try expectReject(&.{ 0x64, 0x8B, 0x10 }); // FS segment
    try expectReject(&.{ 0x67, 0x8B, 0x10 }); // address-size override
}

test "rejects: operands the subset refuses" {
    try expectReject(&.{ 0x8B, 0xC1 }); // mov %ecx,%eax — register-direct, no memory
    try expectReject(&.{ 0x88, 0x20 }); // mov %ah,(%rax) — AH without REX
    try expectReject(&.{ 0x8A, 0x28 }); // mov (%rax),%ch — CH without REX
    try expectReject(&.{ 0xC7, 0x08, 0x01, 0x00, 0x00, 0x00 }); // C7 /1 is not MOV
    try expectReject(&.{ 0x01, 0x10 }); // add — outside the subset
}

test "rejects: truncated fetches at every stage" {
    try expectReject(&.{});
    try expectReject(&.{0x8B}); // opcode, no ModRM
    try expectReject(&.{0x0F}); // half a two-byte opcode
    try expectReject(&.{ 0x8B, 0x05, 0x10, 0x00 }); // disp32 cut short
    try expectReject(&.{ 0xC7, 0x00, 0x78, 0x56 }); // imm32 cut short
}
