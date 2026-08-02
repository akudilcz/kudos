//! 64-bit IDT setup. Gates point at the asm stub table.

const isr = @import("isr.zig");

/// One 16-byte 64-bit IDT gate descriptor (SDM Vol 3A §6.14.1). The 64-bit handler
/// offset is split across offset_low/mid/high.
const Entry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    zero: u32,
};

/// The IDTR operand loaded by `lidt`: table byte-limit plus base address.
const Idtr = packed struct {
    limit: u16,
    base: u64,
};

extern const isr_stub_table: [256]u64; // from boot/isr.asm

var idt: [256]Entry = undefined;

const KERNEL_CS: u16 = 0x08; // code selector from the boot GDT
const INTERRUPT_GATE: u8 = 0x8E; // present, DPL0, 64-bit interrupt gate

/// Fill IDT slot `vec` with a present, DPL0, 64-bit interrupt gate targeting the
/// asm stub at `handler` in the kernel code segment (IST unused → uses TSS RSP0).
fn setGate(vec: usize, handler: u64) void {
    idt[vec] = .{
        .offset_low = @truncate(handler),
        .selector = KERNEL_CS,
        .ist = 0,
        .type_attr = INTERRUPT_GATE,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
        .zero = 0,
    };
}

/// Point all 256 gates at their asm stubs and load the IDTR. Called once on the
/// BSP; APs share this same IDT (it is not per-core state).
pub fn init() void {
    for (0..256) |i| setGate(i, isr_stub_table[i]);

    const idtr = Idtr{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&idtr),
        : .{ .memory = true });
}

/// Set RFLAGS.IF so this core starts accepting maskable interrupts. Call only
/// after the IDT, PIC, and LAPIC are programmed.
pub fn enableInterrupts() void {
    asm volatile ("sti");
}
