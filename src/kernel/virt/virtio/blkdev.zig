//! virtio-blk — a block device backed by kudos RAM (spec VIRT-037).
//!
//! Every other guest device here moves data the host already had a place for: a
//! scanout to composite, a frame to bridge, a keystroke to deliver. A disk has
//! no such place, so this device IS its own storage — a flat slice of kudos
//! memory, addressed by 512-byte sector, that the guest sees as /dev/vda.
//!
//! WHY A DISK AT ALL, on a hypervisor whose guests boot from an initramfs. The
//! initramfs was never a design decision so much as the consequence of having no
//! block device: a Linux image that cannot mount a root filesystem must carry
//! its whole userland in RAM before init runs, which rules out every stock
//! distribution image ever published. With a disk the guest can be handed an
//! ordinary filesystem, and the images stop having to be built specially to be
//! bootable at all.
//!
//! RAM-BACKED, and nothing about that is temporary. The storage is host memory:
//! writes land in it, reads come back from it, and a VM that is torn down takes
//! its disk with it. That is the honest shape of a disk on a machine with no
//! persistent store of its own to lend — what it buys is not durability but a
//! block device that behaves like one, which is what the guest is asking for.
//!
//! Requests are a header, some data, and a status byte (§5.2.6), and the device
//! serves them synchronously: a read is a copy out of the backing store and a
//! write is a copy into it, so a request is complete by the time the chain is
//! pushed onto the used ring. There is no queue depth to model because there is
//! no latency to hide.

const std = @import("std");
const mmio = @import("mmio.zig");
pub const virtq = @import("virtq.zig");

/// Virtio device id for a block device (§5.2).
const DEVICE_ID_BLOCK: u32 = 2;

/// The sector size the virtio-blk protocol addresses in, fixed by the
/// specification (§5.2.6) regardless of any logical block size a device
/// advertises. Every `sector` field in a request counts these.
pub const SECTOR_BYTES: u64 = 512;

/// Request types (§5.2.6). FLUSH and GET_ID are answered rather than refused —
/// a driver that asks and is told "unsupported" logs an error on a device that
/// could perfectly well have said yes.
const T_IN: u32 = 0; // device → guest (read)
const T_OUT: u32 = 1; // guest → device (write)
const T_FLUSH: u32 = 4;
const T_GET_ID: u32 = 8;

/// Status byte values (§5.2.6).
const S_OK: u8 = 0;
const S_IOERR: u8 = 1;
const S_UNSUPP: u8 = 2;

/// The request header: type, a reserved word, and the starting sector.
const HDR_BYTES: usize = 16;

/// VIRTIO_BLK_F_FLUSH (§5.2.3): the device honours a flush. Offered because the
/// backing store is memory and a flush is therefore already true — a guest that
/// knows it can flush mounts its filesystem without the write-cache warnings a
/// device with no flush support draws.
const VIRTIO_BLK_F_FLUSH: u64 = 1 << 9;

/// The serial the device reports for GET_ID, which some drivers read to name the
/// disk. Twenty bytes, as the request's buffer is (§5.2.6).
const DEVICE_ID_STRING = "kudos-ramdisk";

/// virtio_blk_config (§5.2.4). Only `capacity` is meaningful without further
/// feature bits, and it counts SECTOR_BYTES sectors.
const CONFIG_SIZE: usize = 8;

