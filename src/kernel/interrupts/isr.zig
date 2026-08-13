//! Interrupt dispatch. The asm stubs in boot/isr.asm
//! build a uniform Frame and call isrDispatch.

const klog = @import("../debug/klog.zig");
const pic = @import("pic.zig");
const buildinfo = @import("buildinfo");
const lapic = @import("../apic/lapic.zig");
const ioapic = @import("../apic/ioapic.zig");
const sessionspace = @import("../memory/sessionspace.zig");
const sched = @import("../sched/sched.zig");
const percpu = @import("../sched/percpu.zig");
const smp = @import("../smp/smp.zig");
const crashlog = @import("../debug/crashlog.zig");
const power = @import("../power/reboot.zig");
const deadman = @import("../debug/deadman.zig");
const timer = @import("../timer/timer.zig");
const counter = @import("../debug/counter.zig");

/// Spurious IRQ7/IRQ15 arrivals absorbed without a handler (see the bail in
/// isrDispatch): a stuck or floating line shows up here instead of nowhere.
var cnt_spurious_irq = counter.Counter{ .mod = .irq, .name = "spurious" };

/// LAPIC timer interrupt vector (above the PIC's 0x20-0x2F range). Each core's
/// LAPIC timer fires this; the handler EOIs the LAPIC and preempts (sched.tick).
pub const LAPIC_TIMER_VECTOR: u8 = 0x40;

/// MSI vector range. PCI message-signalled
/// interrupts are allocated here — deliberately above the LAPIC timer (0x40) and
/// wakeup IPI (0x41) so a chosen MSI vector cannot alias them. MSIs are
/// LAPIC-delivered: dispatch EOIs the LOCAL APIC (via the handler), never the PIC.
pub const MSI_VECTOR_BASE: u8 = 0x50;
pub const MSI_VECTOR_COUNT: u8 = 16; // vectors 0x50..0x5F

/// Saved register frame, laid out to match the push order in boot/isr.asm.
pub const Frame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// A registered interrupt handler: takes no args and acknowledges its own source
/// per the dispatch rules (PIC handlers are EOI'd by the dispatcher; MSI handlers
/// own the LAPIC EOI themselves).
pub const IrqHandler = *const fn () void;

// PIC IRQ handlers (16 legacy lines, vectors 0x20-0x2F) and MSI handlers
// (MSI_VECTOR_COUNT vectors from MSI_VECTOR_BASE). Kept in separate tables
// because the two interrupt sources are acknowledged differently (PIC EOI vs
// LAPIC EOI) — see isrDispatch.
var irq_handlers: [16]?IrqHandler = .{null} ** 16;
var msi_handlers: [MSI_VECTOR_COUNT]?IrqHandler = .{null} ** MSI_VECTOR_COUNT;

/// Register a legacy PIC IRQ handler and unmask the line. `irq` is 0–15; an
/// out-of-range line is a configuration bug and panics rather than corrupting
/// memory past the table. Registering over an already-live line panics too
/// (fail-loud): silently replacing a live handler would drop the previous
/// driver's interrupts with no trace — a real double-register is a config bug,
/// not a supported hot-swap.
pub fn registerIrq(irq: u8, handler: IrqHandler) void {
    if (irq >= irq_handlers.len) @panic("isr.registerIrq: IRQ line out of range (0..15)");
    if (irq_handlers[irq] != null) @panic("isr.registerIrq: IRQ line already has a handler");
    irq_handlers[irq] = handler;
    pic.clearMask(irq);
}

/// Register an MSI handler for a vector in [MSI_VECTOR_BASE, +MSI_VECTOR_COUNT).
/// The handler is invoked from isrDispatch's MSI arm and owns the LAPIC EOI (no
/// PIC EOI — MSIs are LAPIC-delivered). A vector outside the MSI range is a
/// configuration bug and panics loudly, as is registering over a vector that
/// already has a handler (fail-loud: a silent replace would drop the previous
/// device's interrupts unnoticed).
pub fn registerMsi(vector: u8, handler: IrqHandler) void {
    if (vector < MSI_VECTOR_BASE or vector >= MSI_VECTOR_BASE + MSI_VECTOR_COUNT)
        @panic("isr.registerMsi: vector outside the MSI range (0x50..0x5F)");
    if (msi_handlers[vector - MSI_VECTOR_BASE] != null)
        @panic("isr.registerMsi: MSI vector already has a handler");
    msi_handlers[vector - MSI_VECTOR_BASE] = handler;
}

/// Read CR2, which holds the faulting linear address on a #PF. Read directly in
/// the exception dump (not via cpu.zig) so a page fault can be diagnosed even if
/// GS/other state is corrupt.
fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[r]"
        : [r] "=r" (-> u64),
    );
}

