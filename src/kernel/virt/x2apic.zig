//! Emulated local APIC (Intel SDM Vol. 3A, §11), the guest's interrupt hub. One
//! register file, reachable two ways, because a Linux guest chooses which:
//!
//!  - x2APIC mode (§11.12): every access is an RDMSR/WRMSR of MSRs 0x800–0x83F,
//!    routed here as `msrRead`/`msrWrite`.
//!  - xAPIC mode (§11.4.1): every access is a 32-bit load or store in a 4 KiB
//!    window at MMIO_BASE, arriving as an EPT violation and routed here as
//!    `mmioRead`/`mmioWrite`.
//!
//! Serving both is not thoroughness, it is the difference between running one
//! kernel and running Linux. A guest reaches for the window whenever it has not
//! (yet) switched to x2APIC, and that includes every kernel whose APIC driver is
//! still the default one — the memory-mapped read in `register_lapic_address`
//! happens long before any x2APIC driver is installed. A hypervisor that serves
//! only MSRs meets that read as an unhandled fault in code that has no fault
//! handler, and the guest dies with "unable to handle kernel paging request".
//!
//! Either way this stays a pure register file plus IRR/ISR bookkeeping for
//! injection. Host-tested (test/kernel/virt/x2apic_test.zig).
//!
//! Only what a single-vCPU Linux guest touches is modeled: ID/VERSION, TPR,
//! EOI, spurious vector, the LVT entries, ESR, ICR (every destination is
//! self on one vCPU), and IA32_APIC_BASE reporting x2APIC already enabled.
//! The timer is TSC-deadline: a write to IA32_TSC_DEADLINE returns an
//! `arm_deadline` action for the machine model to arm against the host clock,
//! and the LVT timer entry supplies the vector to inject when it fires.
//! Interrupt priority is the architectural class scheme — bits 7:4 of the
//! vector — where a pending vector is injectable only when its class exceeds
//! the processor priority (the higher of TPR and the in-service class). An
//! ExtINT-programmed LINT0 delivers the 8259's vector below all fixed
//! interrupts; the 8259 does its own prioritization for that path.

/// IA32_APIC_BASE (SDM Vol. 4, Table 2-2): the window's base address plus BSP
/// (bit 8), x2APIC enable (bit 10), and global enable (bit 11).
///
/// At reset the APIC is enabled in xAPIC mode, which is what real firmware
/// leaves behind and therefore the state every kernel is written for. Reporting
/// x2APIC already on is a lie a guest believes: it concludes "enabled by BIOS",
/// takes a path almost nothing exercises, and reads the memory-mapped ID
/// register through an APIC driver that has not been switched over yet. The
/// guest turns x2APIC on itself, by writing this MSR, and `mode` follows.
const MSR_IA32_APIC_BASE: u32 = 0x1B;
const APIC_BASE_BSP: u64 = 1 << 8;
const APIC_BASE_X2APIC_ENABLE: u64 = 1 << 10;
const APIC_BASE_GLOBAL_ENABLE: u64 = 1 << 11;
const APIC_BASE_RESET_VALUE: u64 = MMIO_BASE | APIC_BASE_BSP | APIC_BASE_GLOBAL_ENABLE;

// ── the memory-mapped (xAPIC) view of the same registers ────────────────────
// SDM Vol. 3A §11.4.1: one 4 KiB page of 32-bit registers, one every 16 bytes.
// §11.12.1.2 gives the correspondence with the MSR view: MSR 0x800 + offset/16.

/// Where the window sits in every guest's physical address space. Also what the
/// MADT tells the guest (virt/acpi.zig) and what IA32_APIC_BASE reports.
pub const MMIO_BASE: u64 = 0xFEE0_0000;
/// One page, as the architecture fixes it.
pub const MMIO_BYTES: u64 = 0x1000;
/// Bytes between consecutive registers.
const MMIO_STRIDE: u64 = 0x10;

/// The offsets whose translation is NOT "MSR 0x800 + offset/16".
const MMIO_ID: u64 = 0x020;
const MMIO_DFR: u64 = 0x0E0; // destination format — xAPIC only
const MMIO_ICR_LOW: u64 = 0x300;
const MMIO_ICR_HIGH: u64 = 0x310;
/// xAPIC reports the local APIC id in bits 31:24 of its ID register.
const MMIO_ID_SHIFT: u5 = 24;
/// Destination format at reset: all-ones (SDM Vol. 3A Figure 11-13).
const DFR_RESET_VALUE: u32 = 0xFFFF_FFFF;

