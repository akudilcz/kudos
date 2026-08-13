//! Intel e1000 (82540EM) NIC driver. Polled RX/TX rings;
//! interrupts are masked — the network stack pumps RX from the main path. The
//! DMA-ring/send/poll machinery is shared with the modern Intel driver via
//! intel.Nic; this file owns only the e1000's register map, its legacy descriptor
//! layout, and its (simple) bring-up.

const pci = @import("../../pci/pci.zig");
const intel = @import("intel.zig");

const N_RX = intel.N_RX;
const N_TX = intel.N_TX;
const BUF = intel.BUF;

// Register offsets (bytes into BAR0 MMIO).
// Offsets shared with the modern controllers live once in intel.zig.
const CTRL = intel.CTRL;
const STATUS = intel.STATUS;
const IMC = intel.IMC;
const RCTL = intel.RCTL;
const TCTL = intel.TCTL;
const TIPG = 0x0410;
const RDBAL = 0x2800;
const RDBAH = 0x2804;
const RDLEN = 0x2808;
const RDH = 0x2810;
const RDT = 0x2818;
const TDBAL = 0x3800;
const TDBAH = 0x3804;
const TDLEN = 0x3808;
const TDH = 0x3810;
const TDT = 0x3818;
const RAL0 = intel.RAL0;
const RAH0 = intel.RAH0;
const MTA = 0x5200;

// Legacy descriptor layouts.
const RxDesc = extern struct {
    addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};
