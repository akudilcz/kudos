//! Decoder for the narrow x86-64 instruction subset a guest kernel uses to
//! touch memory-mapped IO: the MOV and MOVZX forms Linux's readb/w/l/q and
//! writeb/w/l/q accessors compile to, plus MOV-immediate stores (Intel SDM
//! Vol 2 "MOV", "MOVZX"). Pure and host-tested (test/kernel/virt/insn_test.zig).
//!
//! On an EPT violation the VMCS supplies the faulting guest-physical address
//! but not the operand size, direction, or register — those live only in the
//! instruction bytes at the guest RIP. The machine model fetches the bytes
//! (virt/guestwalk.zig), decodes them here, performs the device access, and
//! writes any load result back into the exiting vCPU's register file.
//!
//! Anything outside the subset decodes to null; the caller logs the raw bytes
//! and shuts the guest down rather than guess (spec VIRT-017). The ModRM, SIB,
//! and displacement bytes are parsed for instruction length only — the
//! effective address is authoritative from the exit, so the addressing
//! registers never need to be evaluated.

/// Longest legal x86 instruction; the fetch the caller hands `decode`.
pub const MAX_BYTES: usize = 15;

// Prefixes (SDM Vol 2 §2.1.1).
const PREFIX_OPSIZE: u8 = 0x66;
const REX_BASE: u8 = 0x40; // 0x40..0x4F: REX.W bit 3, REX.R bit 2, REX.B bit 0

// Opcodes (SDM Vol 2, one-byte map; 0F-prefixed for MOVZX).
const OP_MOV_MR8: u8 = 0x88; // MOV r/m8,  r8
const OP_MOV_MR: u8 = 0x89; //  MOV r/m16/32/64, r
const OP_MOV_RM8: u8 = 0x8A; // MOV r8,  r/m8
const OP_MOV_RM: u8 = 0x8B; //  MOV r, r/m16/32/64
const OP_TWO_BYTE: u8 = 0x0F;
const OP2_MOVZX_B: u8 = 0xB6; // MOVZX r, r/m8
const OP2_MOVZX_W: u8 = 0xB7; // MOVZX r, r/m16
const OP_MOV_MI8: u8 = 0xC6; // MOV r/m8, imm8 (/0)
const OP_MOV_MI: u8 = 0xC7; //  MOV r/m16/32/64, imm16/32 (/0)

/// How a load writes its destination register: `zero` replaces the whole
/// 64-bit register (32-bit MOV zero-extends, as does MOVZX); `none` merges
/// into the low bytes, preserving the rest (8- and 16-bit MOV).
pub const Ext = enum { none, zero };

pub const Src = union(enum) {
    reg: u4,
    imm: u64,
};

pub const Op = union(enum) {
    /// Device → register. `reg` is the destination in x86 encoding order
    /// (0=RAX … 15=R15); `size` is the access width in bytes.
    load: struct { reg: u4, size: u8, ext: Ext },
    /// Register or immediate → device.
    store: struct { size: u8, src: Src },
};

pub const Decoded = struct {
    op: Op,
    /// Total instruction length — cross-checked by the caller against the
    /// VMCS-reported exit instruction length.
    len: u8,
};

