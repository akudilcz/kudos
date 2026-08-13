//! Low-level CPU control primitives: MSRs, control registers, TLB/cache, CPUID,
//! and the PAT/MTRR programming that makes the framebuffer write-combining. Single
//! source of truth for these instruction families (cf. io/io.zig for port I/O,
//! io/mmio.zig for MMIO loads/stores). Every other module imports `rdmsr`/`wrmsr`/
//! `cpuid`/`readCr3`/`sfence` from here rather than re-emitting the asm.
//!
//! All constants and the effective-memory-type rule are cited in Intel SDM
//! Vol 3A §11.5.2/§11.11/§11.12, cross-checked against Linux arch/x86/mm/pat.

const klog = @import("../debug/klog.zig");

// MSR numbers.
const IA32_PAT: u32 = 0x277;
const IA32_MTRRCAP: u32 = 0xFE;
const IA32_MTRR_DEF_TYPE: u32 = 0x2FF;
const IA32_MTRR_PHYSBASE0: u32 = 0x200; // PHYSBASEn = 0x200 + 2n, PHYSMASKn = +1

// Memory-type encodings.
const MT_UC: u8 = 0x00;
const MT_WC: u8 = 0x01;

/// Effective cache type for an MMIO window, selected via a variable MTRR. `uc`
/// for device register apertures (strongly ordered, no caching/combining), `wc`
/// for large write-mostly apertures like a framebuffer or a GPU BAR1. Maps to the
/// SDM memory-type encoding.
pub const MmioCacheType = enum(u8) {
    uc = MT_UC,
    wc = MT_WC,
};

// The framebuffer's 1 GiB identity-map PDPTE selects PA1 (repurposed to WC) with
// PWT=1, PCD=0, PAT=0. On a huge page PWT=bit3, PCD=bit4, PAT=bit12.
const PDPTE_PWT: u64 = 1 << 3;
const PDPTE_PCD: u64 = 1 << 4;
const PDPTE_PAT_HUGE: u64 = 1 << 12;
const PDPTE_SEL_MASK: u64 = PDPTE_PWT | PDPTE_PCD | PDPTE_PAT_HUGE;

// Default IA32_PAT (0x0007040600070406) with PA1 changed WT(04)->WC(01).
const PAT_WC_IN_PA1: u64 = 0x0007040600070106;

// The boot trampoline's PDPT (boot/boot.asm), identity-mapped. 512 1-GiB entries.
extern var p3_table: [512]u64;

// --- primitives -----------------------------------------------------------

/// Read a model-specific register (ECX = `msr`) as a 64-bit value.
pub fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [ecx] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Write a model-specific register (ECX = `msr`).
pub fn wrmsr(msr: u32, val: u64) void {
    const lo: u32 = @truncate(val);
    const hi: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr"
        :
        : [ecx] "{ecx}" (msr),
          [lo] "{eax}" (lo),
          [hi] "{edx}" (hi),
        : .{ .memory = true });
}

/// The four CPUID output registers.
pub const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

/// Execute CPUID for `leaf` (EAX) and `sub` (ECX), returning all four registers.
/// The single CPUID wrapper for the whole kernel — feature probes read the field
/// they need (e.g. `cpuid(1, 0).ecx`).
pub fn cpuid(leaf: u32, sub: u32) Cpuid {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

/// Read CR2 — the linear address of the last page fault. It is NOT part of the VMCS:
/// the guest and the host share the register, so after a VM exit it still holds
/// whatever address faulted inside the guest. That makes it the only way to see
/// where a guest that triple-faulted was pointing.
pub fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[out]"
        : [out] "=r" (-> u64),
    );
}

/// Read CR3 (the physical base of the active page tables). Used to reload CR3 for a
/// TLB flush and to hand the AP trampoline the BSP's page tables.
pub fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}

