//! Emulated pair of 8259A programmable interrupt controllers (Intel 8259A
//! datasheet), the guest's legacy PICs at I/O ports 0x20/0x21 (master) and
//! 0xA0/0xA1 (slave). Pure register state machine: the machine model routes
//! guest IN/OUT exits to `ioRead`/`ioWrite`, drives device lines with
//! `raise`/`lower`, and pulls vectors with `ack` when the vCPU opens an
//! interrupt window. Host-tested (test/kernel/virt/i8259_test.zig).
//!
//! The guest runs virtual-wire mode: the master's INT output feeds the local
//! APIC's LINT0 as ExtINT, and the only line that matters is the serial UART
//! on IRQ 4 (plus the IRQ 2 cascade that slave lines 8–15 arrive through).
//! Modeled: the ICW1–ICW4 initialization sequence, OCW1 (interrupt mask),
//! OCW2 EOIs (specific and non-specific), OCW3 IRR/ISR read-back, and fully
//! nested priority where a lower IRQ number outranks a higher one. Timing
//! modes, rotation, and poll mode are not — Linux never uses them here.

const MASTER_COMMAND_PORT: u16 = 0x20;
const MASTER_DATA_PORT: u16 = 0x21;
const SLAVE_COMMAND_PORT: u16 = 0xA0;
const SLAVE_DATA_PORT: u16 = 0xA1;

// ICW1 (Initialization Command Word 1) is any command-port write with bit 4
// set; it restarts the initialization sequence (8259A datasheet, Figure 6).
const ICW1_SELECT: u8 = 1 << 4;
const ICW1_ICW4_NEEDED: u8 = 1 << 0; // IC4: an ICW4 write will follow
const ICW1_SINGLE_MODE: u8 = 1 << 1; // SNGL: no cascade, so no ICW3
// ICW2 carries the vector base in bits 7:3; bits 2:0 are the IRQ number.
const ICW2_BASE_MASK: u8 = 0xF8;

// OCW2/OCW3 share the command port with ICW1: bit 4 clear selects an OCW,
// and bit 3 then distinguishes OCW3 (set) from OCW2 (clear).
const OCW3_SELECT: u8 = 1 << 3;
const OCW3_READ_REGISTER: u8 = 1 << 1; // RR: bits 1:0 = 10 read IRR, 11 read ISR
const OCW3_READ_ISR: u8 = 1 << 0;
const OCW2_COMMAND_MASK: u8 = 0xE0; // bits 7:5 = R / SL / EOI
const OCW2_EOI_NONSPECIFIC: u8 = 0x20; // clear the highest-priority in-service bit
const OCW2_EOI_SPECIFIC: u8 = 0x60; // clear the in-service bit named in bits 2:0
const OCW2_LEVEL_MASK: u8 = 0x07;

/// The master line the slave's INT output is wired to on every PC.
const CASCADE_IRQ: u3 = 2;

const InitState = enum { ready, expect_icw2, expect_icw3, expect_icw4 };

fn irqBit(irq: u3) u8 {
    return @as(u8, 1) << irq;
}

/// One 8259A. Kept private: the pair is the device the guest sees, and tests
/// observe each half through OCW3 read-back like the guest does.
const Pic = struct {
    /// Interrupt request register: lines currently asserted and latched.
    irr: u8 = 0,
    /// In-service register: acknowledged interrupts awaiting their EOI.
    isr: u8 = 0,
    /// Interrupt mask register (OCW1). Everything is masked until the guest
    /// programs the chip; ICW1 clears it as the datasheet specifies.
    imr: u8 = 0xFF,
    /// Vector base from ICW2; `ack` returns base + IRQ number.
    base: u8 = 0,
    init_state: InitState = .ready,
    icw4_needed: bool = false,
    single_mode: bool = false,
    /// OCW3 read selector: the next command-port read returns ISR when set,
    /// IRR otherwise (the power-on default).
    read_isr: bool = false,

    fn commandWrite(self: *Pic, val: u8) void {
        if (val & ICW1_SELECT != 0) {
            // ICW1 resets the chip: request state and mask are cleared and
            // the sequence continues with ICW2 on the data port.
            self.icw4_needed = val & ICW1_ICW4_NEEDED != 0;
            self.single_mode = val & ICW1_SINGLE_MODE != 0;
            self.irr = 0;
            self.isr = 0;
            self.imr = 0;
            self.read_isr = false;
            self.init_state = .expect_icw2;
        } else if (val & OCW3_SELECT != 0) {
            if (val & OCW3_READ_REGISTER != 0) self.read_isr = val & OCW3_READ_ISR != 0;
        } else switch (val & OCW2_COMMAND_MASK) {
            OCW2_EOI_NONSPECIFIC => self.eoiHighest(),
            OCW2_EOI_SPECIFIC => self.isr &= ~irqBit(@intCast(val & OCW2_LEVEL_MASK)),
            else => {}, // rotation and no-op commands — unused by the guest
        }
    }

    fn dataWrite(self: *Pic, val: u8) void {
        switch (self.init_state) {
            .expect_icw2 => {
                self.base = val & ICW2_BASE_MASK;
                if (self.single_mode) {
                    self.init_state = if (self.icw4_needed) .expect_icw4 else .ready;
                } else {
                    self.init_state = .expect_icw3;
                }
            },
            // ICW3 names the cascade wiring, which this model fixes at IRQ 2;
            // ICW4 selects 8086 mode, the only mode modeled. Both are
            // accepted purely to advance the sequence.
            .expect_icw3 => self.init_state = if (self.icw4_needed) .expect_icw4 else .ready,
            .expect_icw4 => self.init_state = .ready,
            .ready => self.imr = val, // OCW1
        }
    }

    fn commandRead(self: *const Pic) u8 {
        return if (self.read_isr) self.isr else self.irr;
    }

    /// The highest-priority serviceable request: unmasked, requested, and not
    /// outranked by an in-service interrupt (fully nested mode — a lower IRQ
    /// number is a higher priority, and an in-service bit blocks its own line
    /// and everything below it until EOI).
    fn highestPending(self: *const Pic) ?u3 {
        const pending = self.irr & ~self.imr;
        var irq: u3 = 0;
        while (true) : (irq += 1) {
            const bit = irqBit(irq);
            if (self.isr & bit != 0) return null;
            if (pending & bit != 0) return irq;
            if (irq == 7) return null;
        }
    }

    fn eoiHighest(self: *Pic) void {
        var irq: u3 = 0;
        while (true) : (irq += 1) {
            const bit = irqBit(irq);
            if (self.isr & bit != 0) {
                self.isr &= ~bit;
                return;
            }
            if (irq == 7) return;
        }
    }
};

