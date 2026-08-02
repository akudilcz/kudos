//! Modern Intel Ethernet driver: igb (82576, QEMU
//! `-device igb`) and igc / I225 / I226 (the real target NIC, 8086:125c). These
//! share the **advanced descriptor** model and a register map distinct from the
//! e1000. The DMA-ring/send/poll machinery is shared with the e1000 via intel.Nic;
//! this file owns the advanced-descriptor encoding and the (involved) bring-up
//! (reset + PHY autonegotiation + per-queue SRRCTL/RXDCTL/TXDCTL). Tested against
//! QEMU igb as the closest proxy for the I226 (which QEMU does not emulate).

const pci = @import("../../pci/pci.zig");
const klog = @import("../../../kernel/debug/klog.zig");
const gate = @import("../../../kernel/debug/gate.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const wait = @import("../../io/wait.zig");
const intel = @import("intel.zig");
const igc_desc = @import("igc_desc.zig");

const N_RX = intel.N_RX;
const N_TX = intel.N_TX;
const BUF = intel.BUF;

// Registers. Offsets shared with e1000 live once in intel.zig (single owner).
const CTRL = intel.CTRL;
const STATUS = intel.STATUS;
// Legacy interrupt-mask-clear lives at different offsets per chip: igb/e1000 at
// 0x000D8 (intel.IMC) vs igc/I225/I226 at 0x0150C (Linux igc igc_regs.h IGC_IMC).
// We mask both — see maskAllInterrupts. EIMC is shared.
const IMC_IGB = intel.IMC;
const IMC_IGC = 0x0150C; // igc/I226-only second IMC
const EIMC = 0x1528;
const RCTL = intel.RCTL;
const TCTL = intel.TCTL;
const RAL0 = intel.RAL0;
const RAH0 = intel.RAH0;
const MDIC = 0x0020;
const PHY_ADDR = 1; // internal PHY (igb/igc)

// Standard MII PHY registers.
const MII_BMCR = 0; // basic control: bit12 AUTOEN, bit9 ANRESTART
const MII_BMSR = 1; // basic status: bit5 AN_COMP, bit2 LINK
// Per-queue 0.
const RDBAL = 0xC000;
const RDBAH = 0xC004;
const RDLEN = 0xC008;
const SRRCTL = 0xC00C;
const RDH = 0xC010;
const RDT = 0xC018;
const RXDCTL = 0xC028;
const TDBAL = 0xE000;
const TDBAH = 0xE004;
const TDLEN = 0xE008;
const TDH = 0xE010;
const TDT = 0xE018;
const TXDCTL = 0xE028;

const CTRL_SLU = 1 << 6;
const CTRL_RST = 1 << 26;

// Busy-spin settle after asserting CTRL.RST, before polling CTRL.RST for clear.
// The datasheet requires a delay for the reset to propagate; this bounded spin
// gives it time on both QEMU and real I226 silicon.
const RESET_SETTLE_SPINS = 200000;

// The ENCODING lives in igc_desc.zig — pure and host-tested, because QEMU never runs
// this driver at all (the emulated NIC is an e1000, which takes the legacy path), so
// the bit layout below has zero coverage from any emulated boot. A regression in it
// means no packets, which means no netdebug, which means no way to see why there are
// no packets. This file keeps only the volatile load/store.
const AdvDesc = igc_desc.AdvDesc;

var nic: intel.Nic = .{};

/// Pointer to advanced descriptor `i` in the ring at `ring` (16-byte, 4×u32).
fn descAt(ring: usize, i: usize) *volatile AdvDesc {
    return @ptrFromInt(ring + i * @sizeOf(AdvDesc));
}

// --- descriptor ops: the volatile shell over igc_desc's pure encoding ---------

/// intel.DescOps.tx_set: encode the advanced-data TX descriptor `i` for a
/// `len`-byte frame at `buf_phys`.
fn txSet(ring: usize, i: usize, buf_phys: u64, len: usize) void {
    descAt(ring, i).* = igc_desc.txSet(buf_phys, len);
}
/// intel.DescOps.tx_done: true once the NIC has written back TX descriptor `i`.
fn txDone(ring: usize, i: usize) bool {
    return igc_desc.txDone(descAt(ring, i).*);
}
/// intel.DescOps.rx_len: received length of RX descriptor `i` if DD is set, else null.
fn rxLen(ring: usize, i: usize) ?usize {
    return igc_desc.rxLen(descAt(ring, i).*);
}
/// intel.DescOps.rx_reset: return RX descriptor `i` to the empty/read format at `buf_phys`.
fn rxReset(ring: usize, i: usize, buf_phys: u64) void {
    descAt(ring, i).* = igc_desc.rxReset(buf_phys);
}

const OPS: intel.DescOps = .{ .tx_set = txSet, .tx_done = txDone, .rx_len = rxLen, .rx_reset = rxReset };

// --- chip-specific bring-up helpers ----------------------------------------

/// Busy-wait `n` PAUSE iterations — a coarse post-reset settle delay where the
/// register poll below has nothing to observe yet.
fn spin(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) asm volatile ("pause");
}
/// Mask all interrupts on both igb and igc. The IMC offset differs per chip; a
/// write to the unimplemented offset on either chip is harmless, so we hit both
/// plus the shared EIMC and avoid a device-ID branch.
fn maskAllInterrupts() void {
    nic.write(IMC_IGB, 0xFFFFFFFF);
    nic.write(IMC_IGC, 0xFFFFFFFF);
    nic.write(EIMC, 0xFFFFFFFF);
}

