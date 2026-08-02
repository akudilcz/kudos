//! Per-core runtime GDT with a Task State Segment, installed on cores that host a
//! virtual CPU. VMX host-state loading (SDM Vol 3C §27.5) requires a valid Task
//! Register: after a VM exit the CPU loads the host TR from the VMCS, and the
//! descriptor it names must be a present 64-bit TSS. The boot GDT (boot/boot.asm)
//! and the AP trampoline GDT carry only null/code/data — no TSS — so a core that
//! runs a guest installs this GDT first.
//!
//! The code and data descriptors are bit-identical to the boot GDT's, so the live
//! CS/SS/DS/… selectors stay valid across the LGDT with no segment reload; only a
//! TSS descriptor is added at selector 0x18. IST and RSP0 stay zero — kudos runs
//! ring-0 only and every IDT gate uses IST 0 (interrupts/idt.zig), so the TSS is
//! never consulted for a stack; it exists solely to satisfy the VMX TR check.
//!
//! Indexed by `percpu.indexOrBsp`, not `index`: the single-core build runs guests
//! on core 0 too but installs no per-CPU GS base, so reading the core number
//! through GS there would fault before the guest ever started.

const cpu = @import("cpu.zig");
const percpu = @import("../sched/percpu.zig");

/// Selectors into this GDT. Code/data match the boot GDT; the TSS is new.
pub const SEL_CODE: u16 = 0x08;
pub const SEL_DATA: u16 = 0x10;
pub const SEL_TSS: u16 = 0x18;

// Segment descriptors, identical to boot/boot.asm (§"64-bit GDT"): a 64-bit code
// segment (executable, S, present, long) and a writable data segment.
const DESC_CODE64: u64 = (1 << 43) | (1 << 44) | (1 << 47) | (1 << 53);
const DESC_DATA: u64 = (1 << 41) | (1 << 44) | (1 << 47);

// The available-64-bit-TSS descriptor type + present bit for the attribute byte
// (SDM Vol 3A §7.2.3; LTR marks it busy = type 0xB).
const TSS_DESC_ATTR: u64 = 0x89; // P=1, DPL=0, type=9 (available 64-bit TSS)
const TSS_LIMIT: u64 = @sizeOf(Tss) - 1;

/// 64-bit Task State Segment (SDM Vol 3A §7.7). All stack-pointer fields are zero
/// (never used); `io_map_base` past the limit disables the I/O permission bitmap.
const Tss = extern struct {
    reserved0: u32 = 0,
    rsp: [3]u64 = .{ 0, 0, 0 },
    reserved1: u64 = 0,
    ist: [7]u64 = .{ 0, 0, 0, 0, 0, 0, 0 },
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    io_map_base: u16 = 104, // == @sizeOf(Tss): no I/O bitmap follows
};

// One GDT and TSS per core, in .bss. The GDT holds five 8-byte slots: null, code,
// data, and the two halves of the 16-byte TSS system descriptor.
var gdts: [percpu.MAX_CPUS][5]u64 = undefined;
var tsses: [percpu.MAX_CPUS]Tss = undefined;

/// Install this core's GDT and load its TR. Idempotent: a core that already runs
/// on this GDT (TR = SEL_TSS) returns immediately. Runs with interrupts disabled
/// because it swaps the live descriptor table.
pub fn installForThisCore() void {
    const was = cpu.irqSave();
    defer cpu.irqRestore(was);

    if (cpu.readTr() == SEL_TSS) return;

    const i = percpu.indexOrBsp();
    const g = &gdts[i];
    tsses[i] = .{};
    const base = @intFromPtr(&tsses[i]);

    g[0] = 0;
    g[1] = DESC_CODE64;
    g[2] = DESC_DATA;
    g[3] = tssDescLow(base);
    g[4] = tssDescHigh(base);

    lgdt(.{ .limit = @sizeOf([5]u64) - 1, .base = @intFromPtr(g) });
    ltr(SEL_TSS);
}

/// This core's TSS base address, for the VMX host-state TR-base field.
pub fn tssBase() u64 {
    return @intFromPtr(&tsses[percpu.indexOrBsp()]);
}

/// Low 8 bytes of the 16-byte TSS descriptor: limit, base[31:0] split, attributes.
fn tssDescLow(base: u64) u64 {
    return (TSS_LIMIT & 0xFFFF) |
        ((base & 0xFFFF) << 16) |
        (((base >> 16) & 0xFF) << 32) |
        (TSS_DESC_ATTR << 40) |
        (((TSS_LIMIT >> 16) & 0xF) << 48) |
        (((base >> 24) & 0xFF) << 56);
}

/// High 8 bytes: base[63:32] (the rest reserved zero).
fn tssDescHigh(base: u64) u64 {
    return base >> 32;
}

fn lgdt(p: cpu.DescPtr) void {
    asm volatile ("lgdt %[p]"
        :
        : [p] "*p" (&p),
        : .{ .memory = true });
}

fn ltr(sel: u16) void {
    asm volatile ("ltr %[s]"
        :
        : [s] "r" (sel),
    );
}
