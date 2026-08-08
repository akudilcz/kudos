//! The guest's network adapter as one virtio-mmio device: a virtio-net model
//! (virtio 1.1 §5.1) behind the version-2 transport (virtio/mmio.zig), plus the
//! config space carrying the MAC and the interrupt latch that join them. Pure
//! and host-tested (test/kernel/virt/virtio/virtio_netdev_test.zig) — a scripted driver
//! conversation drives the whole path from a register probe to frames crossing
//! in both directions.
//!
//! No offload feature is ever offered, so every frame that crosses the device
//! is a plain Ethernet frame and its virtio_net_hdr prefix carries nothing.
//! Frames cross the host side through a narrow seam the NIC bridge implements:
//! outbound, each transmit chain is handed to the connected `FrameSink` exactly
//! once with the header stripped; inbound, `pushRx` copies one frame into the
//! guest's next free receive buffer behind an all-zero header. The device is
//! exposed to the guest even before a bridge connects a sink — the device map
//! and its cmdline discovery arguments are fixed at build time, and the display
//! adapter is wired unconditionally the same way — so an unbridged guest sees a
//! quiet network, and the drop counters say where its frames went.
//!
//! Neither seam call is safe against the vCPU concurrently driving the device's
//! registers: like serial receive (machine.zig pulls ivirt.conFetch at poll
//! time), delivery must happen on the guest's own core.

const std = @import("std");
pub const mmio = @import("mmio.zig");
pub const virtq = @import("virtq.zig");
pub const ivirt = @import("ivirt");

/// Virtio device type 1, "network card" (virtio 1.1 §5).
const DEVICE_ID_NET: u32 = 1;

/// VIRTIO_NET_F_MAC, feature bit 5 (§5.1.3): the device has a MAC address and
/// reports it in config space. The only device-specific feature offered — with
/// no checksum/GSO offload bits, a driver may hand the device nothing but
/// complete, plain frames.
const VIRTIO_NET_F_MAC: u64 = 1 << 5;

/// Queue indices (§5.1.2): receiveq1 and transmitq1. There is no control queue
/// because VIRTIO_NET_F_CTRL_VQ is not offered.
const RECEIVEQ: u16 = 0;
const TRANSMITQ: u16 = 1;

/// struct virtio_net_hdr (§5.1.6), the prefix on every frame in both
/// directions: flags, gso_type, hdr_len, gso_size, csum_start, csum_offset,
/// num_buffers — twelve bytes under VIRTIO_F_VERSION_1. With no offloads
/// negotiated every field is zero (gso_type 0 is VIRTIO_NET_GSO_NONE and
/// num_buffers is only meaningful under VIRTIO_NET_F_MRG_RXBUF), so the device
/// ignores the header on transmit and writes it all-zero on receive.
pub const HDR_BYTES: usize = 12;

/// Largest frame the seam carries: an Ethernet II frame of 14 header plus 1500
/// payload bytes, no frame check sequence — the frame half of the 1526-byte
/// receive buffers §5.1.6.3 requires of a driver that negotiated no offloads.
pub const MAX_FRAME_BYTES: usize = 1514;

/// struct virtio_net_config (§5.1.4): only the 6-byte `mac` field. Every later
/// field (status, max_virtqueue_pairs, mtu, …) belongs to a feature this device
/// does not offer, and the transport reads absent config bytes as zero.
const CONFIG_SIZE: usize = 6;

/// Where outbound guest frames go — the seam the NIC bridge implements. `put`
/// receives one plain Ethernet frame (virtio_net_hdr already stripped, at most
/// MAX_FRAME_BYTES long, valid only for the duration of the call) and returns
/// whether it was accepted; the device counts refusals in `tx_dropped`, so a
/// bridge with a full ring never fails silently.
pub const FrameSink = struct {
    ctx: *anyopaque,
    put: *const fn (ctx: *anyopaque, frame: []const u8) bool,
};

/// Locally administered unicast MAC for the guest in mailbox slot `id`: the
/// prefix spells "RSVDK" in ASCII — byte 0 (0x52, 'R') has the locally
/// administered bit set and the multicast bit clear — and the final byte is the
/// slot, so side-by-side guests get distinct addresses.
pub fn guestMac(id: ivirt.Id) [6]u8 {
    return .{ 'R', 'S', 'V', 'D', 'K', @intCast(id) };
}