const REG_WAIT_SPINS = intel.WAIT_SPINS;
/// wait.until predicate: MDIC transaction complete (MDIC.READY, bit 28).
fn mdicReady(_: void) bool {
    return (nic.read(MDIC) & (1 << 28)) != 0;
}
/// wait.until predicate: device reset has finished (CTRL.RST self-cleared).
fn rstClear(_: void) bool {
    return (nic.read(CTRL) & CTRL_RST) == 0;
}
/// wait.until predicate: TX queue 0 is live (TXDCTL.ENABLE, bit 25).
fn txdctlEnabled(_: void) bool {
    return (nic.read(TXDCTL) & (1 << 25)) != 0;
}
/// wait.until predicate: RX queue 0 is live (RXDCTL.ENABLE, bit 25).
fn rxdctlEnabled(_: void) bool {
    return (nic.read(RXDCTL) & (1 << 25)) != 0;
}
/// wait.until predicate: RX queue 0 has quiesced (RXDCTL.ENABLE clear).
fn rxdctlDisabled(_: void) bool {
    return (nic.read(RXDCTL) & (1 << 25)) == 0;
}

/// Write `data` to internal-PHY register `reg` over MDIO, then wait for the
/// transaction to complete (MDIC OP=write).
fn mdicWrite(reg: u32, data: u16) void {
    nic.write(MDIC, @as(u32, data) | (reg << 16) | (PHY_ADDR << 21) | (1 << 26)); // OP=write
    _ = wait.until({}, mdicReady, wait.noop, REG_WAIT_SPINS, "igc: MDIC ready (write)");
}
/// Read internal-PHY register `reg` over MDIO (MDIC OP=read), returning its value.
fn mdicRead(reg: u32) u16 {
    nic.write(MDIC, (reg << 16) | (PHY_ADDR << 21) | (2 << 26)); // OP=read
    _ = wait.until({}, mdicReady, wait.noop, REG_WAIT_SPINS, "igc: MDIC ready (read)");
    return @truncate(nic.read(MDIC));
}

