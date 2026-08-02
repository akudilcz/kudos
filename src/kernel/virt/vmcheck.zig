//! Guest-state validity checks (Intel SDM Vol 3C §27.3.1). A VM entry that fails
//! these produces exit reason 33 (invalid guest state) with no further diagnosis
//! from the CPU, so this module re-derives the most common violations from a
//! shadow of everything the run loop intends to VMWRITE. It runs on the target
//! before the first VMLAUNCH and again on any reason-33 exit; it also host-tests
//! (test/kernel/virt/vmcheck_test.zig), where each check is proven by mutating a
//! known-good shadow and confirming exactly the expected violation.
//!
//! This is a diagnostic aid, not a complete encoding of §27.3: it covers the
//! checks a 64-bit flat guest actually trips (control-register and EFER
//! consistency, RFLAGS, CS long-mode attributes, TR usability, canonical bases).
//! Passing it does not guarantee entry; failing it names a real problem.

pub const vmcs = @import("vmcs.zig");

/// Everything the run loop writes into guest state, mirrored so the checker (and a
/// crash dump) can inspect the intended VMCS without a VMREAD. Field names track
/// the VMCS fields in vmcs.zig.
pub const GuestShadow = struct {
    cr0: u64,
    cr3: u64,
    cr4: u64,
    efer: u64,
    rflags: u64,
    rip: u64,
    rsp: u64,

    cs_selector: u16,
    cs_base: u64,
    cs_limit: u32,
    cs_ar: u32,

    tr_selector: u16,
    tr_base: u64,
    tr_limit: u32,
    tr_ar: u32,

    gdtr_base: u64,
    gdtr_limit: u32,
    idtr_base: u64,
    idtr_limit: u32,

    /// VM-entry controls (vmcs.ENTRY_*), needed for the IA-32e-mode consistency
    /// checks that tie CR0.PG, EFER.LMA, and CS.L together.
    entry_controls: u32,
};

/// A single failed check, named for a log line and carrying the offending value.
pub const Violation = struct {
    check: []const u8,
    field: vmcs.Field,
    value: u64,
};

// Control-register / EFER bits used by the checks.
const CR0_PE: u64 = 1 << 0;
const CR0_PG: u64 = 1 << 31;
const CR4_PAE: u64 = 1 << 5;
const EFER_LME: u64 = 1 << 8;
const EFER_LMA: u64 = 1 << 10;

// Access-rights bits (SDM Vol 3C Table 24-2). The AR field is the segment
// descriptor's bytes 5–6 attributes with an "unusable" bit at position 16.
const AR_TYPE_MASK: u32 = 0xF;
const AR_S: u32 = 1 << 4; // descriptor type: 1 = code/data
const AR_PRESENT: u32 = 1 << 7;
const AR_L: u32 = 1 << 13; // 64-bit code segment
const AR_DB: u32 = 1 << 14; // default operation size
const AR_UNUSABLE: u32 = 1 << 16;

// RFLAGS bits.
const RFLAGS_RESERVED1: u64 = 1 << 1; // always 1
const RFLAGS_VM: u64 = 1 << 17;
const RFLAGS_RESERVED_ZERO: u64 = ~@as(u64, 0) << 22 | (1 << 3) | (1 << 5) | (1 << 15);

