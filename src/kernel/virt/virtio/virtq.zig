//! Split virtqueue over guest RAM (virtio 1.1 §2.6). Pure: the queue is three
//! driver-programmed structures — descriptor table, available ring, used ring —
//! living inside a caller-provided guest-RAM slice where slice index ==
//! guest-physical address (guest RAM is based at guest-physical 0). Host-tested
//! (test/kernel/virt/virtio/virtq_test.zig).
//!
//! This module is the hypervisor's security boundary for device models: every
//! guest-supplied address, length, and ring index is bounds-checked against the
//! RAM slice before use, so an out-of-range access a malformed virtqueue could
//! cause is meant to surface HERE rather than as a host memory touch. Any
//! violation surfaces as an `Error`; the device
//! model aborts processing the queue rather than trusting it further.
//!
//! Ordering follows §2.6.13: the driver publishes avail.idx after filling the
//! ring, so the device acquire-loads it before reading entries; the device fills
//! a used-ring element first and release-stores used.idx after, so the driver's
//! acquire sees a complete element. `mem` must be at least 4-byte aligned (guest
//! RAM is page-aligned) for those two atomics; the ring base addresses must
//! carry the §2.6 minimum alignments, which are checked here, never trusted.

const std = @import("std");

/// Descriptor-table entry (§2.6.5): one guest buffer, chained to the next
/// descriptor when F_NEXT is set. Field order and widths are the wire format.
pub const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };

// Descriptor flags (§2.6.5).
pub const F_NEXT: u16 = 1;
pub const F_WRITE: u16 = 2;
pub const F_INDIRECT: u16 = 4; // indirect descriptor table — never negotiated, so rejected

// Structure layout (§2.6.5–§2.6.8): byte offsets within each area, element
// sizes, and the minimum alignment of each area's base address (§2.6).
const DESC_BYTES: u64 = @sizeOf(Desc); // 16
const AVAIL_ALIGN: u64 = 2;
const AVAIL_IDX_OFF: u64 = 2; // u16 idx after u16 flags
const AVAIL_RING_OFF: u64 = 4; // u16 ring[] after flags+idx
const USED_ALIGN: u64 = 4;
const USED_IDX_OFF: u64 = 2; // u16 idx after u16 flags
const USED_RING_OFF: u64 = 4; // {u32 id, u32 len} ring[] after flags+idx
const USED_ELEM_BYTES: u64 = 8;

pub const Error = error{ AddrOutOfBounds, ChainTooLong, BadIndex, NotReady, Unsupported };