/// Decode one instruction from `bytes`, or null when it falls outside the
/// subset (unknown opcode, LOCK/REP/segment/address-size prefix, register
/// destination, an AH/CH/DH/BH byte-register encoding, or a truncated fetch).
pub fn decode(bytes: []const u8) ?Decoded {
    var i: usize = 0;

    var opsize = false;
    if (i < bytes.len and bytes[i] == PREFIX_OPSIZE) {
        opsize = true;
        i += 1;
    }

    var rex: u8 = 0;
    if (i < bytes.len and bytes[i] & 0xF0 == REX_BASE) {
        rex = bytes[i];
        i += 1;
    }

    if (i >= bytes.len) return null;
    const rex_w = rex & 0b1000 != 0;
    const wide_size: u8 = if (rex_w) 8 else if (opsize) 2 else 4;
    const wide_ext: Ext = if (rex_w) .zero else if (opsize) .none else .zero;

    const opcode = bytes[i];
    i += 1;
    switch (opcode) {
        OP_MOV_MR8 => {
            const m = modrm(bytes, &i, rex) orelse return null;
            if (!byteRegValid(m.reg, rex)) return null;
            return .{ .op = .{ .store = .{ .size = 1, .src = .{ .reg = m.reg } } }, .len = @intCast(i) };
        },
        OP_MOV_MR => {
            const m = modrm(bytes, &i, rex) orelse return null;
            return .{ .op = .{ .store = .{ .size = wide_size, .src = .{ .reg = m.reg } } }, .len = @intCast(i) };
        },
        OP_MOV_RM8 => {
            const m = modrm(bytes, &i, rex) orelse return null;
            if (!byteRegValid(m.reg, rex)) return null;
            return .{ .op = .{ .load = .{ .reg = m.reg, .size = 1, .ext = .none } }, .len = @intCast(i) };
        },
        OP_MOV_RM => {
            const m = modrm(bytes, &i, rex) orelse return null;
            return .{ .op = .{ .load = .{ .reg = m.reg, .size = wide_size, .ext = wide_ext } }, .len = @intCast(i) };
        },
        OP_TWO_BYTE => {
            if (i >= bytes.len) return null;
            const op2 = bytes[i];
            i += 1;
            const src_size: u8 = switch (op2) {
                OP2_MOVZX_B => 1,
                OP2_MOVZX_W => 2,
                else => return null,
            };
            const m = modrm(bytes, &i, rex) orelse return null;
            return .{ .op = .{ .load = .{ .reg = m.reg, .size = src_size, .ext = .zero } }, .len = @intCast(i) };
        },
        OP_MOV_MI8 => {
            const m = modrm(bytes, &i, rex) orelse return null;
            if (m.reg & 0b111 != 0) return null; // opcode extension /0
            const imm = readImm(bytes, &i, 1) orelse return null;
            return .{ .op = .{ .store = .{ .size = 1, .src = .{ .imm = imm } } }, .len = @intCast(i) };
        },
        OP_MOV_MI => {
            const m = modrm(bytes, &i, rex) orelse return null;
            if (m.reg & 0b111 != 0) return null; // opcode extension /0
            // Immediate is imm16 with the operand-size prefix, else imm32 —
            // sign-extended to the 64-bit operand under REX.W (SDM "MOV").
            const imm_bytes: u8 = if (opsize) 2 else 4;
            const raw = readImm(bytes, &i, imm_bytes) orelse return null;
            const imm = if (rex_w) @as(u64, @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @intCast(raw))))))) else raw;
            return .{ .op = .{ .store = .{ .size = wide_size, .src = .{ .imm = imm } } }, .len = @intCast(i) };
        },
        else => return null,
    }
}

const ModRm = struct { reg: u4 };

/// Consume the ModRM byte and its SIB/displacement tail, advancing `*i` past
/// them. Returns the reg field (REX.R-extended), or null for a register-direct
/// operand (mod 3 — not a memory access) or a truncated buffer.
fn modrm(bytes: []const u8, i: *usize, rex: u8) ?ModRm {
    if (i.* >= bytes.len) return null;
    const b = bytes[i.*];
    i.* += 1;
    const mod: u2 = @intCast(b >> 6);
    const reg: u3 = @intCast((b >> 3) & 0b111);
    const rm: u3 = @intCast(b & 0b111);
    if (mod == 3) return null;

    var disp: usize = switch (mod) {
        0 => if (rm == 0b101) 4 else 0, // RIP-relative disp32
        1 => 1,
        2 => 4,
        else => unreachable,
    };
    if (rm == 0b100) { // SIB follows
        if (i.* >= bytes.len) return null;
        const sib = bytes[i.*];
        i.* += 1;
        // SIB base 101 with mod 00 means no base register, disp32 follows.
        if (mod == 0 and sib & 0b111 == 0b101) disp = 4;
    }
    if (i.* + disp > bytes.len) return null;
    i.* += disp;

    const rex_r: u4 = if (rex & 0b0100 != 0) 0b1000 else 0;
    return .{ .reg = rex_r | @as(u4, reg) };
}

/// A byte-register operand encoded 4..7 without any REX prefix is AH/CH/DH/BH
/// (SDM Vol 2 §2.1.5, Table 2-4); the subset refuses those — with a REX prefix
/// the same encodings mean SPL/BPL/SIL/DIL and decode normally.
fn byteRegValid(reg: u4, rex: u8) bool {
    return rex != 0 or reg < 4;
}

/// Read a little-endian immediate of `n` bytes, advancing `*i` past it.
fn readImm(bytes: []const u8, i: *usize, n: u8) ?u64 {
    if (i.* + n > bytes.len) return null;
    var v: u64 = 0;
    var k: u8 = 0;
    while (k < n) : (k += 1) {
        v |= @as(u64, bytes[i.* + k]) << @intCast(8 * k);
    }
    i.* += n;
    return v;
}