/// Whether `port` is one of the four PIC command/data ports, so the machine
/// model routes it here rather than restating the port numbers.
pub fn owns(port: u16) bool {
    return switch (port) {
        MASTER_COMMAND_PORT, MASTER_DATA_PORT, SLAVE_COMMAND_PORT, SLAVE_DATA_PORT => true,
        else => false,
    };
}

pub const PicPair = struct {
    master: Pic = .{},
    slave: Pic = .{},

    /// Handle a guest OUT to one of the four PIC ports. Writes to other ports
    /// are not routed here by the machine model.
    pub fn ioWrite(self: *PicPair, port: u16, val: u8) void {
        switch (port) {
            MASTER_COMMAND_PORT => self.master.commandWrite(val),
            MASTER_DATA_PORT => self.master.dataWrite(val),
            SLAVE_COMMAND_PORT => self.slave.commandWrite(val),
            SLAVE_DATA_PORT => self.slave.dataWrite(val),
            else => {},
        }
        self.updateCascade();
    }

    /// Handle a guest IN from one of the four PIC ports: the mask from a data
    /// port, IRR or ISR (per the last OCW3) from a command port.
    pub fn ioRead(self: *PicPair, port: u16) u8 {
        return switch (port) {
            MASTER_COMMAND_PORT => self.master.commandRead(),
            MASTER_DATA_PORT => self.master.imr,
            SLAVE_COMMAND_PORT => self.slave.commandRead(),
            SLAVE_DATA_PORT => self.slave.imr,
            else => 0xFF, // open bus
        };
    }

    /// A device asserts line `irq` (0–7 master, 8–15 slave).
    pub fn raise(self: *PicPair, irq: u4) void {
        if (irq < 8) {
            self.master.irr |= irqBit(@intCast(irq));
        } else {
            self.slave.irr |= irqBit(@intCast(irq - 8));
        }
        self.updateCascade();
    }

    /// A device deasserts line `irq` before it was acknowledged.
    pub fn lower(self: *PicPair, irq: u4) void {
        if (irq < 8) {
            self.master.irr &= ~irqBit(@intCast(irq));
        } else {
            self.slave.irr &= ~irqBit(@intCast(irq - 8));
        }
        self.updateCascade();
    }

    /// Master IRR bit 2 mirrors the slave's INT output: the cascade line is
    /// owned by the slave, never by `raise`/`lower` directly.
    fn updateCascade(self: *PicPair) void {
        if (self.slave.highestPending() != null) {
            self.master.irr |= irqBit(CASCADE_IRQ);
        } else {
            self.master.irr &= ~irqBit(CASCADE_IRQ);
        }
    }

    /// The vector `ack` would return, without acknowledging it: no IRR→ISR move,
    /// no state change. The machine model offers this to the local APIC as the
    /// candidate ExtINT vector before the vCPU commits to injecting it, so a
    /// vector that loses arbitration (or that the guest cannot take yet) is not
    /// consumed and lost. Null when nothing is serviceable.
    pub fn peek(self: *const PicPair) ?u8 {
        const master_irq = self.master.highestPending() orelse return null;
        if (master_irq == CASCADE_IRQ and !self.master.single_mode) {
            const slave_irq = self.slave.highestPending() orelse return null;
            return self.slave.base + @as(u8, slave_irq);
        }
        return self.master.base + @as(u8, master_irq);
    }

    /// Acknowledge the highest-priority serviceable request, as the INTA cycle
    /// would: latch it into ISR, drop it from IRR, and return its vector
    /// (ICW2 base + IRQ number, resolved through the slave when the winning
    /// master line is the cascade). Null when nothing is serviceable.
    pub fn ack(self: *PicPair) ?u8 {
        const master_irq = self.master.highestPending() orelse return null;
        if (master_irq == CASCADE_IRQ and !self.master.single_mode) {
            const slave_irq = self.slave.highestPending() orelse {
                self.updateCascade(); // stale cascade bit — drop it, no vector
                return null;
            };
            self.slave.irr &= ~irqBit(slave_irq);
            self.slave.isr |= irqBit(slave_irq);
            self.master.isr |= irqBit(CASCADE_IRQ);
            self.updateCascade();
            return self.slave.base + @as(u8, slave_irq);
        }
        self.master.irr &= ~irqBit(master_irq);
        self.master.isr |= irqBit(master_irq);
        return self.master.base + @as(u8, master_irq);
    }
};
