//! Shared core for the Intel Ethernet drivers. The e1000 and
//! the modern igb/igc controllers differ only in their register offsets, their
//! descriptor encoding, and their bring-up sequence — everything else (DMA-ring
//! allocation, MMIO access, the MAC read, and the polled send/poll loops) is
//! identical. That common machinery lives here once; each driver supplies a
//! `RegMap` (where its rings live) and a `DescOps` (how to encode/decode its
//! descriptors), then calls the shared `send`/`poll`.
//!
//! A dependency-free leaf module so both e1000.zig and igc.zig reuse it without a
//! back-edge through nic.zig. Descriptor formats are cross-checked against the
//! Linux e1000 and igc drivers.

const pmm = @import("../../../kernel/memory/pmm.zig");
const mmio = @import("../../../kernel/io/mmio.zig");
const counter = @import("../../../kernel/debug/counter.zig");

/// Frames delivered by poll() — the RX-path liveness proof. A native stall
/// where netdebug TX heartbeats continue but KMR1 goes deaf forks on this:
/// frozen = the RX ring stalled at the NIC; climbing = frames arrive and the
/// loss is above the driver (dispatch/fileserv).
var cnt_rx_frames = counter.Counter{ .mod = .net, .name = "rx.frames" };

/// Ring sizing, shared by both controllers. RX is deeper than TX because
/// receives arrive unsolicited; TX is drained synchronously.
///
/// TX is 64 deep, not 8: send() drops (counts) a frame when the ring is full
/// rather than block, and there is no retransmit yet, so a burst larger than the
/// ring loses its middle segments FOR GOOD. A POST body ships as ~1400-byte
/// segments, and an 8-deep ring (11 KiB) dropped anything past that — including
/// the agent's LLM POSTs. 64 (89 KiB) covers a realistic request. This does NOT
/// replace flow control + retransmit (a body past the ring, or any wire loss,
/// still needs those); it removes the acute local-overflow drop. TDLEN stays a
/// valid multiple of 128 for any N_TX that is a multiple of 8.
pub const N_RX = 32;
pub const N_TX = 64;
pub const BUF = 2048; // per-descriptor buffer (one full Ethernet frame)

/// Bound for register-bit-settle waits during bring-up (igc MDIC/reset/queue
/// enable). A few million PAUSEs is a generous timeout for a
/// control register to settle. NOT used on the send path anymore: send() is
/// fire-and-forget (it never blocks on a descriptor writeback).
pub const WAIT_SPINS: u32 = 5_000_000;

/// Register offsets that are identical on the e1000 (82540) and the modern igb/igc
/// controllers. The single owner — both drivers import these rather than each
/// re-declaring the same value. Per-queue ring offsets
/// (RDBAL/TDBAL/…) and the modern-only registers (SRRCTL, RXDCTL, MDIC, the
/// IGC IMC alias) differ per controller and stay local to each driver.
pub const CTRL = 0x0000; // Device Control
pub const STATUS = 0x0008; // Device Status
pub const IMC = 0x00D8; // Interrupt Mask Clear (legacy; igc also has IMC_IGC)
pub const RCTL = 0x0100; // Receive Control
pub const TCTL = 0x0400; // Transmit Control
pub const RAL0 = 0x5400; // Receive Address Low (MAC bytes 0-3)
pub const RAH0 = 0x5404; // Receive Address High (MAC bytes 4-5)

/// Receive Control bits, named once because both drivers program the same
/// receive filter and that filter is a contract, not a per-driver taste. kudos
/// bridges guests onto this one NIC at layer 2 (VIRT-029), so the hardware must
/// accept every address a guest answers to, not just this host's: UPE and MPE
/// turn off the unicast and multicast filters, BAM keeps broadcast. Without
/// MPE, multicast is discarded below any counter kudos keeps — a guest's IPv6
/// neighbour discovery would go unanswered with nothing to show for it.
pub const RCTL_EN: u32 = 1 << 1; // receiver enable
pub const RCTL_UPE: u32 = 1 << 3; // unicast promiscuous
pub const RCTL_MPE: u32 = 1 << 4; // multicast promiscuous
pub const RCTL_BAM: u32 = 1 << 15; // accept broadcast
pub const RCTL_SECRC: u32 = 1 << 26; // strip the Ethernet CRC