pub const Virtq = struct {
    /// Guest RAM; index == guest-physical address.
    mem: []u8,
    /// Queue size in descriptors, programmed by the transport before ready.
    size: u16,
    desc_gpa: u64,
    avail_gpa: u64,
    used_gpa: u64,
    /// The next avail-ring slot this device will consume (free-running, mod-size
    /// on use, §2.6.7.1).
    last_avail: u16 = 0,
    /// The device's own used.idx shadow — the spec forbids reading it back from
    /// guest memory, which the guest could corrupt (§2.6.8.2).
    used_idx: u16 = 0,
    ready: bool = false,
    /// Completions dropped because the driver programmed an unusable used ring.
    /// pushUsed cannot return an error to the guest, so the drop is counted.
    dropped_used: u64 = 0,

    /// Bounds-check the guest-physical range [base+off, base+off+len) and return
    /// it as a host slice. Every guest-supplied address flows through here.
    fn range(self: *const Virtq, base: u64, off: u64, len: u64) Error![]u8 {
        const gpa = std.math.add(u64, base, off) catch return Error.AddrOutOfBounds;
        if (gpa > self.mem.len or len > self.mem.len - gpa) return Error.AddrOutOfBounds;
        return self.mem[@intCast(gpa)..@intCast(gpa + len)];
    }

    /// Acquire-load the driver's avail.idx (§2.6.6). Rejects a misaligned ring
    /// base — the atomic requires the §2.6 alignment the driver must provide.
    fn availIdx(self: *const Virtq) Error!u16 {
        if (self.avail_gpa % AVAIL_ALIGN != 0) return Error.AddrOutOfBounds;
        const bytes = try self.range(self.avail_gpa, AVAIL_IDX_OFF, 2);
        const p: *align(2) const u16 = @ptrCast(@alignCast(bytes.ptr));
        return @atomicLoad(u16, p, .acquire);
    }

    /// Pop the next available descriptor-chain head, or null when the driver has
    /// published nothing new. Heads come back in ring order; a head outside the
    /// descriptor table is BadIndex (the slot is still consumed, so a reset — not
    /// a livelock — follows).
    pub fn popAvail(self: *Virtq) Error!?u16 {
        if (!self.ready or self.size == 0) return Error.NotReady;
        const idx = try self.availIdx();
        if (idx == self.last_avail) return null;
        const slot: u64 = self.last_avail % self.size;
        const bytes = try self.range(self.avail_gpa, AVAIL_RING_OFF + slot * 2, 2);
        const head = std.mem.readInt(u16, bytes[0..2], .little);
        self.last_avail +%= 1;
        if (head >= self.size) return Error.BadIndex;
        return head;
    }

    /// Bounds-checked read of descriptor `i` from the guest's table (§2.6.5).
    pub fn descAt(self: *const Virtq, i: u16) Error!Desc {
        if (i >= self.size) return Error.BadIndex;
        const bytes = try self.range(self.desc_gpa, @as(u64, i) * DESC_BYTES, DESC_BYTES);
        return .{
            .addr = std.mem.readInt(u64, bytes[0..8], .little),
            .len = std.mem.readInt(u32, bytes[8..12], .little),
            .flags = std.mem.readInt(u16, bytes[12..14], .little),
            .next = std.mem.readInt(u16, bytes[14..16], .little),
        };
    }

    /// The guest buffer a descriptor points at, as a bounds-checked host slice.
    pub fn segment(self: *const Virtq, d: Desc) Error![]u8 {
        return self.range(d.addr, 0, d.len);
    }

    /// Publish a completed chain (§2.6.8): fill used.ring[used_idx % size] with
    /// the head and the byte count the device wrote, then release-store the
    /// advanced used.idx. A mis-programmed used ring cannot fault the host: an
    /// out-of-bounds or misaligned ring drops the completion into `dropped_used`.
    pub fn pushUsed(self: *Virtq, head: u16, written: u32) void {
        if (self.size == 0 or self.used_gpa % USED_ALIGN != 0) {
            self.dropped_used += 1;
            return;
        }
        const slot: u64 = self.used_idx % self.size;
        const elem = self.range(self.used_gpa, USED_RING_OFF + slot * USED_ELEM_BYTES, USED_ELEM_BYTES) catch {
            self.dropped_used += 1;
            return;
        };
        const idx_bytes = self.range(self.used_gpa, USED_IDX_OFF, 2) catch {
            self.dropped_used += 1;
            return;
        };
        std.mem.writeInt(u32, elem[0..4], head, .little);
        std.mem.writeInt(u32, elem[4..8], written, .little);
        self.used_idx +%= 1;
        const p: *align(2) u16 = @ptrCast(@alignCast(idx_bytes.ptr));
        @atomicStore(u16, p, self.used_idx, .release); // barrier: publishes the element
    }
};

/// Walks a descriptor chain from its head, following F_NEXT links. Hop-capped at
/// the queue size — a chain can never legitimately be longer, so a looped `next`
/// terminates in ChainTooLong instead of spinning the device model.
pub const ChainIter = struct {
    q: *const Virtq,
    next_index: ?u16,
    hops: u32 = 0,

    /// The next descriptor in the chain, null past the end.
    pub fn next(self: *ChainIter) Error!?Desc {
        const i = self.next_index orelse return null;
        if (self.hops >= self.q.size) return Error.ChainTooLong;
        self.hops += 1;
        const d = try self.q.descAt(i);
        // Indirect descriptors require negotiating VIRTIO_F_INDIRECT_DESC, which this
        // device never offers; a driver setting the flag anyway is malformed input.
        if (d.flags & F_INDIRECT != 0) return Error.Unsupported;
        self.next_index = if (d.flags & F_NEXT != 0) d.next else null;
        return d;
    }
};

/// Iterate the chain starting at `head` (a value popAvail returned).
pub fn chain(q: *const Virtq, head: u16) ChainIter {
    return .{ .q = q, .next_index = head };
}
