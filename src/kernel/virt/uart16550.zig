//! Emulated 16550 UART (National Semiconductor PC16550D), the guest's serial
//! console at I/O ports 0x3F8–0x3FF. Pure register state machine: the machine
//! model routes guest IN/OUT exits to `ioRead`/`ioWrite`, drains transmitted
//! bytes with `popTx` into the console ring, and feeds keystrokes in with
//! `pushRx`. Host-tested (test/kernel/virt/uart16550_test.zig), including the THRE-interrupt
//! edge quirk that Linux's 8250 driver depends on.
//!
//! Only the register semantics Linux exercises are modeled: DLAB divisor latches
//! (accepted and ignored — timing is irrelevant to an emulated line), IER/IIR/FCR,
//! LCR, MCR, and an LSR that always reports the transmitter empty because we
//! consume TX instantly. Line/modem-status inputs are benign constants.

const RX_CAP: usize = 128;
const TX_CAP: usize = 512;

// Register offsets from the port base (DLAB selects the alternate meaning of 0/1).
const REG_DATA: u3 = 0; // RBR (read) / THR (write) / DLL when DLAB
const REG_IER: u3 = 1; // IER / DLM when DLAB
const REG_IIR_FCR: u3 = 2; // IIR (read) / FCR (write)
const REG_LCR: u3 = 3;
const REG_MCR: u3 = 4;
const REG_LSR: u3 = 5;
const REG_MSR: u3 = 6;
const REG_SCR: u3 = 7;

// IER bits.
const IER_RX_AVAIL: u8 = 1 << 0; // received-data-available interrupt
const IER_THR_EMPTY: u8 = 1 << 1; // transmitter-holding-register-empty interrupt

// IIR interrupt IDs (bits 3:1), with bit 0 = 0 meaning "interrupt pending".
const IIR_NONE: u8 = 0x01; // bit 0 set = no interrupt
const IIR_THR_EMPTY: u8 = 0x02;
const IIR_RX_AVAIL: u8 = 0x04;
const IIR_ID_MASK: u8 = 0x0F; // interrupt-ID field (bits 3:0), below the FIFO-enabled bits
const IIR_FIFO_ENABLED: u8 = 0xC0; // top bits set when FIFO (FCR bit 0) is on

// FCR (FIFO control) bits. Linux's 8250 open path clears the FIFOs on init.
const FCR_CLEAR_RX: u8 = 1 << 1; // flush the receive FIFO
const FCR_CLEAR_TX: u8 = 1 << 2; // flush the transmit FIFO

// LCR / LSR bits.
const LCR_DLAB: u8 = 1 << 7;
const LSR_DATA_READY: u8 = 1 << 0;
const LSR_THR_EMPTY: u8 = 1 << 5;
const LSR_TRANSMITTER_EMPTY: u8 = 1 << 6;

// Modem-status inputs reported as a benign "line up" (16550 datasheet, MSR):
// data-carrier-detect, data-set-ready, and clear-to-send asserted.
const MSR_DCD: u8 = 1 << 7;
const MSR_DSR: u8 = 1 << 5;
const MSR_CTS: u8 = 1 << 4;
const MSR_RI: u8 = 1 << 6;
const MSR_LINE_UP: u8 = MSR_DCD | MSR_DSR | MSR_CTS;

// MCR (modem control) outputs. LOOP is the one that matters here: a driver
// probing for a real 16550 puts the chip in local loopback, drives the outputs,
// and expects to read them back on the modem-status inputs. A port that answers
// with a constant fails that test and is discarded as "not present" — which is
// exactly how a guest ends up booting with no console at all.
const MCR_DTR: u8 = 1 << 0;
const MCR_RTS: u8 = 1 << 1;
const MCR_OUT1: u8 = 1 << 2;
const MCR_OUT2: u8 = 1 << 3;
const MCR_LOOP: u8 = 1 << 4;