/// Human-readable names for CPU exception vectors 0–21 (SDM Vol 3A §6.15),
/// indexed by vector, for the exception dump in isrDispatch.
const exception_names = [_][]const u8{
    "divide-by-zero",      "debug",
    "NMI",                 "breakpoint",
    "overflow",            "bound-range",
    "invalid-opcode",      "device-not-available",
    "double-fault",        "coprocessor-overrun",
    "invalid-TSS",         "segment-not-present",
    "stack-segment-fault", "general-protection",
    "page-fault",          "reserved-15",
    "x87-fp",              "alignment-check",
    "machine-check",       "SIMD-fp",
    "virtualization",      "control-protection",
};

/// The single C-ABI entry point every asm stub jumps to after building `frame`.
/// Routes by vector: CPU exceptions (<32) dump state and halt; PIC IRQs (32–47)
/// run their handler and PIC-EOI unless spurious; MSIs (0x50–0x5F) run their
/// handler which owns the LAPIC EOI; LAPIC timer / wakeup IPI (SMP) EOI the local
/// APIC and reschedule; the LAPIC spurious vector (0xFF) is deliberately not
/// EOI'd.
export fn isrDispatch(frame: *Frame) callconv(.c) void {
    const vec = frame.vector;
    if (vec < 32) {
        // The fatal path's ONLY output channel is this core's crash record
        // (kernel/debug/crashlog.zig): the fault may have interrupted this very
        // core inside klog's bus-lock critical section, so by construction
        // nothing here touches the trace bus or any lock. The sealed record
        // reaches the wire through any live core's netdebug drain, or through
        // flushNow on the terminal path below.
        const slot = percpu.indexOrZero();
        const name = if (vec < exception_names.len) exception_names[vec] else "reserved";
        crashlog.puts(slot, "\n*** CPU EXCEPTION: ");
        crashlog.puts(slot, name);
        crashlog.puts(slot, " vec=");
        crashlog.putHex(slot, vec);
        crashlog.puts(slot, " err=");
        crashlog.putHex(slot, frame.error_code);
        crashlog.puts(slot, " rip=");
        crashlog.putHex(slot, frame.rip);
        crashlog.puts(slot, " cr2=");
        crashlog.putHex(slot, readCr2());
        // LAPIC id read directly (no GS deref — GS may be the corrupted thing).
        crashlog.puts(slot, " lapic=");
        crashlog.putHex(slot, lapic.id());
        crashlog.puts(slot, "\n");
        // Call-stack backtrace of the FAULTING context: the faulting instruction
        // (frame.rip) first, then the rbp chain — seeded at the saved RBP, bound
        // to the saved RSP (same kernel stack — a kernel fault takes no stack
        // switch) — gives its callers. Raw addresses; addr2line maps them offline
        // (the panic backtrace).
        crashlog.puts(slot, "*** backtrace (rip + rbp chain; addr2line against the ELF):\n");
        crashlog.puts(slot, "*** BT ");
        crashlog.putHex(slot, frame.rip);
        crashlog.puts(slot, " (faulting rip)\n");
        _ = crashlog.emitBacktrace(slot, frame.rbp, frame.rsp);
        // A fault taken in a SESSION's address space is that session's failure,
        // not the machine's (MEM-005/006): the classifier counts it and records
        // the session for the desktop to close; the faulting task dies here and
        // the core keeps running everything else. Sealed first: the record's
        // owner core stays alive and ships it on its own next drain. Only a
        // fault in the KERNEL space falls through to core containment.
        if (comptime buildinfo.smp) {
            if (sessionspace.containCurrentFault()) {
                crashlog.seal(slot);
                sched.exitFromFault();
            }
        }
        // A kernel fault on a non-BSP core appends its containment note, seals
        // the record and parks that core (contained) — any surviving core's
        // drain ships it. On the bootstrap core this returns and the crash path
        // below runs.
        smp.containIfAp();
        crashlog.puts(slot, "*** crash held, then reboot (one-shot -> fallback OS)\n");
        crashlog.seal(slot);
        klog.flushCrash(); // best-effort: get the crash record onto the LAN
        power.crashReboot();
    }
    if (vec < 48) {
        const irq: u8 = @intCast(vec - 32);
        // A spurious IRQ7/IRQ15 (the 8259 raises these when a line deasserts before
        // the CPU acks) must not run a handler and has bespoke EOI rules — see
        // pic.spurious. Bailing here avoids an unearned EOI that would dismiss a real
        // in-service IRQ and, over time, wedge the line. Counted, not silently
        // absorbed: a climbing rate is the fingerprint of a floating/misrouted line.
        if (pic.spurious(irq)) {
            counter.register(&cnt_spurious_irq); // idempotent — first spurious anywhere registers it
            cnt_spurious_irq.inc();
            return;
        }
        // Deadman: the PIT tick keeps firing while a loop spins with interrupts
        // live — if the steady loops have gone silent past the fuse, log the
        // interrupted RIP + backtrace (the wedged code is exactly what this
        // interrupt landed in). One bounded report a second, on the fuse's own
        // TSC clock; see kernel/debug/deadman.zig. IRQ0 arrives here only while
        // the PIC still delivers it — pre-SMP and the single-core build, both
        // BSP-only, hence the literal core 0 (GS may not be live yet, so
        // percpu.index() is not safe here).
        if (irq == 0) deadman.checkFromIrq(0, frame.rip, frame.rbp, frame.rsp);
        if (irq_handlers[irq]) |h| h();
        pic.eoi(irq);
        return;
    }
    // MSI range (0x50-0x5F): LAPIC-delivered. Invoke the registered handler,
    // which owns the LAPIC EOI (e.g. the GPU's msi.trampoline). No PIC EOI — an
    // MSI is not an 8259 line.
    if (vec >= MSI_VECTOR_BASE and vec < MSI_VECTOR_BASE + MSI_VECTOR_COUNT) {
        const slot: u8 = @intCast(vec - MSI_VECTOR_BASE);
        if (msi_handlers[slot]) |h| h() else {
            // In-range but unregistered (a device firing before/after its
            // registerMsi): still EOI, or this priority class's in-service bit
            // stays set and the core's LAPIC wedges on the next interrupt.
            lapic.eoi();
        }
        return;
    }
    // Wall-clock tick via the IO-APIC (SMP only, after smp routes it away from
    // the PIC): advance the clock, feed this core's deadman, aim the next tick
    // at the next online core (KRN-012), then give THIS core's scheduler a
    // pass. The scheduler pass is load-bearing: an idle core with a disarmed
    // preemption deadline takes no LAPIC-timer interrupt, so this rotating tick
    // is the only periodic entry it has into schedule() — without it the core's
    // parked zombie is never reaped and its exit hooks never fire. Rotation is
    // re-armed BEFORE the pass because schedule() may switch stacks and return
    // to this frame arbitrarily late — the machine-wide clock must not wait on
    // one core's scheduling. LAPIC-delivered, so LAPIC EOI — the PIC never saw
    // this edge. Per-CPU GS is live on every rotation target: a core only
    // enters the rotation once its scheduler is up, and it takes the interrupt
    // only once a task ran `sti`.
    if (buildinfo.smp and vec == ioapic.TICK_VECTOR) {
        lapic.eoi();
        timer.tick();
        deadman.checkFromIrq(percpu.index(), frame.rip, frame.rbp, frame.rsp);
        ioapic.rotate();
        sched.tick();
        return;
    }
    // TLB shootdown (SMP only): another core reshaped an address space; drop
    // every stale translation before this core can touch remapped memory.
    if (buildinfo.smp and vec == sessionspace.TLB_VECTOR) {
        lapic.eoi();
        sessionspace.flushLocal();
        return;
    }
    // LAPIC timer (SMP only): EOI the local APIC, then preempt this core. The
    // reschedule swaps stacks so the iret returns into the newly-scheduled task.
    if (buildinfo.smp and vec == LAPIC_TIMER_VECTOR) {
        lapic.eoi();
        // Deadman for this core (percpu GS is live wherever a LAPIC timer is armed).
        // Before sched.tick: the reschedule may not return to this frame.
        deadman.checkFromIrq(percpu.index(), frame.rip, frame.rbp, frame.rsp);
        sched.tick();
        return;
    }
    // Wakeup IPI (SMP only): core 0 routed work to this AP and pulled a blocked
    // task back onto our run queue. EOI FIRST (the reschedule may not return to
    // this frame), then drain the wake ring + reschedule.
    if (buildinfo.smp and vec == lapic.WAKEUP_VECTOR) {
        lapic.eoi();
        sched.wakeDrain();
        return;
    }
    // LAPIC spurious vector (SVR bits[7:0], lapic.SPURIOUS_VECTOR). A spurious
    // interrupt means the LAPIC had nothing truly in-service, so there is NO ISR bit
    // to clear: it must NOT be EOI'd (an EOI here would dismiss an unrelated real
    // interrupt). Enforced explicitly here, not left to falling through the end
    // of the dispatcher by accident.
    if (vec == lapic.SPURIOUS_VECTOR) return;

    // Any other vector reaching here is unexpected — nothing programs the LAPIC to
    // deliver it. It DID come from the local APIC (it is not a PIC line, MSI, or the
    // known SMP/spurious vectors), so its ISR bit is set: EOI it or that priority
    // class wedges the core. Log loudly (fail-loud rule) rather than silently
    // returning without an EOI. Only the spurious vector above legitimately skips EOI.
    klog.puts("*** unexpected interrupt vector ");
    klog.putHex(vec);
    klog.puts(" — EOI + ignore\n");
    lapic.eoi();
}