/// The mailbox slot addressed by `mac`, or null when it is no guest's — the
/// inverse of `guestMac`, and the bridge's whole forwarding policy: a frame is
/// a guest's exactly when its destination is an address `guestMac` handed out.
pub fn guestIdFor(mac: *const [6]u8) ?ivirt.Id {
    const id: ivirt.Id = mac[5];
    if (id >= ivirt.MAX_VMS) return null;
    const expect = guestMac(id);
    if (!std.mem.eql(u8, mac[0..5], expect[0..5])) return null;
    return id;
}

pub const NetDev = struct {
    transport: mmio.Mmio = undefined,
    config: [CONFIG_SIZE]u8 = [_]u8{0} ** CONFIG_SIZE,
    /// The transport's interrupt line, latched here for the machine model to
    /// mirror onto its PIC at the next interrupt poll.
    irq_level: bool = false,
    bound: bool = false,
    /// The connected bridge, or null while none exists — transmitted frames
    /// then drop into `tx_dropped`.
    sink: ?FrameSink = null,
    /// Transmit staging: one chain's header and frame gathered contiguous, so
    /// the sink sees a single flat frame however the driver fragmented the
    /// chain. Sized at init — nothing on the transmit path allocates.
    tx_buf: [HDR_BYTES + MAX_FRAME_BYTES]u8 = undefined,
    /// Outbound frames that reached no wire: no sink connected, the sink
    /// refused, or the chain was runt or oversized.
    tx_dropped: u64 = 0,
    /// Inbound frames that reached no guest buffer: the driver not up, no free
    /// descriptor, an unusable ring, or a buffer too small for the frame.
    rx_dropped: u64 = 0,

    /// Wire the device up in place. The transport's backend holds interior
    /// pointers (`ctx` to this struct, `config` to its own field), so this must
    /// run on the NetDev's FINAL address — the machine model calls it from
    /// `Vm.start`, never from `Vm.create`, whose result is returned by value
    /// and copied into the VM table. `mac` lands in config space for the driver
    /// to read under VIRTIO_NET_F_MAC; `guest_ram` is the RAM slice the
    /// virtqueues live in.
    pub fn bind(self: *NetDev, mac: [6]u8, guest_ram: []u8) void {
        self.config = mac;
        self.irq_level = false;
        self.sink = null;
        self.tx_dropped = 0;
        self.rx_dropped = 0;
        self.transport = mmio.Mmio.init(.{
            .device_id = DEVICE_ID_NET,
            .device_features = VIRTIO_NET_F_MAC,
            .config = &self.config,
            .ctx = self,
            .notify = onNotify,
            .onReset = onReset,
        }, guest_ram, onIrq);
        self.bound = true;
    }

    /// Connect the bridge that carries this guest's frames to the wire. The
    /// drop counters keep accumulating across the connection, so frames lost
    /// before the bridge existed stay visible.
    pub fn connectSink(self: *NetDev, sink: FrameSink) void {
        self.sink = sink;
    }

    /// A guest MMIO read of `size` bytes at `off` (address − the device's
    /// window base). Reads before `bind` are all-zero, so a probe of an unwired
    /// slot finds no device rather than a half-built one.
    pub fn read(self: *NetDev, off: u64, size: u8) u32 {
        if (!self.bound) return 0;
        return self.transport.read(off, size);
    }

    pub fn write(self: *NetDev, off: u64, size: u8, val: u32) void {
        if (!self.bound) return;
        self.transport.write(off, size, val);
    }

    /// The device's interrupt line level, for the machine model to reflect onto
    /// its PIC line.
    pub fn irqLevel(self: *const NetDev) bool {
        return self.irq_level;
    }

    /// The inbound half of the seam: land one Ethernet frame in the guest's
    /// next free receive buffer behind an all-zero virtio_net_hdr. Returns
    /// whether it landed; every false is a counted drop — to the bridge, a
    /// driver that is down, an empty ring, and a too-small buffer all read the
    /// same way: the guest was not ready for this frame.
    pub fn pushRx(self: *NetDev, frame: []const u8) bool {
        if (!self.bound or frame.len > MAX_FRAME_BYTES) {
            self.rx_dropped += 1;
            return false;
        }
        const q = &self.transport.queues[RECEIVEQ];
        const popped = q.popAvail() catch |e| {
            // NotReady is the normal state before the driver brings the queue
            // up; any other error means the ring itself cannot be trusted.
            if (e != virtq.Error.NotReady)
                self.transport.status |= mmio.STATUS_DEVICE_NEEDS_RESET;
            self.rx_dropped += 1;
            return false;
        };
        const head = popped orelse {
            self.rx_dropped += 1;
            return false;
        };
        const written = deliver(q, head, frame) catch {
            self.transport.status |= mmio.STATUS_DEVICE_NEEDS_RESET;
            self.rx_dropped += 1;
            return false;
        };
        // Even a too-small chain is retired (written == 0): the driver gets its
        // buffer back holding nothing, and the queue keeps flowing.
        q.pushUsed(head, written);
        self.transport.raiseUsedIrq();
        if (written == 0) {
            self.rx_dropped += 1;
            return false;
        }
        return true;
    }

    fn onNotify(ctx: *anyopaque, queue: u16) void {
        const self: *NetDev = @ptrCast(@alignCast(ctx));
        switch (queue) {
            // A receive notify only publishes fresh buffers; frames arrive via
            // pushRx, so there is nothing to do until one does.
            RECEIVEQ => {},
            TRANSMITQ => {
                const consumed = self.drainTransmitQueue() catch {
                    // A malformed descriptor chain: the guest's queue cannot be
                    // trusted, so stop consuming it and tell the driver the
                    // device needs reset.
                    self.transport.status |= mmio.STATUS_DEVICE_NEEDS_RESET;
                    return;
                };
                if (consumed) self.transport.raiseUsedIrq();
            },
            else => {},
        }
    }

    /// Drain every available transmit chain: strip the virtio_net_hdr, hand the
    /// frame to the sink, retire the chain. Returns whether any chain was
    /// consumed — the used interrupt is only worth raising then.
    fn drainTransmitQueue(self: *NetDev) virtq.Error!bool {
        const q = &self.transport.queues[TRANSMITQ];
        var consumed = false;
        while (try q.popAvail()) |head| {
            try self.transmit(q, head);
            q.pushUsed(head, 0); // the chain is device-readable: nothing written back
            consumed = true;
        }
        return consumed;
    }

    /// Gather one transmit chain into `tx_buf` and hand the bytes past the
    /// header to the sink. A chain that is runt (nothing past the header) or
    /// overflows the staging buffer is dropped and counted; the caller still
    /// retires it so the queue keeps flowing.
    fn transmit(self: *NetDev, q: *const virtq.Virtq, head: u16) virtq.Error!void {
        var fill: usize = 0;
        var overflow = false;
        var it = virtq.chain(q, head);
        while (try it.next()) |d| {
            if (d.flags & virtq.F_WRITE != 0) continue; // tx chains are device-readable
            const seg = try q.segment(d);
            const room = self.tx_buf.len - fill;
            if (seg.len > room) overflow = true;
            const n = @min(seg.len, room);
            @memcpy(self.tx_buf[fill..][0..n], seg[0..n]);
            fill += n;
        }
        if (overflow or fill <= HDR_BYTES) {
            self.tx_dropped += 1;
            return;
        }
        const frame = self.tx_buf[HDR_BYTES..fill];
        const sink = self.sink orelse {
            self.tx_dropped += 1;
            return;
        };
        if (!sink.put(sink.ctx, frame)) self.tx_dropped += 1;
    }

    fn onReset(ctx: *anyopaque) void {
        // The device holds no model state outside the transport's queues, and
        // the drop counters survive a driver reset on purpose — they diagnose
        // the device's whole life, not one driver generation.
        _ = ctx;
    }

    fn onIrq(ctx: *anyopaque, level: bool) void {
        const self: *NetDev = @ptrCast(@alignCast(ctx));
        self.irq_level = level;
    }
};

/// Scatter an all-zero virtio_net_hdr followed by `frame` into the chain's
/// device-writable segments, in order. Returns the bytes the delivery needed,
/// or 0 when the chain has too little writable room for all of them — the
/// partial copy is harmless, because a used length of 0 tells the driver the
/// buffer holds nothing.
fn deliver(q: *const virtq.Virtq, head: u16, frame: []const u8) virtq.Error!u32 {
    const total = HDR_BYTES + frame.len;
    var off: usize = 0; // progress through the virtual [header ++ frame] source
    var it = virtq.chain(q, head);
    while (try it.next()) |d| {
        if (d.flags & virtq.F_WRITE == 0) continue;
        var seg = try q.segment(d);
        if (off < HDR_BYTES) {
            const n = @min(seg.len, HDR_BYTES - off);
            @memset(seg[0..n], 0); // the whole header is zero: no offloads
            off += n;
            seg = seg[n..];
        }
        if (seg.len > 0 and off < total) {
            const n = @min(seg.len, total - off);
            @memcpy(seg[0..n], frame[off - HDR_BYTES ..][0..n]);
            off += n;
        }
        if (off == total) return @intCast(total);
    }
    return 0;
}