/// The MSR a memory-mapped register offset corresponds to, or null when the
/// offset is not a register boundary or falls outside the window.
fn mmioMsr(offset: u64) ?u32 {
    if (offset >= MMIO_BYTES or offset % MMIO_STRIDE != 0) return null;
    return MSR_X2APIC_FIRST + @as(u32, @intCast(offset / MMIO_STRIDE));
}

/// IA32_TSC_DEADLINE (SDM Vol. 3A, §11.5.4.1): writing arms the timer to
/// fire when the TSC passes the value; writing zero disarms it.
const MSR_IA32_TSC_DEADLINE: u32 = 0x6E0;

// x2APIC register MSRs (SDM Vol. 3A, Table 11-6).
const MSR_X2APIC_FIRST: u32 = 0x800;
const MSR_X2APIC_LAST: u32 = 0x83F;
const MSR_APIC_ID: u32 = 0x802;
const MSR_APIC_VERSION: u32 = 0x803;
const MSR_TPR: u32 = 0x808;
const MSR_PPR: u32 = 0x80A;
const MSR_EOI: u32 = 0x80B;
const MSR_LDR: u32 = 0x80D;
const MSR_SVR: u32 = 0x80F;
const MSR_ISR_BASE: u32 = 0x810; // eight 32-bit chunks, vectors 0–255
const MSR_TMR_BASE: u32 = 0x818;
const MSR_IRR_BASE: u32 = 0x820;
const MSR_ESR: u32 = 0x828;
const MSR_ICR: u32 = 0x830; // one 64-bit MSR in x2APIC, not two MMIO halves
const MSR_LVT_TIMER: u32 = 0x832;
const MSR_LVT_LINT0: u32 = 0x835;
const MSR_LVT_LINT1: u32 = 0x836;
const MSR_LVT_ERROR: u32 = 0x837;
const MSR_TIMER_DIVIDE: u32 = 0x83E;
const MSR_SELF_IPI: u32 = 0x83F;

const STATUS_CHUNKS: u32 = 8; // 256 vectors / 32 bits per ISR/TMR/IRR MSR

/// Version 0x14 with a max-LVT-entry index of 5 (bits 23:16) — what real
/// integrated local APICs report (SDM Vol. 3A, §11.4.8).
const APIC_VERSION_VALUE: u64 = 0x5_0014;

/// The logical ID x2APIC hardware derives from APIC ID 0
/// (SDM Vol. 3A, §11.12.10.2): cluster 0, logical bit 0.
const LDR_VALUE: u64 = 1;

// LVT entry layout (SDM Vol. 3A, Figure 11-8).
const LVT_VECTOR_MASK: u64 = 0xFF;
const LVT_DELIVERY_MODE_MASK: u64 = 0x700;
const LVT_DELIVERY_EXTINT: u64 = 0x700; // delivery mode 0b111
const LVT_MASKED: u64 = 1 << 16;
/// Every LVT entry resets masked (SDM Vol. 3A, §11.5.1).
const LVT_RESET_VALUE: u64 = LVT_MASKED;

// ICR layout (SDM Vol. 3A, Figure 11-12); with one vCPU any fixed-delivery
// IPI — whatever the destination — is a self-interrupt.
const ICR_DELIVERY_MODE_MASK: u64 = 0x700;
const ICR_DELIVERY_FIXED: u64 = 0x000;

const TPR_VALUE_MASK: u64 = 0xFF;
/// SVR keeps the spurious vector (7:0) and the software-enable bit (8).
const SVR_VALUE_MASK: u64 = 0x1FF;
/// SVR resets to 0xFF: vector 0xFF, APIC software-disabled (SDM §11.9).
const SVR_RESET_VALUE: u64 = 0xFF;
/// SVR bit 8 — the APIC software-enable.
const SVR_SOFTWARE_ENABLE: u64 = 1 << 8;

/// Bits 7:4 of a vector are its priority class (SDM Vol. 3A, §11.8.3.1);
/// a numerically higher vector is a higher priority.
fn priorityClass(vector: u8) u8 {
    return vector >> 4;
}

/// A 256-bit vector set stored as the guest reads it: eight 32-bit chunks,
/// chunk n covering vectors 32n..32n+31.
const VectorSet = [STATUS_CHUNKS]u32;

fn setVector(set: *VectorSet, vector: u8) void {
    set[vector >> 5] |= @as(u32, 1) << @intCast(vector & 31);
}

