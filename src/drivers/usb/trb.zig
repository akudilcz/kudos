//! Pure TRB math for the xHCI transfer rings — the parts that are arithmetic
//! rather than MMIO, so they can be host-tested (`zig build test`).
//!
//! xhci.zig imports MMIO and cannot compile on the host, so nothing in it is reachable
//! by a test. The 64 KiB rule below is exactly the kind of fact that needs one: QEMU's
//! xHCI model does NOT enforce it and happily DMAs a straddling buffer, while the real
//! Intel PCH controller corrupts or errors the transfer. So it lives here, where a
//! regression turns the host suite red rather than waiting for a boot on real hardware.

const std = @import("std");

/// One Transfer Request Block — the 16-byte unit of every xHCI ring (command,
/// transfer, and event rings alike; xHCI §4.11 / §6.4). One home for the
/// layout: xhci.zig's rings and the class glue reached through the controller
/// seam (hub.zig submitCommand/cmdOk) all speak this type.
pub const Trb = extern struct {
    param: u64 = 0,
    status: u32 = 0,
    control: u32 = 0,
};

/// TRB Type (control bits 15:10) of the Configure Endpoint command
/// (xHCI §6.4.3.5). Here rather than in xhci.zig so the class glue behind the
/// controller seam (hub.zig) can build the command word without importing the
/// driver.
pub const TYPE_CONFIGURE_ENDPOINT: u32 = 12;

/// xHCI §4.11.2.1 / §6.4.1.1: a TRB's data buffer MUST NOT cross a 64 KiB
/// boundary. A transfer that spans one is split across several chained TRBs.
pub const BOUNDARY: u64 = 64 * 1024;

/// One TRB's worth of buffer: guaranteed not to cross a 64 KiB boundary.
pub const Span = struct { addr: u64, len: u32 };

/// Walks a (addr, len) buffer, yielding the spans a TD must be split into so
/// that no single TRB crosses a 64 KiB boundary.
///
/// A zero-length buffer still yields ONE zero-length span: a zero-length packet
/// is a legitimate bulk transfer and needs a TRB to carry it.
pub const Splitter = struct {
    addr: u64,
    remaining: u32,
    emitted: bool = false,

    pub fn init(addr: u64, len: u32) Splitter {
        return .{ .addr = addr, .remaining = len };
    }

    pub fn next(self: *Splitter) ?Span {
        if (self.remaining == 0) {
            if (self.emitted) return null;
            self.emitted = true;
            return Span{ .addr = self.addr, .len = 0 };
        }
        // Bytes left before the next 64 KiB boundary. When addr is already
        // boundary-aligned this is a full BOUNDARY, never 0.
        const to_boundary: u64 = BOUNDARY - (self.addr & (BOUNDARY - 1));
        const take: u32 = @intCast(@min(@as(u64, self.remaining), to_boundary));
        const s = Span{ .addr = self.addr, .len = take };
        self.addr += take;
        self.remaining -= take;
        self.emitted = true;
        return s;
    }
};

/// How many TRBs a (addr, len) buffer needs. The caller checks this against the
/// ring's free space BEFORE pushing anything — a TD that half-fits would leave
/// the ring with a chained TRB whose continuation never arrives.
pub fn spanCount(addr: u64, len: u32) u32 {
    var it = Splitter.init(addr, len);
    var n: u32 = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// xHCI §4.11.7.1 TD Size: the number of PACKETS still to transfer after this
/// TRB, saturated at 31 (the field is 5 bits). Zero on the final TRB of a TD.
/// The controller uses it to schedule; a wrong value can stall the pipe.
pub fn tdSize(remaining_after: u32, mps: u32) u32 {
    if (remaining_after == 0 or mps == 0) return 0;
    const packets = (remaining_after + mps - 1) / mps;
    return @min(packets, 31);
}

/// The Normal-TRB status word: transfer length (bits 16:0) + TD Size (bits 21:17).
/// Interrupter Target (31:22) stays 0 — we run a single interrupter.
pub fn statusWord(len: u32, td_size: u32) u32 {
    return (len & 0x1FFFF) | ((td_size & 0x1F) << 17);
}

/// Control-word bits the ring-wrap Link math needs (xHCI §6.4.1). One home for
/// these encodings; xhci.zig's private copies must match.
pub const TYPE_LINK: u32 = 6; // TRB Type field (bits 15:10) value for a Link TRB
pub const TOGGLE_CYCLE: u32 = 1 << 1; // Link TRB: flip the ring's Cycle state on traverse
pub const CHAIN: u32 = 1 << 4; // this TRB is not the last of its TD

/// The Link TRB control word the producer writes when the enqueue pointer wraps
/// right after pushing a TRB whose control word is `pushed_control`, at ring
/// Cycle state `cycle`. The Link MUST carry CHAIN when the TRB just pushed is
/// mid-TD (chained) — otherwise the controller ends the TD at the wrap and the
/// TD's tail becomes a stray TRB, silently splitting a chained bulk transfer
/// that straddles the ring boundary (xHCI §4.11.5.1). QEMU tolerates the missing
/// bit; the real Intel PCH corrupts the transfer, so the rule is host-tested here.
pub fn linkControl(cycle: u32, pushed_control: u32) u32 {
    var c: u32 = (TYPE_LINK << 10) | TOGGLE_CYCLE | cycle;
    if (pushed_control & CHAIN != 0) c |= CHAIN;
    return c;
}