/// The handful of register offsets the shared send/poll loop needs. Each driver's
/// map differs (e1000 legacy vs igc per-queue offsets) but the *roles* are the
/// same, so the shared code addresses them by role through this table.
pub const RegMap = struct {
    rdt: usize, // RX descriptor tail — hand a refilled descriptor back to the NIC
    tdt: usize, // TX descriptor tail — kick a queued frame
    tdh: usize, // TX descriptor head — the NIC's own consume position (reclaim authority)
};

/// Per-controller descriptor encode/decode. The shared send/poll loop is written
/// once against these; the driver fills them in for its descriptor layout. All
/// take the descriptor-array base and an index, and the DMA buffer phys address.
pub const DescOps = struct {
    /// Write TX descriptor `i` for a `len`-byte frame already copied into `buf_phys`.
    tx_set: *const fn (ring: usize, i: usize, buf_phys: u64, len: usize) void,
    /// True once the controller has written back TX descriptor `i` (DD set).
    tx_done: *const fn (ring: usize, i: usize) bool,
    /// RX descriptor `i`'s received length if DD is set, else null.
    rx_len: *const fn (ring: usize, i: usize) ?usize,
    /// Reset RX descriptor `i` to the read/empty format pointing at `buf_phys`.
    rx_reset: *const fn (ring: usize, i: usize, buf_phys: u64) void,
};