/// Write CR3 — switch address space, or (written back unchanged) flush every
/// non-global TLB entry on this core.
pub fn writeCr3(v: u64) void {
    asm volatile ("mov %[v], %%cr3"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

/// Reload CR3 to flush all non-global TLB entries (drops stale PAT-index caching
/// for the page we just re-typed).
fn flushTlb() void {
    asm volatile ("mov %[v], %%cr3"
        :
        : [v] "r" (readCr3()),
        : .{ .memory = true });
}

/// Store fence: order all prior stores before any later store. Used to flush
/// write-combining framebuffer writes before a dependent read.
pub fn sfence() void {
    asm volatile ("sfence" ::: .{ .memory = true });
}

/// RFLAGS.IF — the interrupt-enable flag (SDM Vol 1 §3.4.3).
const RFLAGS_IF: u64 = 1 << 9;

/// Whether maskable interrupts are currently enabled on this core (RFLAGS.IF set).
/// The single owner of this check: the scheduler, spinlock, and GPU MSI paths call
/// it to save/restore IF around critical sections rather than each re-emitting the
/// `pushfq; pop; test bit 9` sequence.
pub fn interruptsEnabled() bool {
    const flags = asm volatile ("pushfq; pop %[f]"
        : [f] "=r" (-> u64),
    );
    return (flags & RFLAGS_IF) != 0;
}

/// Open an IRQ-off critical section: save whether maskable interrupts were
/// enabled, then disable them. Pair with `irqRestore` (pass the returned flag)
/// so a caller that entered with interrupts already off never has them forced
/// back on. The one home of the save-IF/`cli` idiom.
pub fn irqSave() bool {
    const was_on = interruptsEnabled();
    asm volatile ("cli" ::: .{ .memory = true });
    return was_on;
}

/// Close an IRQ-off critical section opened by `irqSave`: re-enable maskable
/// interrupts only if they were enabled on entry.
pub fn irqRestore(was_on: bool) void {
    if (was_on) asm volatile ("sti" ::: .{ .memory = true });
}

/// Park the calling core forever: `hlt` in a loop, waking only to re-halt on
/// each interrupt. The terminal state for fatal bring-up paths where there is
/// nothing left to do.
pub fn park() noreturn {
    while (true) asm volatile ("hlt");
}

/// Park the calling core forever with maskable interrupts masked (`cli; hlt`):
/// the core never runs another instruction short of an NMI. For retired
/// (fault-contained) cores and the end of the reset chain.
pub fn parkMasked() noreturn {
    while (true) asm volatile ("cli; hlt");
}

/// Physical-address width in bits (CPUID.80000008h:EAX[7:0]).
fn physAddrBits() u6 {
    return @intCast(cpuid(0x80000008, 0).eax & 0xFF);
}

// --- MTRR probe -----------------------------------------------------------

/// The MTRR memory type covering `phys` (UC=0, WC=1, WT=4, WP=5, WB=6), honoring
/// the "UC wins among overlapping variable MTRRs" rule; falls back to the default
/// type when no variable MTRR matches. Used to predict whether PAT WC will take
/// effect (a UC MTRR overrides PAT WC — Table 11-7).
fn mtrrTypeFor(phys: u64) u8 {
    const def = rdmsr(IA32_MTRR_DEF_TYPE);
    const cap = rdmsr(IA32_MTRRCAP);
    const vcnt: u32 = @truncate(cap & 0xFF);
    const addr_mask: u64 = (@as(u64, 1) << physAddrBits()) - 1;

    var best: ?u8 = null;
    var i: u32 = 0;
    while (i < vcnt) : (i += 1) {
        const base = rdmsr(IA32_MTRR_PHYSBASE0 + 2 * i);
        const mask = rdmsr(IA32_MTRR_PHYSBASE0 + 2 * i + 1);
        if ((mask & (1 << 11)) == 0) continue; // V (valid) bit
        const m = mask & addr_mask & ~@as(u64, 0xFFF); // bits [maxphys-1:12]
        if ((phys & m) == (base & m)) {
            const t: u8 = @truncate(base & 0xFF);
            if (t == MT_UC) return MT_UC; // UC wins immediately
            best = best orelse t;
        }
    }
    return best orelse @as(u8, @truncate(def & 0xFF));
}

// --- public API -----------------------------------------------------------

/// True if a hypervisor is present (CPUID.1:ECX[31], the "hypervisor-present"
/// bit). This bit is **always zero on physical CPUs** and is set by KVM/QEMU (and
/// every other hypervisor) — the canonical virtualization probe Linux uses for
/// X86_FEATURE_HYPERVISOR.
fn hypervisorPresent() bool {
    return (cpuid(1, 0).ecx & (1 << 31)) != 0;
}

/// Make the framebuffer write-combining (real hardware only). `phys`/`span`
/// describe the framebuffer MMIO range. Following Linux's modern path (PAT is the
/// primary lever; `arch_phys_wc_add` — the WC MTRR — is a no-op when PAT is
/// enabled, which it is on every CPU we target): reprogram PA1 of IA32_PAT to WC
/// and select it on the framebuffer's 1 GiB PDPTE. Because PAT cannot override a
/// UC MTRR (Intel SDM Table 11-7: MTRR=UC + PAT=WC → UC), also program a WC
/// variable MTRR over the span when the firmware MTRR is UC (the real-hardware
/// case) — the same `set_memory_wc` + `arch_phys_wc_add` belt-and-suspenders Linux
/// uses. Caller must have verified no normal RAM shares the framebuffer's 1 GiB
/// (WC on WB RAM corrupts coherency). Interrupts must be disabled (init runs
/// before enableInterrupts).
///
/// **Skipped under a hypervisor.** KVM does not propagate a guest's PAT=WC stores
/// over QEMU's RAM-backed `vga.vram` region to the scanned-out surface, so the
/// screen stays black. Leaving the framebuffer uncached under virtualization
/// renders correctly, and the WC speed-up matters only on the real target.
pub fn framebufferWriteCombine(phys: u64, span: u64) void {
    if (hypervisorPresent()) {
        klog.puts("fb: hypervisor detected; leaving framebuffer UC (WC breaks KVM scanout)\n");
        return;
    }

    // The framebuffer's 1 GiB PDPTE index must be inside the boot identity map
    // (p3_table is [512]u64 = 512 GiB). A firmware that maps a GPU BAR above 512 GiB
    // would index past the PDPT — an OOB write corrupting memory past it. Bail loud
    // and leave the framebuffer UC (correct, just not write-combining) rather than
    // corrupt the page tables.
    const idx: usize = @intCast(phys >> 30); // 1 GiB index
    if (idx >= p3_table.len) {
        klog.puts("fb: framebuffer above the 512 GiB identity map; leaving it UC\n");
        return;
    }

    // PA1 is unused by any live mapping (all entries select PA0/WB), so changing
    // it needs no CR0.CD/WBINVD dance — just wrmsr + a TLB flush (done below).
    wrmsr(IA32_PAT, PAT_WC_IN_PA1);

    p3_table[idx] = (p3_table[idx] & ~PDPTE_SEL_MASK) | PDPTE_PWT; // select PA1 (WC)

    if (mtrrTypeFor(phys) == MT_UC) {
        klog.puts("fb: MTRR=UC over framebuffer; adding a WC MTRR\n");
        addMtrr(phys, span, MT_WC);
    }

    flushTlb();
}

/// Set the effective cache type of an MMIO window [phys, phys+span) via a
/// variable MTRR, for callers other than the framebuffer (e.g. GPU register and
/// aperture BARs — src/drivers/gpu/rm/mmio.zig). Unlike
/// `framebufferWriteCombine`, this does NOT touch any PDPTE/PAT selection: the
/// window is reached through the identity map's existing PA0(WB) entries, and the
/// MTRR overrides that per SDM Table 11-7 (UC and WC both win over WB). Programs
/// the pair only when the firmware MTRR for the window does not already match the
/// requested type. Interrupts must be disabled (single-CPU MTRR sequence).
pub fn mapMmio(phys: u64, span: u64, cache: MmioCacheType) void {
    const want: u8 = @intFromEnum(cache);
    if (mtrrTypeFor(phys) == want) return; // firmware already covers it
    addMtrr(phys, span, want);
    flushTlb();
}

/// Program a spare variable MTRR pair to `mem_type` over [phys, phys+span). Uses
/// the full SDM §11.11.8 cache-disable sequence (single CPU, interrupts already
/// off). The span is rounded up to a power-of-two, naturally-aligned region for
/// one pair. `mem_type` is an SDM memory-type encoding (MT_UC / MT_WC).
fn addMtrr(phys: u64, span: u64, mem_type: u8) void {
    const cap = rdmsr(IA32_MTRRCAP);
    const vcnt: u32 = @truncate(cap & 0xFF);

    // Find a free (invalid) variable pair.
    var slot: ?u32 = null;
    var i: u32 = 0;
    while (i < vcnt) : (i += 1) {
        if ((rdmsr(IA32_MTRR_PHYSBASE0 + 2 * i + 1) & (1 << 11)) == 0) {
            slot = i;
            break;
        }
    }
    const n = slot orelse {
        klog.puts("fb: no free MTRR; WC may be ineffective\n");
        return;
    };

    // Power-of-two size >= span, base aligned down to that size.
    var size: u64 = 1 << 12;
    while (size < span) size <<= 1;
    const base = phys & ~(size - 1);
    const addr_mask: u64 = (@as(u64, 1) << physAddrBits()) - 1;
    const physbase = (base & ~@as(u64, 0xFFF)) | mem_type;
    const physmask = (~(size - 1) & addr_mask & ~@as(u64, 0xFFF)) | (1 << 11); // V=1

    // CD=1, NW=0; WBINVD; disable MTRRs; set pair; re-enable; WBINVD; CD=0.
    const cr0 = readCr0();
    writeCr0((cr0 | (1 << 30)) & ~@as(u64, 1 << 29)); // CD=1, NW=0
    wbinvd();
    flushTlb();
    const def = rdmsr(IA32_MTRR_DEF_TYPE);
    wrmsr(IA32_MTRR_DEF_TYPE, def & ~@as(u64, 1 << 11)); // clear E
    wrmsr(IA32_MTRR_PHYSBASE0 + 2 * n, physbase);
    wrmsr(IA32_MTRR_PHYSBASE0 + 2 * n + 1, physmask);
    wrmsr(IA32_MTRR_DEF_TYPE, def | (1 << 11)); // set E
    wbinvd();
    flushTlb();
    writeCr0(cr0); // restore CD/NW
}

/// Read CR0 (cache-control and mode bits) for the MTRR cache-disable sequence and
/// the VMX host/guest fixed-bit setup (virt/vmx.zig).
pub fn readCr0() u64 {
    return asm volatile ("mov %%cr0, %[r]"
        : [r] "=r" (-> u64),
    );
}
/// Write CR0, used to toggle CD/NW around the SDM §11.11.8 MTRR update sequence
/// and to apply the VMX-required CR0 fixed bits before VMXON.
pub fn writeCr0(v: u64) void {
    asm volatile ("mov %[v], %%cr0"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

/// Read CR4 (feature-enable bits). VMX bring-up reads it to apply the CR4 fixed
/// bits and set CR4.VMXE.
pub fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}
/// Write CR4, used to set CR4.VMXE (enable VMX operation) before VMXON.
pub fn writeCr4(v: u64) void {
    asm volatile ("mov %[v], %%cr4"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

/// True when the CPU reports VMX support (CPUID.1:ECX[5]). The single home of the
/// VMX capability probe (cf. the CPUID wrapper contract above).
pub fn hasVmx() bool {
    return (cpuid(1, 0).ecx & (1 << 5)) != 0;
}

/// A descriptor-table register image (GDTR/IDTR): 16-bit limit followed by the
/// 64-bit base, as SGDT/SIDT store it (Intel SDM Vol 3A §3.5.1). `packed` so the
/// 10-byte in-memory layout the instructions expect is exact.
pub const DescPtr = packed struct {
    limit: u16,
    base: u64,
};

/// Read the current GDTR (base + limit) to populate the VMX host-state GDTR fields.
pub fn sgdt() DescPtr {
    var p: DescPtr = undefined;
    asm volatile ("sgdt %[p]"
        : [p] "=m" (p),
    );
    return p;
}

/// Read the current IDTR (base + limit) to populate the VMX host-state IDTR fields.
pub fn sidt() DescPtr {
    var p: DescPtr = undefined;
    asm volatile ("sidt %[p]"
        : [p] "=m" (p),
    );
    return p;
}

/// Read the Task Register selector (the current TSS selector) for the VMX
/// host-state TR field.
pub fn readTr() u16 {
    return asm volatile ("str %[r]"
        : [r] "=r" (-> u16),
    );
}
/// Write-back and invalidate all caches (raw instruction). Wrapped by
/// `flushCaches`; also used inside the MTRR cache-disable sequence.
fn wbinvd() void {
    asm volatile ("wbinvd" ::: .{ .memory = true });
}

/// Write-back + invalidate all CPU caches. Used to make CPU-written DMA buffers
/// (e.g. the GSP WPR meta / radix3 tables in WB-cached sysmem) visible to a
/// device that DMAs them. Heavy (flushes everything); use sparingly at hand-off
/// points, not in hot paths.
pub fn flushCaches() void {
    wbinvd();
}

/// Flush a single cache line containing `addr` (write-back + invalidate that one
/// line). Cheap, unlike wbinvd; use in polling loops to push a small written
/// value to RAM or pull a device-written value. mfence orders it.
pub fn clflush(addr: u64) void {
    asm volatile (
        \\mfence
        \\clflush (%[a])
        \\mfence
        :
        : [a] "r" (addr),
        : .{ .memory = true });
}
