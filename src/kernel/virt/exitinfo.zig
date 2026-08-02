//! Decoders for the VM-exit qualification and related fields (Intel SDM Vol 3C
//! §27.2.1, Tables 27-3/5/7). Pure bit-field extraction — the run loop reads the
//! raw VMCS fields with virt/vmxasm.zig and hands the values here to get typed
//! exit descriptions. Host-tested (test/kernel/virt/exitinfo_test.zig) against known
//! qualification words so a mis-shifted field is caught off-hardware.

/// I/O-instruction exit (exit reason 30) qualification — SDM Vol 3C Table 27-5.
pub const IoInfo = struct {
    /// Access width in bytes (1, 2, or 4).
    size: u8,
    /// Direction: true = IN (port → guest), false = OUT (guest → port).
    is_in: bool,
    /// A string instruction (INS/OUTS) rather than IN/OUT.
    is_string: bool,
    /// REP-prefixed string instruction.
    is_rep: bool,
    /// Operand is an immediate port (true) rather than DX (false).
    is_immediate: bool,
    /// The I/O port number.
    port: u16,

    pub fn decode(qual: u64) IoInfo {
        const size_field: u2 = @truncate(qual);
        return .{
            .size = switch (size_field) {
                0 => 1,
                1 => 2,
                3 => 4,
                else => 1, // 2 is reserved; treat as byte defensively
            },
            .is_in = (qual >> 3) & 1 != 0,
            .is_string = (qual >> 4) & 1 != 0,
            .is_rep = (qual >> 5) & 1 != 0,
            .is_immediate = (qual >> 6) & 1 != 0,
            .port = @truncate(qual >> 16),
        };
    }
};

/// EPT-violation exit (exit reason 48) qualification — SDM Vol 3C Table 27-7. The
/// faulting guest-physical address is the separate `guest_phys_addr` VMCS field,
/// not part of the qualification, so it is carried alongside.
pub const EptViolation = struct {
    /// The access was a data read.
    read: bool,
    /// The access was a data write.
    write: bool,
    /// The access was an instruction fetch.
    fetch: bool,
    /// The EPT entry allowed read / write / execute (the current permissions).
    ept_readable: bool,
    ept_writable: bool,
    ept_executable: bool,
    /// The guest-linear address (below) is valid.
    linear_valid: bool,
    /// When `linear_valid`, the fault was a translation of a guest paging-structure
    /// access rather than a normal data/instruction access.
    to_paging_structure: bool,

    pub fn decode(qual: u64) EptViolation {
        return .{
            .read = (qual >> 0) & 1 != 0,
            .write = (qual >> 1) & 1 != 0,
            .fetch = (qual >> 2) & 1 != 0,
            .ept_readable = (qual >> 3) & 1 != 0,
            .ept_writable = (qual >> 4) & 1 != 0,
            .ept_executable = (qual >> 5) & 1 != 0,
            .linear_valid = (qual >> 7) & 1 != 0,
            .to_paging_structure = (qual >> 8) & 1 != 0,
        };
    }
};

/// Control-register access exit (exit reason 28) qualification — SDM Vol 3C
/// Table 27-3.
pub const CrAccess = struct {
    /// Which control register (0, 3, 4, or 8).
    cr: u4,
    kind: Kind,
    /// For MOV to/from CR: the general-purpose register index (0 = RAX … 15 = R15).
    gp_register: u4,

    pub const Kind = enum(u2) { mov_to_cr = 0, mov_from_cr = 1, clts = 2, lmsw = 3 };

    pub fn decode(qual: u64) CrAccess {
        return .{
            .cr = @truncate(qual & 0xF),
            .kind = @enumFromInt(@as(u2, @truncate(qual >> 4))),
            .gp_register = @truncate(qual >> 8),
        };
    }
};

/// Strip the entry-failure flag (bit 31) and reserved high bits from the raw
/// exit-reason field, leaving the basic exit reason (bits 15:0). SDM Vol 3C §24.9.1.
pub fn basicExitReason(raw: u64) u16 {
    return @truncate(raw & 0xFFFF);
}

/// True when the "exit" is actually a VM-entry failure (raw exit-reason bit 31).
pub fn isEntryFailure(raw: u64) bool {
    return (raw >> 31) & 1 != 0;
}