/// Run the checks over `s`, appending violations to `out`. Returns the number
/// written (capped at out.len). Zero means the shadow passes the encoded checks.
pub fn checkGuestState(s: *const GuestShadow, out: []Violation) usize {
    var n: usize = 0;
    const ia32e = s.entry_controls & vmcs.ENTRY_IA32E_MODE_GUEST != 0;

    const emit = struct {
        fn f(list: []Violation, cnt: *usize, check: []const u8, field: vmcs.Field, value: u64) void {
            if (cnt.* < list.len) {
                list[cnt.*] = .{ .check = check, .field = field, .value = value };
            }
            cnt.* += 1; // count even when the buffer is full, so callers see truncation
        }
    }.f;

    // §27.3.1.1 — CR0.PG requires CR0.PE (protected mode) under VMX without
    // unrestricted guest, which we never use.
    if (s.cr0 & CR0_PG != 0 and s.cr0 & CR0_PE == 0)
        emit(out, &n, "CR0.PG set without CR0.PE", .guest_cr0, s.cr0);

    // IA-32e-mode guest requires CR0.PG, CR4.PAE, and EFER.LMA all set.
    if (ia32e) {
        if (s.cr0 & CR0_PG == 0)
            emit(out, &n, "IA-32e guest without CR0.PG", .guest_cr0, s.cr0);
        if (s.cr4 & CR4_PAE == 0)
            emit(out, &n, "IA-32e guest without CR4.PAE", .guest_cr4, s.cr4);
        if (s.efer & EFER_LMA == 0)
            emit(out, &n, "IA-32e guest without EFER.LMA", .guest_ia32_efer, s.efer);
    }

    // §27.3.1.1 — EFER.LMA must equal the IA-32e-mode-guest entry control, and
    // EFER.LME must equal EFER.LMA when CR0.PG is set.
    const lma = s.efer & EFER_LMA != 0;
    if (lma != ia32e)
        emit(out, &n, "EFER.LMA disagrees with IA-32e entry control", .guest_ia32_efer, s.efer);
    if (s.cr0 & CR0_PG != 0 and (s.efer & EFER_LME != 0) != lma)
        emit(out, &n, "EFER.LME disagrees with EFER.LMA under paging", .guest_ia32_efer, s.efer);

    // §27.3.1.4 — RFLAGS bit 1 must be 1; reserved bits must be 0; VM must be 0
    // in IA-32e mode.
    if (s.rflags & RFLAGS_RESERVED1 == 0)
        emit(out, &n, "RFLAGS bit 1 not set", .guest_rflags, s.rflags);
    if (s.rflags & RFLAGS_RESERVED_ZERO != 0)
        emit(out, &n, "RFLAGS reserved bit set", .guest_rflags, s.rflags);
    if (ia32e and s.rflags & RFLAGS_VM != 0)
        emit(out, &n, "RFLAGS.VM set in IA-32e mode", .guest_rflags, s.rflags);

    // §27.3.1.2 — CS must be a present code segment; in IA-32e a 64-bit code
    // segment has L=1 and D=0.
    if (s.cs_ar & AR_UNUSABLE != 0)
        emit(out, &n, "CS marked unusable", .guest_cs_ar, s.cs_ar);
    if (s.cs_ar & AR_PRESENT == 0)
        emit(out, &n, "CS not present", .guest_cs_ar, s.cs_ar);
    if (s.cs_ar & AR_S == 0)
        emit(out, &n, "CS not a code/data descriptor", .guest_cs_ar, s.cs_ar);
    if (ia32e and s.cs_ar & AR_L == 0)
        emit(out, &n, "64-bit guest with CS.L clear", .guest_cs_ar, s.cs_ar);
    if (ia32e and s.cs_ar & AR_L != 0 and s.cs_ar & AR_DB != 0)
        emit(out, &n, "CS.L and CS.D both set", .guest_cs_ar, s.cs_ar);

    // §27.3.1.2 — TR must be usable with a 64-bit busy TSS type (11); base
    // canonical.
    if (s.tr_ar & AR_UNUSABLE != 0)
        emit(out, &n, "TR marked unusable", .guest_tr_ar, s.tr_ar);
    if (s.tr_ar & AR_TYPE_MASK != 11)
        emit(out, &n, "TR type is not 64-bit busy TSS (11)", .guest_tr_ar, s.tr_ar);
    if (!canonical(s.tr_base))
        emit(out, &n, "TR base not canonical", .guest_tr_base, s.tr_base);

    // §27.3.1.3 — GDTR/IDTR bases canonical; limits fit in 16 bits.
    if (!canonical(s.gdtr_base))
        emit(out, &n, "GDTR base not canonical", .guest_gdtr_base, s.gdtr_base);
    if (!canonical(s.idtr_base))
        emit(out, &n, "IDTR base not canonical", .guest_idtr_base, s.idtr_base);
    if (s.gdtr_limit > 0xFFFF)
        emit(out, &n, "GDTR limit exceeds 0xFFFF", .guest_gdtr_limit, s.gdtr_limit);

    // §27.3.1.4 — RIP canonical in IA-32e mode.
    if (ia32e and !canonical(s.rip))
        emit(out, &n, "RIP not canonical", .guest_rip, s.rip);

    return n;
}

/// A 48-bit canonical address: bits 63:47 must all equal bit 47 (SDM Vol 1 §3.3.7.1).
fn canonical(addr: u64) bool {
    const sign = addr >> 47;
    return sign == 0 or sign == 0x1FFFF;
}