pub const Uart = struct {
    ier: u8 = 0,
    lcr: u8 = 0,
    mcr: u8 = 0,
    fcr: u8 = 0,
    scr: u8 = 0,
    dll: u8 = 0,
    dlm: u8 = 0,

    rx: [RX_CAP]u8 = [_]u8{0} ** RX_CAP,
    rx_head: usize = 0,
    rx_tail: usize = 0,
    dropped_rx: u64 = 0,

    tx: [TX_CAP]u8 = [_]u8{0} ** TX_CAP,
    tx_head: usize = 0,
    tx_tail: usize = 0,
    dropped_tx: u64 = 0,

    /// The transmitter-empty interrupt condition. Raised when THR is written (we
    /// empty it instantly) and when the THR-empty interrupt is newly enabled;
    /// cleared by reading IIR while it is the reported source. This edge behavior
    /// is what the 8250 driver's tx path relies on to make progress.
    thre_pending: bool = false,

    fn dlab(self: *const Uart) bool {
        return self.lcr & LCR_DLAB != 0;
    }

    fn rxAvailable(self: *const Uart) bool {
        return self.rx_head != self.rx_tail;
    }

    fn rxPop(self: *Uart) u8 {
        if (!self.rxAvailable()) return 0;
        const b = self.rx[self.rx_head];
        self.rx_head = (self.rx_head + 1) % RX_CAP;
        return b;
    }

    /// The value the guest would read from IIR right now (without side effects).
    fn iirValue(self: *const Uart) u8 {
        var id: u8 = IIR_NONE;
        if (self.ier & IER_RX_AVAIL != 0 and self.rxAvailable()) {
            id = IIR_RX_AVAIL;
        } else if (self.ier & IER_THR_EMPTY != 0 and self.thre_pending) {
            id = IIR_THR_EMPTY;
        }
        if (self.fcr & 1 != 0) id |= IIR_FIFO_ENABLED;
        return id;
    }

    /// Handle a guest IN from `off` (port − base). Returns the byte read.
    pub fn ioRead(self: *Uart, off: u3) u8 {
        return switch (off) {
            REG_DATA => if (self.dlab()) self.dll else self.rxPop(),
            REG_IER => if (self.dlab()) self.dlm else self.ier,
            REG_IIR_FCR => blk: {
                const v = self.iirValue();
                // Reading IIR while THRE is the source clears that condition.
                if (v & IIR_ID_MASK == IIR_THR_EMPTY) self.thre_pending = false;
                break :blk v;
            },
            REG_LCR => self.lcr,
            REG_MCR => self.mcr,
            REG_LSR => blk: {
                var lsr: u8 = LSR_THR_EMPTY | LSR_TRANSMITTER_EMPTY;
                if (self.rxAvailable()) lsr |= LSR_DATA_READY;
                break :blk lsr;
            },
            REG_MSR => if (self.mcr & MCR_LOOP != 0) loopbackMsr(self.mcr) else MSR_LINE_UP,
            REG_SCR => self.scr,
        };
    }

    /// Handle a guest OUT to `off` (port − base) with `val`.
    pub fn ioWrite(self: *Uart, off: u3, val: u8) void {
        switch (off) {
            REG_DATA => {
                if (self.dlab()) {
                    self.dll = val;
                } else {
                    self.txPush(val);
                    self.thre_pending = true; // THR emptied immediately
                }
            },
            REG_IER => {
                if (self.dlab()) {
                    self.dlm = val;
                } else {
                    const newly_enabled_thre = (val & IER_THR_EMPTY != 0) and (self.ier & IER_THR_EMPTY == 0);
                    self.ier = val;
                    if (newly_enabled_thre) self.thre_pending = true;
                }
            },
            REG_IIR_FCR => {
                self.fcr = val;
                // FIFO-clear bits flush the rings so a driver re-init does not
                // deliver bytes queued before it opened the port.
                if (val & FCR_CLEAR_RX != 0) self.rx_head = self.rx_tail;
                if (val & FCR_CLEAR_TX != 0) self.tx_head = self.tx_tail;
            },
            REG_LCR => self.lcr = val,
            REG_MCR => self.mcr = val,
            REG_LSR, REG_MSR => {}, // status registers ignore writes
            REG_SCR => self.scr = val,
        }
    }

    fn txPush(self: *Uart, b: u8) void {
        const next = (self.tx_tail + 1) % TX_CAP;
        if (next == self.tx_head) {
            self.dropped_tx += 1; // console not draining fast enough — counted, never blocked
            return;
        }
        self.tx[self.tx_tail] = b;
        self.tx_tail = next;
    }

    /// Pop one transmitted byte for the console glue, or null when the TX ring is
    /// empty.
    /// The modem-status inputs a 16550 reports while in local loopback: each of
    /// the four control outputs is wired back to the input that mirrors it
    /// (16550 datasheet, MCR bit 4). A driver's presence test writes
    /// RTS + OUT2 and expects CTS + DCD to come back.
    fn loopbackMsr(mcr: u8) u8 {
        var msr: u8 = 0;
        if (mcr & MCR_RTS != 0) msr |= MSR_CTS;
        if (mcr & MCR_DTR != 0) msr |= MSR_DSR;
        if (mcr & MCR_OUT1 != 0) msr |= MSR_RI;
        if (mcr & MCR_OUT2 != 0) msr |= MSR_DCD;
        return msr;
    }

    pub fn popTx(self: *Uart) ?u8 {
        if (self.tx_head == self.tx_tail) return null;
        const b = self.tx[self.tx_head];
        self.tx_head = (self.tx_head + 1) % TX_CAP;
        return b;
    }

    /// Feed a received byte (a keystroke). Returns false and counts the drop when
    /// the RX ring is full.
    pub fn pushRx(self: *Uart, b: u8) bool {
        const next = (self.rx_tail + 1) % RX_CAP;
        if (next == self.rx_head) {
            self.dropped_rx += 1;
            return false;
        }
        self.rx[self.rx_tail] = b;
        self.rx_tail = next;
        return true;
    }

    /// The current interrupt-request level: true when an enabled interrupt source
    /// is asserting. The machine model samples this to drive IRQ 4 into the PIC.
    pub fn irqLevel(self: *const Uart) bool {
        return (self.ier & IER_RX_AVAIL != 0 and self.rxAvailable()) or
            (self.ier & IER_THR_EMPTY != 0 and self.thre_pending);
    }
};