fn clearVector(set: *VectorSet, vector: u8) void {
    set[vector >> 5] &= ~(@as(u32, 1) << @intCast(vector & 31));
}

fn highestVector(set: *const VectorSet) ?u8 {
    var chunk: usize = STATUS_CHUNKS;
    while (chunk > 0) {
        chunk -= 1;
        if (set[chunk] != 0) {
            const top = 31 - @clz(set[chunk]);
            return @intCast(chunk * 32 + top);
        }
    }
    return null;
}

/// What a register write asks the machine model to do beyond bookkeeping.
pub const Action = union(enum) {
    none,
    /// Arm the host timer to fire when the guest TSC passes this value
    /// (zero disarms); on expiry the model raises `timerVector`.
    arm_deadline: u64,
    /// A self-IPI landed in IRR: reevaluate injection into the vCPU.
    inject: u8,
};

pub const Apic = struct {
    tpr: u64 = 0,
    svr: u64 = SVR_RESET_VALUE,
    icr: u64 = 0,
    lvt_timer: u64 = LVT_RESET_VALUE,
    lvt_lint0: u64 = LVT_RESET_VALUE,
    lvt_lint1: u64 = LVT_RESET_VALUE,
    lvt_error: u64 = LVT_RESET_VALUE,
    timer_divide: u64 = 0,
    tsc_deadline: u64 = 0,
    /// Interrupt request register: vectors raised but not yet injected.
    irr: VectorSet = [_]u32{0} ** STATUS_CHUNKS,
    /// In-service register: vectors injected and awaiting the guest's EOI.
    isr: VectorSet = [_]u32{0} ** STATUS_CHUNKS,
    /// Destination format, a register only the memory-mapped view has.
    dfr: u32 = DFR_RESET_VALUE,
    /// Whether the guest has switched the APIC to the MSR interface. It starts
    /// false — see MSR_IA32_APIC_BASE — and only the guest sets it.
    x2apic: bool = false,
    /// Memory-mapped accesses to offsets this model does not translate. A rate,
    /// not a log: a guest using a register nobody modeled shows up as a nonzero
    /// count rather than as mysteriously wrong interrupt behavior.
    mmio_unmodelled: u64 = 0,

    /// Handle a guest RDMSR. Null means the MSR is not the APIC's — the
    /// caller falls through to its other MSR handling.
    pub fn msrRead(self: *Apic, msr: u32) ?u64 {
        if (msr == MSR_IA32_APIC_BASE) return self.apicBase();
        if (msr == MSR_IA32_TSC_DEADLINE) return self.tsc_deadline;
        if (msr < MSR_X2APIC_FIRST or msr > MSR_X2APIC_LAST) return null;
        if (msr >= MSR_ISR_BASE and msr < MSR_ISR_BASE + STATUS_CHUNKS)
            return self.isr[msr - MSR_ISR_BASE];
        if (msr >= MSR_IRR_BASE and msr < MSR_IRR_BASE + STATUS_CHUNKS)
            return self.irr[msr - MSR_IRR_BASE];
        if (msr >= MSR_TMR_BASE and msr < MSR_TMR_BASE + STATUS_CHUNKS)
            return 0; // trigger-mode register: every modeled source is edge
        return switch (msr) {
            MSR_APIC_ID => 0, // the sole vCPU is APIC ID 0
            MSR_APIC_VERSION => APIC_VERSION_VALUE,
            MSR_TPR => self.tpr,
            MSR_PPR => @as(u64, self.processorPriorityClass()) << 4,
            MSR_LDR => LDR_VALUE,
            MSR_SVR => self.svr,
            MSR_ESR => 0, // no modeled error source ever latches a bit
            MSR_ICR => self.icr,
            MSR_LVT_TIMER => self.lvt_timer,
            MSR_LVT_LINT0 => self.lvt_lint0,
            MSR_LVT_LINT1 => self.lvt_lint1,
            MSR_LVT_ERROR => self.lvt_error,
            MSR_TIMER_DIVIDE => self.timer_divide,
            // EOI is write-only; the counters idle at zero because the timer
            // is TSC-deadline; remaining in-range slots read benignly as 0.
            else => 0,
        };
    }

    /// Handle a guest WRMSR. Null means the MSR is not the APIC's; otherwise
    /// the returned action tells the machine model what the write set in
    /// motion. Read-only registers accept and ignore the write.
    pub fn msrWrite(self: *Apic, msr: u32, v: u64) ?Action {
        if (msr == MSR_IA32_APIC_BASE) {
            // The one bit of this MSR a guest changes: whether it wants the MSR
            // interface. Everything else about the APIC's location is fixed, so
            // the write is otherwise ignored rather than allowed to relocate a
            // window the EPT has already been built around.
            self.x2apic = v & APIC_BASE_X2APIC_ENABLE != 0;
            return .none;
        }
        if (msr == MSR_IA32_TSC_DEADLINE) {
            self.tsc_deadline = v;
            return .{ .arm_deadline = v };
        }
        if (msr < MSR_X2APIC_FIRST or msr > MSR_X2APIC_LAST) return null;
        switch (msr) {
            MSR_TPR => self.tpr = v & TPR_VALUE_MASK,
            MSR_EOI => self.eoiPending(),
            MSR_SVR => self.svr = v & SVR_VALUE_MASK,
            MSR_ESR => {}, // a write refreshes ESR, and no errors are pending
            MSR_ICR => {
                self.icr = v;
                if (v & ICR_DELIVERY_MODE_MASK == ICR_DELIVERY_FIXED) {
                    const vector: u8 = @truncate(v);
                    self.raise(vector);
                    return .{ .inject = vector };
                }
                // INIT/SIPI/NMI shorthands target other CPUs; none exist.
            },
            MSR_SELF_IPI => {
                const vector: u8 = @truncate(v);
                self.raise(vector);
                return .{ .inject = vector };
            },
            MSR_LVT_TIMER => self.lvt_timer = v,
            MSR_LVT_LINT0 => self.lvt_lint0 = v,
            MSR_LVT_LINT1 => self.lvt_lint1 = v,
            MSR_LVT_ERROR => self.lvt_error = v,
            MSR_TIMER_DIVIDE => self.timer_divide = v,
            else => {}, // ID/VERSION/status registers are read-only
        }
        return .none;
    }

    /// IA32_APIC_BASE as the guest reads it: fixed location and enables, plus
    /// whichever interface the guest has selected.
    fn apicBase(self: *const Apic) u64 {
        return APIC_BASE_RESET_VALUE | (if (self.x2apic) APIC_BASE_X2APIC_ENABLE else 0);
    }

    /// Handle a guest 32-bit read of the memory-mapped register window, at
    /// `offset` from MMIO_BASE. See the module comment for why this exists
    /// alongside the MSR path.
    pub fn mmioRead(self: *Apic, offset: u64) u32 {
        switch (offset) {
            // xAPIC keeps the local APIC id in the top byte; x2APIC uses the
            // whole register. Same id, different place — and a guest that reads
            // it from the wrong place believes it is CPU 0xFF.
            MMIO_ID => return @as(u32, @truncate(self.msrRead(MSR_APIC_ID) orelse 0)) << MMIO_ID_SHIFT,
            // The 64-bit x2APIC ICR is two registers here. The high half is the
            // destination field, which x2APIC keeps in the ICR's upper dword.
            MMIO_ICR_HIGH => return @truncate(self.icr >> 32),
            MMIO_ICR_LOW => return @truncate(self.icr),
            // Destination format exists only in xAPIC (x2APIC has one format),
            // so it is this view's own register. Reset value is all-ones.
            MMIO_DFR => return self.dfr,
            else => {},
        }
        if (mmioMsr(offset)) |msr| return @truncate(self.msrRead(msr) orelse 0);
        self.mmio_unmodelled +%= 1;
        return 0;
    }

    /// Handle a guest 32-bit write to the memory-mapped register window.
    /// Returns what the write set in motion, exactly as `msrWrite` does.
    pub fn mmioWrite(self: *Apic, offset: u64, value: u32) Action {
        switch (offset) {
            // Latched, not issued: the guest sets the destination first and the
            // write to the low half is what sends the interrupt.
            MMIO_ICR_HIGH => {
                self.icr = (@as(u64, value) << 32) | (self.icr & 0xFFFF_FFFF);
                return .none;
            },
            // Issue the whole 64-bit ICR the two halves now describe, through
            // the one path that knows what an ICR write means.
            MMIO_ICR_LOW => return self.msrWrite(MSR_ICR, (self.icr & 0xFFFF_FFFF_0000_0000) | value) orelse .none,
            MMIO_DFR => {
                self.dfr = value;
                return .none;
            },
            MMIO_ID => return .none, // the sole vCPU's id is not the guest's to set
            else => {},
        }
        if (mmioMsr(offset)) |msr| return self.msrWrite(msr, value) orelse .none;
        self.mmio_unmodelled +%= 1;
        return .none;
    }

    /// The vector to raise when the armed deadline fires, or null while the
    /// LVT timer entry is masked.
    pub fn timerVector(self: *const Apic) ?u8 {
        if (self.lvt_timer & LVT_MASKED != 0) return null;
        const vector: u8 = @truncate(self.lvt_timer & LVT_VECTOR_MASK);
        return vector;
    }

    /// The armed TSC-deadline (0 = disarmed) the machine model polls the host
    /// counter against. The APIC is the single home of this value; `msrWrite`
    /// arms it and `fireTimer` disarms it.
    pub fn armedDeadline(self: *const Apic) u64 {
        return self.tsc_deadline;
    }

    /// The armed deadline expired: hardware disarms the MSR (SDM §11.5.4.1, so a
    /// subsequent guest RDMSR reads 0) and raises the timer vector when the LVT
    /// timer entry is unmasked.
    pub fn fireTimer(self: *Apic) void {
        self.tsc_deadline = 0;
        if (self.timerVector()) |vector| self.raise(vector);
    }

    /// A device or the expired timer requests `vector`: latch it in IRR.
    pub fn raise(self: *Apic, vector: u8) void {
        setVector(&self.irr, vector);
    }

    /// The class injection must beat: the higher of TPR's class and the
    /// highest in-service class (SDM Vol. 3A, §11.8.3.1 processor priority).
    fn processorPriorityClass(self: *const Apic) u8 {
        const tpr_class: u8 = @intCast((self.tpr >> 4) & 0xF);
        const in_service = highestVector(&self.isr) orelse return tpr_class;
        return @max(tpr_class, priorityClass(in_service));
    }

    /// Where an injected vector came from, so the machine model can retire it
    /// from the right source once the vCPU actually injects it.
    pub const Source = enum { apic, extint };
    /// The vector to inject next and its source.
    pub const Pending = struct { vector: u8, source: Source };

    /// The vector to inject next, or null when nothing beats the processor
    /// priority. A LINT0 programmed for ExtINT delivers `extint_vector` (the
    /// 8259's pending vector) below every fixed interrupt — the PIC prioritizes
    /// its own. Non-destructive: the winner is retired only when the machine
    /// model commits the injection (`accept` for a fixed vector, the 8259 INTA
    /// for the ExtINT).
    pub fn nextPending(self: *const Apic, extint_vector: ?u8) ?Pending {
        if (highestVector(&self.irr)) |vector| {
            if (priorityClass(vector) > self.processorPriorityClass())
                return .{ .vector = vector, .source = .apic };
        }
        if (extint_vector) |vector| {
            // A guest that has software-disabled its local APIC takes interrupts
            // straight from the 8259 pair: with the APIC off, the processor's
            // INTR pin is driven by the PIC and LINT0's programming does not
            // enter into it (SDM §11.4.7.2 "Local APIC State After It Has Been
            // Software Disabled"). Requiring LINT0 here would strand every such
            // guest — which includes any kernel built without x2APIC support,
            // because disabling the APIC is exactly what one does when it finds
            // an x2APIC it cannot drive.
            if (!self.softwareEnabled()) return .{ .vector = vector, .source = .extint };
            const extint_mode = self.lvt_lint0 & LVT_DELIVERY_MODE_MASK == LVT_DELIVERY_EXTINT;
            if (extint_mode and self.lvt_lint0 & LVT_MASKED == 0)
                return .{ .vector = vector, .source = .extint };
        }
        return null;
    }

    /// Whether the guest has software-enabled the local APIC (SVR bit 8). It
    /// resets disabled, and a guest that never touches the APIC leaves it so.
    pub fn softwareEnabled(self: *const Apic) bool {
        return self.svr & SVR_SOFTWARE_ENABLE != 0;
    }

    /// The machine model injects `vector`: it moves from requested to
    /// in-service, where it blocks its class until the guest's EOI.
    pub fn accept(self: *Apic, vector: u8) void {
        clearVector(&self.irr, vector);
        setVector(&self.isr, vector);
    }

    /// Retire the highest in-service vector. `msrWrite` calls this on the
    /// guest's EOI write; it is public for the machine model's ExtINT and
    /// teardown paths.
    pub fn eoiPending(self: *Apic) void {
        const vector = highestVector(&self.isr) orelse return;
        clearVector(&self.isr, vector);
    }
};
