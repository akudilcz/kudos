//! 8259 PIC remap + EOI + masking.

const io = @import("../io/io.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;
const EOI: u8 = 0x20;

pub const OFFSET1: u8 = 0x20; // master IRQs -> vectors 0x20..0x27
pub const OFFSET2: u8 = 0x28; // slave  IRQs -> vectors 0x28..0x2F

/// Remap the PICs away from the CPU-exception vectors and mask all lines.
pub fn remap() void {
    io.outb(PIC1_CMD, 0x11); // ICW1: init + ICW4 to follow
    io.wait();
    io.outb(PIC2_CMD, 0x11);
    io.wait();
    io.outb(PIC1_DATA, OFFSET1); // ICW2: vector offsets
    io.wait();
    io.outb(PIC2_DATA, OFFSET2);
    io.wait();
    io.outb(PIC1_DATA, 0x04); // ICW3: slave on IRQ2
    io.wait();
    io.outb(PIC2_DATA, 0x02);
    io.wait();
    io.outb(PIC1_DATA, 0x01); // ICW4: 8086 mode
    io.wait();
    io.outb(PIC2_DATA, 0x01);
    io.wait();

    io.outb(PIC1_DATA, 0xFF); // mask everything; drivers unmask their line
    io.outb(PIC2_DATA, 0xFF);
}

/// Signal end-of-interrupt for a genuine (non-spurious) hardware IRQ. A slave-line
/// IRQ (≥8) needs EOI to both the slave (which latched it) and the master (whose
/// cascade line IRQ2 delivered it); a master-line IRQ needs only the master.
pub fn eoi(irq: u8) void {
    if (irq >= 8) io.outb(PIC2_CMD, EOI);
    io.outb(PIC1_CMD, EOI);
}

// OCW3 command that selects the In-Service Register for the next command-port read.
const OCW3_READ_ISR: u8 = 0x0B;
// ISR bit for IRQ7 (master) / IRQ15 (slave), the top line of each 8259. Set means
// the line is genuinely in-service; clear on a taken IRQ7/15 means it was spurious.
const ISR_TOP_LINE: u8 = 0x80;

/// Read a PIC's In-Service Register (which lines are currently being serviced).
/// Used only to distinguish a real IRQ7/IRQ15 from the 8259's *spurious* interrupt
/// on those lines: the chip raises IRQ7/IRQ15 when a line deasserts before the CPU
/// acknowledges, and for those the corresponding ISR bit is NOT set.
fn readIsr(cmd_port: u16) u8 {
    io.outb(cmd_port, OCW3_READ_ISR);
    return io.inb(cmd_port);
}

/// Whether the just-taken IRQ is a *spurious* 8259 interrupt (a phantom IRQ7 or
/// IRQ15 with no real request behind it), and drive the correct EOI for it. Returns
/// true if spurious — the caller must then NOT run a handler and NOT call `eoi`:
///   - spurious IRQ7 (master): ISR bit 7 clear → no EOI at all (an EOI would dismiss
///     a genuinely in-service master IRQ).
///   - spurious IRQ15 (slave): slave ISR bit 7 clear → EOI the MASTER only, because
///     the master did accept the cascade even though the slave latched nothing.
/// A normal IRQ (or a real IRQ7/15 with the ISR bit set) returns false and is EOI'd
/// normally by the caller.
pub fn spurious(irq: u8) bool {
    if (irq == 7) {
        if ((readIsr(PIC1_CMD) & ISR_TOP_LINE) == 0) return true; // phantom master IRQ7: no EOI
    } else if (irq == 15) {
        if ((readIsr(PIC2_CMD) & ISR_TOP_LINE) == 0) {
            io.outb(PIC1_CMD, EOI); // real cascade, phantom slave: master EOI only
            return true;
        }
    }
    return false;
}

/// Mask (disable) an IRQ line so it no longer reaches the CPU — used when a
/// line's delivery moves to the IO-APIC and the PIC copy must go quiet.
pub fn setMask(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const bit: u3 = @intCast(irq & 7);
    io.outb(port, io.inb(port) | (@as(u8, 1) << bit));
}

/// Unmask (enable) an IRQ line so it can reach the CPU. For a slave line (≥8) the
/// master's cascade line (IRQ2) is also unmasked, since a masked cascade would
/// gate off all slave IRQs.
pub fn clearMask(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const bit: u3 = @intCast(irq & 7);
    io.outb(port, io.inb(port) & ~(@as(u8, 1) << bit));
    if (irq >= 8) {
        // Slave IRQs reach the CPU only if the cascade line (IRQ2) is unmasked.
        io.outb(PIC1_DATA, io.inb(PIC1_DATA) & ~(@as(u8, 1) << 2));
    }
}