/// The shared per-NIC state. A driver embeds one of these, fills `regs`/`ops`/the
/// ring pointers during its own bring-up, then delegates send/poll/macAddr here.
pub const Nic = struct {
    mmio: usize = 0,
    mac: [6]u8 = undefined,
    regs: RegMap = undefined,
    ops: DescOps = undefined,
    rx_ring: usize = 0, // phys base of the RX descriptor array
    tx_ring: usize = 0, // phys base of the TX descriptor array
    rx_buf: usize = 0, // phys base of N_RX * BUF receive buffers
    tx_buf: usize = 0, // phys base of N_TX * BUF transmit buffers
    rx_tail: usize = 0,
    tx_tail: usize = 0,
    tx_queued: u64 = 0, // total frames ever queued — lets send() tell a never-used slot (DD=0) from a wrapped one
    tx_dropped: u64 = 0, // frames dropped because the TX ring was full (link down / TX wedge)
    scratch: [BUF]u8 = undefined, // staging copy returned to the stack from poll

    /// Read a register at `mmio + off`.
    pub fn read(self: *const Nic, off: usize) u32 {
        return mmio.read32(self.mmio + off);
    }
    /// Write a register at `mmio + off`.
    pub fn write(self: *const Nic, off: usize, val: u32) void {
        mmio.write32(self.mmio + off, val);
    }

    /// Transmit one Ethernet frame, FIRE-AND-FORGET.
    /// Does NOT wait for the frame it just queued to transmit: blocking on this
    /// frame's own descriptor writeback would make a link-down or wedged TX cost
    /// every send a full multi-ms timeout, and netdebug's 4 datagrams/tick would
    /// then drag the GPU session loop below refresh. Instead we gate only on the slot we are
    /// about to REUSE: the ring is N_TX deep, so slot `i` was last used N_TX frames
    /// ago and has almost always completed. If it has NOT (its DD is still clear —
    /// the NIC hasn't drained it, i.e. the link is down or TX is wedged), we DROP
    /// this frame and count it rather than block. A dropped debug datagram is
    /// strictly better than freezing the desktop; real traffic retransmits at the
    /// protocol layer.
    pub fn send(self: *Nic, frame: []const u8) void {
        const i = self.tx_tail;
        // The slot we're about to overwrite must be free: either never used yet
        // (the first N_TX sends) or drained by the NIC. tx_set clears the status
        // byte when it arms a descriptor and the NIC sets DD on completion, so
        // tx_done(i) reads DD=0 for BOTH a never-queued slot and a wrapped slot
        // whose frame is still in flight. `tx_queued` disambiguates: before the
        // ring wraps (queued < N_TX) slot i was never armed and is free; after the
        // wrap, DD=0 means slot i's prior frame has NOT transmitted — the link is
        // down or TX is wedged, so DROP this frame (count it) rather than block.
        if (self.tx_queued >= N_TX and !self.ops.tx_done(self.tx_ring, i)) {
            // DD is clear — but on real silicon a clear DD does NOT mean "not yet
            // transmitted". The I226 defers status writeback in batches (TXDCTL.WTHRESH),
            // so a frame can be long gone with its DD bit still unwritten. Believing DD
            // here means the reclaim goes blind exactly one ring-length into the run:
            // TX is healthy, and every send after that is dropped as "still in flight".
            //
            // Emulation cannot show this. QEMU writes DD back instantly, so the bug is
            // invisible until it reaches real hardware — which is why the descriptor
            // format lives in igc_desc.zig, where a host test can hold it.
            //
            // So consult the hardware's own consume position instead: TDH. The ring
            // occupies [TDH, TDT) and slot i == TDT sits outside it, so writing i is
            // safe under exactly one condition — advancing the tail must not make
            // TDT == TDH, the state the NIC cannot tell from an empty ring. One
            // extra MMIO read, and only on the DD-miss path.
            const tdh = mmio.read32(self.mmio + self.regs.tdh) % N_TX;
            if ((i + 1) % N_TX == tdh) {
                // Genuinely full (or wedged/link-down). Count the drop so it is
                // observable rather than silent. Kept as a plain counter, not a log
                // call: intel.zig is a dependency-free leaf (no back-edge to
                // net.dbg), and dropping on the send path must not itself do I/O.
                self.tx_dropped += 1;
                return;
            }
        }
        const buf_phys = self.tx_buf + i * BUF;
        const dst: [*]u8 = @ptrFromInt(buf_phys);
        // Clamp to the per-descriptor DMA buffer, symmetric with the RX copy in
        // poll(): a caller (or a payload-length slip in sendIp) producing a frame
        // longer than BUF would otherwise DMA-corrupt the adjacent TX slot, which
        // the NIC then transmits. A frame this size never legitimately occurs.
        const n = @min(frame.len, BUF);
        @memcpy(dst[0..n], frame[0..n]);
        self.ops.tx_set(self.tx_ring, i, buf_phys, n);
        self.tx_tail = (i + 1) % N_TX;
        self.tx_queued +|= 1;
        self.write(self.regs.tdt, @intCast(self.tx_tail));
    }

    /// Return the next received frame (copied into `scratch`), or null if none.
    pub fn poll(self: *Nic) ?[]const u8 {
        const i = self.rx_tail;
        // The reported length comes from the descriptor writeback, i.e. from the
        // wire — an attacker controls the frame the NIC DMAs in. Clamp it to the
        // per-descriptor buffer size: both the DMA rx buffer and `scratch` are BUF
        // bytes, so a descriptor claiming a longer length (a malformed/oversized
        // writeback, or a jumbo the ring was never sized for) must never drive a
        // copy past either buffer. This is the RAM-safety backstop independent of
        // whatever the RCTL config allows the NIC to accept.
        const len = @min(self.ops.rx_len(self.rx_ring, i) orelse return null, BUF);
        cnt_rx_frames.inc();
        // Copy the payload through a VOLATILE source: the NIC DMA'd these bytes
        // in, and dmaAlloc @memset the buffer to 0 first, so a plain [*]const u8
        // read lets the optimizer prove the bytes still 0 and fold the copy to a
        // zero-fill (the exact bug fixed in xhci.zig).
        // @memcpy rejects a volatile source, so copy byte-wise.
        const src: [*]const volatile u8 = @ptrFromInt(self.rx_buf + i * BUF);
        var k: usize = 0;
        while (k < len) : (k += 1) self.scratch[k] = src[k];
        self.ops.rx_reset(self.rx_ring, i, self.rx_buf + i * BUF);
        // Hand descriptor `i` back to the NIC by setting the tail to it. This is the
        // canonical single-descriptor refill: we only got here because `i`'s DD bit
        // was set (rx_len returns null otherwise), so the NIC has already advanced
        // RDH *past* `i` to deliver it — RDH is therefore ahead of the new RDT=i, and
        // the NIC regains the whole ring except the one descriptor we consume next.
        // (Init sets RDT=N_RX-1 for the same "tail trails the newest available slot"
        // reason.) Do NOT "fix" this to i+1: that would hand the NIC a descriptor we
        // have not yet reset.
        self.write(self.regs.rdt, @intCast(i));
        self.rx_tail = (i + 1) % N_RX;
        return self.scratch[0..len];
    }

    /// The MAC read out of the RAL/RAH registers during the driver's bring-up.
    pub fn macAddr(self: *const Nic) [6]u8 {
        return self.mac;
    }
};