const TxDesc = extern struct {
    addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

var nic: intel.Nic = .{};

// --- descriptor ops (the e1000 legacy encoding) ----------------------------

/// Pointer to RX descriptor `i` in the ring at `ring` (legacy 16-byte layout).
fn rxAt(ring: usize, i: usize) *volatile RxDesc {
    return @ptrFromInt(ring + i * @sizeOf(RxDesc));
}
/// Pointer to TX descriptor `i` in the ring at `ring` (legacy 16-byte layout).
fn txAt(ring: usize, i: usize) *volatile TxDesc {
    return @ptrFromInt(ring + i * @sizeOf(TxDesc));
}

/// intel.DescOps.tx_set: encode TX descriptor `i` for a `len`-byte frame at
/// `buf_phys`, arming end-of-packet, insert-FCS, and report-status.
fn txSet(ring: usize, i: usize, buf_phys: u64, len: usize) void {
    const d = txAt(ring, i);
    d.addr = buf_phys;
    d.length = @intCast(len);
    d.status = 0;
    d.cmd = 0x1 | 0x2 | 0x8; // EOP | IFCS | RS
}
/// intel.DescOps.tx_done: true once the NIC has written back TX descriptor `i`.
fn txDone(ring: usize, i: usize) bool {
    return (txAt(ring, i).status & 0x0F) != 0; // any status nibble bit (incl. DD)
}
/// intel.DescOps.rx_len: received length of RX descriptor `i` if DD is set, else null.
fn rxLen(ring: usize, i: usize) ?usize {
    const d = rxAt(ring, i);
    if (d.status & 0x1 == 0) return null; // DD not set
    return d.length;
}
/// intel.DescOps.rx_reset: return RX descriptor `i` to the empty/read format at `buf_phys`.
fn rxReset(ring: usize, i: usize, buf_phys: u64) void {
    const d = rxAt(ring, i);
    d.addr = buf_phys;
    d.status = 0;
}

const OPS: intel.DescOps = .{ .tx_set = txSet, .tx_done = txDone, .rx_len = rxLen, .rx_reset = rxReset };

/// Roll back a partial bring-up: quiesce both DMA engines FIRST (the receiver
/// is enabled before the TX allocations, so on a TX failure it is already
/// live, writing into buffers about to be returned), then free every
/// ring/buffer taken so far (dmaFree skips never-allocated 0 slots). Returns
/// false so init's failure paths read as one expression.
fn initFail() bool {
    nic.write(RCTL, 0);
    nic.write(TCTL, 0);
    intel.dmaFree(nic.rx_ring, N_RX * @sizeOf(RxDesc));
    intel.dmaFree(nic.rx_buf, N_RX * BUF);
    intel.dmaFree(nic.tx_ring, N_TX * @sizeOf(TxDesc));
    intel.dmaFree(nic.tx_buf, N_TX * BUF);
    nic = .{};
    return false;
}

// --- public driver surface -------------------------------------------------

/// nic.Driver.macAddr: this controller's MAC.
pub fn macAddr() [6]u8 {
    return nic.macAddr();
}
/// nic.Driver.send: transmit one Ethernet frame.
pub fn send(frame: []const u8) void {
    nic.send(frame);
}
/// nic.Driver.poll: next received frame, or null.
pub fn poll() ?[]const u8 {
    return nic.poll();
}
/// nic.Driver.linkUp: STATUS.LU — the PHY reports link.
pub fn linkUp() bool {
    return nic.read(STATUS) & intel.STATUS_LU != 0;
}

/// Find and initialize the e1000. Returns false if no NIC is present.
pub fn init() bool {
    const dev = pci.findByIds(0x8086, 0x100E) orelse return false;
    nic = .{ .regs = .{ .rdt = RDT, .tdt = TDT, .tdh = TDH }, .ops = OPS };
    intel.registerCounters();
    // Use bar64 (masks the flag bits internally, same as igc) rather than a
    // 32-bit `bar(0) & ~0xF`: a 64-bit-BAR e1000 variant would otherwise
    // truncate the base. QEMU's 82540 is 32-bit so this was latent, but the
    // single-source rule wants both Intel drivers reading the BAR the same way.
    nic.mmio = @intCast(pci.bar64(dev, 0));
    dev.enableBusMaster();
    nic.write(IMC, 0xFFFFFFFF); // mask all NIC interrupts (we poll)

    nic.mac = intel.macFromRegs(nic.read(RAL0), nic.read(RAH0));

    var i: usize = 0;
    while (i < 128) : (i += 1) nic.write(MTA + i * 4, 0); // clear multicast filter

    // RX ring + buffers. Out of contiguous DMA memory fails loudly back to
    // nic.init, unwinding whatever this bring-up already took.
    nic.rx_ring = intel.dmaAlloc(N_RX * @sizeOf(RxDesc)) orelse return initFail();
    nic.rx_buf = intel.dmaAlloc(N_RX * BUF) orelse return initFail();
    i = 0;
    while (i < N_RX) : (i += 1) rxAt(nic.rx_ring, i).* = .{ .addr = nic.rx_buf + i * BUF, .length = 0, .checksum = 0, .status = 0, .errors = 0, .special = 0 };
    nic.write(RDBAL, @truncate(nic.rx_ring));
    nic.write(RDBAH, @truncate(nic.rx_ring >> 32));
    nic.write(RDLEN, N_RX * @sizeOf(RxDesc));
    nic.write(RDH, 0);
    // EN | BAM | UPE | MPE | SECRC, BSIZE=2048 (the BSIZE bits are zero).
    // Enable the receiver BEFORE handing it
    // descriptors: RDT is written LAST, as the "go" signal, matching Linux
    // e1000_configure() (rctl setup first, the RDT write is the final step of
    // e1000_alloc_rx_buffers). Order matters on QEMU: an inbound frame that
    // arrives while RX is disabled parks in the netdev queue, and only the RDT
    // write flushes that queue — writing RDT while EN was still 0 made that
    // flush a no-op and every later frame queued behind the parked one forever
    // (DHCP OFFERs included; the no-OFFER hang this order fixes).
    nic.write(RCTL, intel.RCTL_EN | intel.RCTL_UPE | intel.RCTL_MPE | intel.RCTL_BAM | intel.RCTL_SECRC);
    nic.write(RDT, N_RX - 1);

    // TX ring + buffers. The receiver is already enabled — a failure here must
    // unwind through initFail so it is not left DMA-ing into freed buffers.
    nic.tx_ring = intel.dmaAlloc(N_TX * @sizeOf(TxDesc)) orelse return initFail();
    nic.tx_buf = intel.dmaAlloc(N_TX * BUF) orelse return initFail();
    i = 0;
    while (i < N_TX) : (i += 1) txAt(nic.tx_ring, i).* = .{ .addr = nic.tx_buf + i * BUF, .length = 0, .cso = 0, .cmd = 0, .status = 1, .css = 0, .special = 0 };
    nic.write(TDBAL, @truncate(nic.tx_ring));
    nic.write(TDBAH, @truncate(nic.tx_ring >> 32));
    nic.write(TDLEN, N_TX * @sizeOf(TxDesc));
    nic.write(TDH, 0);
    nic.write(TDT, 0);
    nic.write(TIPG, 0x0060200A);
    // EN | PSP | CT=0x0F | COLD=0x3F
    nic.write(TCTL, 0x2 | 0x8 | (0x0F << 4) | (0x3F << 12));

    return true;
}

/// nic.Driver.txDropped: frames dropped on a full/unreclaimable TX ring.
pub fn txDropped() u64 {
    return nic.tx_dropped;
}