pub const BlkDev = struct {
    transport: mmio.Mmio = undefined,
    config: [CONFIG_SIZE]u8 = [_]u8{0} ** CONFIG_SIZE,
    /// The transport's interrupt line, latched for the machine model to mirror
    /// onto its PIC at the next interrupt poll.
    irq_level: bool = false,
    bound: bool = false,
    /// The disk itself: host memory the guest addresses by sector. Owned by
    /// whoever called `bind` — the machine model allocates it with the VM and
    /// frees it with the VM.
    store: []u8 = &.{},
    /// Requests refused because the chain was malformed, addressed past the end
    /// of the store, or asked for something this device does not do. Never
    /// silent: a guest whose IO fails should find a count that says how often.
    errors: u64 = 0,
    /// Sectors read and written, which is the only traffic figure a disk has.
    sectors_read: u64 = 0,
    sectors_written: u64 = 0,

    /// Wire the device up in place over `store`. Like every device model here the
    /// transport's backend holds interior pointers, so this must run on the
    /// BlkDev's final address — the machine model calls it from `Vm.start`.
    /// `guest_ram` is the RAM the virtqueues live in; `store` is the disk.
    pub fn bind(self: *BlkDev, store: []u8, guest_ram: []u8) void {
        self.store = store;
        self.irq_level = false;
        self.errors = 0;
        self.sectors_read = 0;
        self.sectors_written = 0;
        std.mem.writeInt(u64, self.config[0..8], store.len / SECTOR_BYTES, .little);
        self.transport = mmio.Mmio.init(.{
            .device_id = DEVICE_ID_BLOCK,
            .device_features = VIRTIO_BLK_F_FLUSH,
            .config = &self.config,
            .ctx = self,
            .notify = onNotify,
            .onReset = onReset,
        }, guest_ram, onIrq);
        self.bound = true;
    }

    /// A guest MMIO read of `size` bytes at `off`. Reads before `bind` are
    /// all-zero, so a probe of an unwired slot finds no device.
    pub fn read(self: *BlkDev, off: u64, size: u8) u32 {
        if (!self.bound) return 0;
        return self.transport.read(off, size);
    }

    pub fn write(self: *BlkDev, off: u64, size: u8, val: u32) void {
        if (!self.bound) return;
        self.transport.write(off, size, val);
    }

    /// The device's interrupt line level, for the machine model's PIC.
    pub fn irqLevel(self: *const BlkDev) bool {
        return self.irq_level;
    }

    /// How many sectors the disk holds — what the guest reads from config space.
    pub fn capacitySectors(self: *const BlkDev) u64 {
        return self.store.len / SECTOR_BYTES;
    }

    fn onIrq(ctx: *anyopaque, level: bool) void {
        const self: *BlkDev = @ptrCast(@alignCast(ctx));
        self.irq_level = level;
    }

    fn onReset(ctx: *anyopaque) void {
        const self: *BlkDev = @ptrCast(@alignCast(ctx));
        self.irq_level = false;
        // The store survives a reset: a driver re-initialising its queues has
        // not asked for the disk to be wiped, and a filesystem it mounted before
        // the reset is still the filesystem it expects to find after one.
    }

    fn onNotify(ctx: *anyopaque, queue: u16) void {
        const self: *BlkDev = @ptrCast(@alignCast(ctx));
        if (queue != 0) return; // one request queue (§5.2.2)
        self.processQueue(&self.transport.queues[0]);
        self.transport.raiseUsedIrq();
    }

    /// Serve every request the driver has made available on `q`. Public because
    /// it is the whole device: the transport calls it on a queue notification,
    /// and a test drives it against a queue of its own without having to stand
    /// up an MMIO transport to reach the behaviour underneath.
    pub fn processQueue(self: *BlkDev, q: *virtq.Virtq) void {
        while (q.hasAvail()) {
            const head = (q.popAvail() catch {
                self.errors += 1;
                return;
            }) orelse return;
            const written = self.serve(q, head);
            q.pushUsed(head, written);
        }
    }

    /// Serve one request chain and return the number of bytes the device wrote
    /// into it — the data it produced plus the status byte, which is what the
    /// used ring reports (§2.6.8).
    ///
    /// The chain is a header, then data, then a one-byte status the device
    /// writes last. Rather than assume that shape, this walks the chain and
    /// treats the FINAL device-writable byte as the status: a driver is entitled
    /// to fragment the data across as many descriptors as it likes.
    fn serve(self: *BlkDev, q: *virtq.Virtq, head: u16) u32 {
        var it = virtq.chain(q, head);
        const hdr_desc = (it.next() catch null) orelse {
            self.errors += 1;
            return 0;
        };
        const hdr = q.segment(hdr_desc) catch {
            self.errors += 1;
            return 0;
        };
        if (hdr.len < HDR_BYTES) {
            self.errors += 1;
            return 0;
        }
        const req_type = std.mem.readInt(u32, hdr[0..4], .little);
        const sector = std.mem.readInt(u64, hdr[8..16], .little);

        // Collect the rest of the chain: everything but the last writable
        // descriptor is data, and the last one is where the status goes.
        var segs: [MAX_DATA_SEGS][]u8 = undefined;
        var nsegs: usize = 0;
        var status_seg: ?[]u8 = null;
        while (true) {
            const d = (it.next() catch {
                self.errors += 1;
                return 0;
            }) orelse break;
            const seg = q.segment(d) catch {
                self.errors += 1;
                return 0;
            };
            // A one-byte device-writable tail is the status byte (§5.2.6).
            if (seg.len == 1 and (d.flags & virtq.F_WRITE) != 0) {
                status_seg = seg;
                break;
            }
            if (nsegs == MAX_DATA_SEGS) {
                self.errors += 1;
                return 0;
            }
            segs[nsegs] = seg;
            nsegs += 1;
        }
        const status = status_seg orelse {
            // No status byte means no way to answer, so there is nothing to say
            // but count it.
            self.errors += 1;
            return 0;
        };

        const data_bytes = self.transfer(req_type, sector, segs[0..nsegs]);
        status[0] = if (data_bytes) |_| S_OK else |e| switch (e) {
            error.Unsupported => S_UNSUPP,
            error.OutOfRange => S_IOERR,
        };
        if (data_bytes) |n| {
            // Only a read puts bytes in the guest's buffers; a write's data
            // travelled the other way, so the used length is the status alone.
            return @intCast(n + 1);
        } else |_| {
            self.errors += 1;
            return 1;
        }
    }

    /// Move the request's data. Returns the number of bytes written INTO guest
    /// buffers, which is nonzero only for a read.
    fn transfer(self: *BlkDev, req_type: u32, sector: u64, segs: [][]u8) error{ Unsupported, OutOfRange }!usize {
        switch (req_type) {
            T_IN, T_OUT => {},
            // A flush over a memory-backed store has already happened by the
            // time it is asked for: every write completed into the store before
            // its chain was retired.
            T_FLUSH => return 0,
            T_GET_ID => {
                if (segs.len == 0) return 0;
                const dst = segs[0];
                @memset(dst, 0);
                const n = @min(dst.len, DEVICE_ID_STRING.len);
                @memcpy(dst[0..n], DEVICE_ID_STRING[0..n]);
                return n;
            },
            else => return error.Unsupported,
        }

        // One bounds check for the whole request, before any byte moves: a
        // request that runs off the end of the disk must not half-happen.
        var total: usize = 0;
        for (segs) |s| total += s.len;
        const start = sector * SECTOR_BYTES;
        if (start > self.store.len or total > self.store.len - start) return error.OutOfRange;

        var off = start;
        var produced: usize = 0;
        for (segs) |s| {
            if (req_type == T_IN) {
                @memcpy(s, self.store[off..][0..s.len]);
                produced += s.len;
            } else {
                @memcpy(self.store[off..][0..s.len], s);
            }
            off += s.len;
        }
        const sectors = (total + SECTOR_BYTES - 1) / SECTOR_BYTES;
        if (req_type == T_IN) self.sectors_read += sectors else self.sectors_written += sectors;
        return produced;
    }
};

/// The most descriptors of data one request may carry. A chain longer than this
/// is refused rather than served partially: the figure is well above what any
/// driver produces for a single request (Linux caps a virtio-blk segment count
/// far below it) and it keeps the segment table off the heap and on the stack,
/// where a device model on an interrupt path belongs.
const MAX_DATA_SEGS: usize = 128;