/// Register the shared counters. Called by each driver's bring-up, NOT from
/// poll(): registration scans the counter table, and doing that per received
/// frame would put a linear search on the RX hot path.
pub fn registerCounters() void {
    counter.register(&cnt_rx_frames);
}

/// Allocate `bytes` of zeroed, physically-contiguous DMA memory. Null on
/// failure — a value, not a 0 sentinel, so a forgotten check refuses to
/// compile (physical 0 is real, reserved memory here).
pub fn dmaAlloc(bytes: usize) ?usize {
    const frames = (bytes + pmm.FRAME_SIZE - 1) / pmm.FRAME_SIZE;
    // allocContiguousDma: the NIC rings/buffers are device-addressed — the
    // <4 GiB DMA rail is asserted at the allocation (pmm.DMA_LIMIT).
    const p = pmm.allocContiguousDma(frames) orelse return null;
    @memset(@as([*]u8, @ptrFromInt(p))[0 .. frames * pmm.FRAME_SIZE], 0);
    return p;
}

/// Return DMA memory taken by dmaAlloc (same frame rounding). A zero `addr` is
/// a slot that was never allocated — the init unwind paths pass every slot
/// unconditionally.
pub fn dmaFree(addr: usize, bytes: usize) void {
    if (addr == 0) return;
    const frames = (bytes + pmm.FRAME_SIZE - 1) / pmm.FRAME_SIZE;
    pmm.freeContiguous(addr, frames);
}

/// Unpack a 6-byte MAC from the Intel RAL/RAH receive-address registers (little
/// endian: RAL holds bytes 0-3, RAH bytes 4-5). Both drivers read it identically
/// from their own RAL0/RAH0 offsets.
pub fn macFromRegs(ral: u32, rah: u32) [6]u8 {
    return .{
        @truncate(ral),       @truncate(ral >> 8),
        @truncate(ral >> 16), @truncate(ral >> 24),
        @truncate(rah),       @truncate(rah >> 8),
    };
}

/// A NIC driver as seen by nic.zig: four function pointers over an opaque driver.
/// Replaces a per-method `switch (backend)` with one resolved-at-init value.
pub const Driver = struct {
    macAddr: *const fn () [6]u8,
    send: *const fn (frame: []const u8) void,
    poll: *const fn () ?[]const u8,
    linkUp: *const fn () bool,
    /// Cumulative frames dropped by send() on a full/unreclaimable ring. A TX
    /// wedge mutes the machine while it otherwise runs on fine, so the counter
    /// must be pollable from net.pump and shipped as a record the moment TX
    /// comes back.
    txDropped: *const fn () u64,
};

/// STATUS.LU (bit 1) — link up, same bit across the e1000 and igc families.
/// Netdebug gates its boot-log replay on this: frames sent before the link (and
/// the switch port behind it) is forwarding are silently lost.
pub const STATUS_LU: u32 = 1 << 1;