/// Find a modern Intel Ethernet controller (Intel, class 02/00, not the e1000).
fn find() ?pci.Device {
    for (pci.list()) |d| {
        if (d.vendor == 0x8086 and d.class == 0x02 and d.subclass == 0x00 and d.device != 0x100E) {
            return d;
        }
    }
    return null;
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

/// Find, reset, and bring up a modern Intel controller: PHY autonegotiation for
/// link, then per-queue RX/TX ring setup. Returns false if none is present or a
/// DMA allocation fails.
pub fn init() bool {
    const dev = find() orelse return false;
    nic = .{ .regs = .{ .rdt = RDT, .tdt = TDT, .tdh = TDH }, .ops = OPS };
    dev.enableBusMaster();
    nic.mmio = @intCast(pci.bar64(dev, 0));
    if (nic.mmio == 0) return false;

    // Mask interrupts, reset, mask again.
    maskAllInterrupts();
    if (gate.on(.net)) {
        klog.puts("igc: STATUS before reset=");
        klog.putHex(nic.read(STATUS));
        klog.putc('\n');
    }
    nic.write(CTRL, nic.read(CTRL) | CTRL_RST);
    spin(RESET_SETTLE_SPINS);
    _ = wait.until({}, rstClear, wait.noop, REG_WAIT_SPINS, "igc: reset complete (CTRL.RST clear)");
    maskAllInterrupts();
    nic.write(CTRL, nic.read(CTRL) | CTRL_SLU); // set link up

    // Start the link via PHY autonegotiation (the reset cleared it) and DO NOT
    // wait for STATUS.LU — Linux's igc_probe never blocks on link either (the
    // watchdog handles it async). Autoneg takes ~1.5-2.5 s on a real PHY, and
    // blocking here serialized up to 3 s into every native boot for nothing:
    // both RX consumers tolerate a late link (netdebug.drain gates on live
    // linkUp() + a settle window via pathProven; DHCP starts ~1 s later on the
    // boot path with a 3×2 s DISCOVER retry budget that absorbs the remaining
    // autoneg time): link comes up via autonegotiation.
    const bmcr = mdicRead(MII_BMCR);
    mdicWrite(MII_BMCR, bmcr | (1 << 12) | (1 << 9)); // AUTOEN | ANRESTART
    if (gate.on(.net)) {
        klog.puts("igc: autoneg restarted (link comes up async), STATUS=");
        klog.putHex(nic.read(STATUS));
        klog.putc('\n');
    }

    nic.mac = intel.macFromRegs(nic.read(RAL0), nic.read(RAH0));

    // RX ring (advanced descriptors) + buffers.
    nic.rx_ring = intel.dmaAlloc(N_RX * @sizeOf(AdvDesc));
    nic.rx_buf = intel.dmaAlloc(N_RX * BUF);
    if (nic.rx_ring == 0 or nic.rx_buf == 0) return false;
    var i: usize = 0;
    while (i < N_RX) : (i += 1) rxReset(nic.rx_ring, i, nic.rx_buf + i * BUF);
    // RX queue setup, matching the Linux igc driver order (igc_configure_rx_ring
    // + igc_setup_rctl): disable queue, set ring, init head/tail, SRRCTL, then
    // enable the queue; global RCTL last; finally hand the descriptors over.
    nic.write(RXDCTL, 0); // disable queue while configuring
    // Wait for the queue to quiesce before reprogramming the ring base/length —
    // on the real I226 reprogramming a still-enabled queue leaves it fetching a
    // stale descriptor base. Mirrors the TX enable poll (txdctlEnabled).
    _ = wait.until({}, rxdctlDisabled, wait.noop, REG_WAIT_SPINS, "igc: RX queue disable (RXDCTL.ENABLE clear)");
    nic.write(RDBAL, @truncate(nic.rx_ring));
    nic.write(RDBAH, @truncate(nic.rx_ring >> 32));
    nic.write(RDLEN, N_RX * @sizeOf(AdvDesc));
    nic.write(RDH, 0);
    nic.write(RDT, 0);
    // SRRCTL: BSIZEPACKET=2 (2KB, 1KB units) | DESCTYPE = advanced one-buffer.
    nic.write(SRRCTL, 2 | (1 << 25));
    // RXDCTL: PTHRESH=8 | HTHRESH=8<<8 | WTHRESH=0 | QUEUE_ENABLE(bit25).
    // WTHRESH MUST be 0 on this driver: kudos POLLS the DD bit with all NIC
    // interrupts masked, and a nonzero write-back threshold lets the I226
    // defer descriptor write-back until WTHRESH descriptors accumulate — a
    // lone datagram on a quiet LAN (a KMR1 request, an ARP reply) then sits
    // received-but-invisible with nothing to flush it. Linux's 8/8/4 values
    // assume interrupt-driven flushes kudos does not have. QEMU's e1000 model
    // writes DD back per-packet, so only real silicon showed this.
    nic.write(RXDCTL, 8 | (8 << 8) | (0 << 16) | (1 << 25));
    // Confirm the queue actually enabled before arming it (mirrors the TX poll);
    // on the real I226 an un-polled enable can leave RX silently dead.
    _ = wait.until({}, rxdctlEnabled, wait.noop, REG_WAIT_SPINS, "igc: RX queue enable (RXDCTL.ENABLE)");
    // RCTL: EN | UPE | BAM | SECRC. LPE (bit5, long-packet enable) is deliberately
    // OMITTED: RX buffers are a single 2KB descriptor each (SRRCTL BSIZEPACKET=2),
    // so a >2048B frame would be reported at its full length and the shared
    // intel.Nic.poll would @memcpy it out of a 2KB buffer -> overrun. Jumbo frames
    // are out of scope; the e1000 path omits LPE for the same
    // reason and is safe.
    nic.write(RCTL, (1 << 1) | (1 << 3) | (1 << 15) | (1 << 26));
    nic.write(RDT, N_RX - 1); // hand all descriptors to the controller
    if (gate.on(.net)) {
        klog.puts("igc: STATUS=");
        klog.putHex(nic.read(STATUS));
        klog.puts(" RCTL=");
        klog.putHex(nic.read(RCTL));
        klog.puts(" RXDCTL=");
        klog.putHex(nic.read(RXDCTL));
        klog.putc('\n');
    }

    // TX ring + buffers.
    nic.tx_ring = intel.dmaAlloc(N_TX * @sizeOf(AdvDesc));
    nic.tx_buf = intel.dmaAlloc(N_TX * BUF);
    if (nic.tx_ring == 0 or nic.tx_buf == 0) return false;
    nic.write(TDBAL, @truncate(nic.tx_ring));
    nic.write(TDBAH, @truncate(nic.tx_ring >> 32));
    nic.write(TDLEN, N_TX * @sizeOf(AdvDesc));
    nic.write(TDH, 0);
    nic.write(TDT, 0);
    nic.write(TXDCTL, (1 << 25) | (1 << 16)); // ENABLE | WTHRESH=1
    _ = wait.until({}, txdctlEnabled, wait.noop, REG_WAIT_SPINS, "igc: TX queue enable (TXDCTL.ENABLE)");
    nic.write(TCTL, (1 << 1) | (1 << 3) | (0x0F << 4) | (0x3F << 12)); // EN | PSP | CT | COLD

    klog.puts("igc: up\n");
    return true;
}

/// nic.Driver.txDropped: frames dropped on a full/unreclaimable TX ring.
pub fn txDropped() u64 {
    return nic.tx_dropped;
}
