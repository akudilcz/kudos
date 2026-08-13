//! GPFIFO pushbuffer method emitter (NVC36F host / NVA0B5 CE encoding).
//!
//! Grounded in cl906f.h. Distinct from the EVO disp `push.zig`: GPFIFO headers
//! are SEC_OP<<29 | COUNT<<16 | SUBCH<<13 | METHOD>>2. The buffer is CPU-visible
//! sysmem; the caller cache-flushes and writes the GPFIFO ring entry pointing at
//! it.

pub const SUBCH_HOST: u32 = 0; // NVC36F
pub const SUBCH_CE: u32 = 4; // NVA0B5

/// Host wait-for-idle (NVC36F_WFI): the engine drains all preceding work before
/// any later method runs — the barrier the GR render/resolve fencing rides on.
pub const WFI: u32 = 0x0078;

const SEC_OP_INC: u32 = 1;
const SEC_OP_IMMD: u32 = 4;
const SEC_OP_INC_ONCE: u32 = 5;

pub const HostPush = struct {
    buf: [*]u32,
    cap: usize,
    n: usize,

    pub fn init(phys: u64, capacity_bytes: usize) HostPush {
        return .{ .buf = @ptrFromInt(phys), .cap = capacity_bytes / 4, .n = 0 };
    }

    /// Start an incrementing run of `count` data dwords at `mthd` on `subch`;
    /// follow with exactly `count` data() calls.
    pub fn incr(self: *HostPush, subch: u32, mthd: u32, count: u32) void {
        self.emit((SEC_OP_INC << 29) | (count << 16) | (subch << 13) | (mthd >> 2));
    }

    /// Increment-once run: the FIRST data dword goes to `mthd`, every later
    /// dword goes to `mthd`+4 (which does not advance further). The encoding
    /// for methods that auto-advance internal state per write (e.g.
    /// LOAD_CONSTANT_BUFFER: dword0 = OFFSET at 0x238c, dwords 1..n all hit
    /// 0x2390 and the HW bumps the cb offset itself). A plain INC run walks
    /// past the 16-entry LOAD window and hangs the engine (observed on HW
    /// with a 64-dword constant load).
    pub fn incOnce(self: *HostPush, subch: u32, mthd: u32, count: u32) void {
        self.emit((SEC_OP_INC_ONCE << 29) | (count << 16) | (subch << 13) | (mthd >> 2));
    }

    /// Immediate method: 13-bit data packed in the header, no data dwords.
    pub fn immd(self: *HostPush, subch: u32, mthd: u32, val: u13) void {
        self.emit((SEC_OP_IMMD << 29) | (@as(u32, val) << 16) | (subch << 13) | (mthd >> 2));
    }

    pub fn data(self: *HostPush, v: u32) void {
        self.emit(v);
    }

    pub fn bytes(self: *const HostPush) u32 {
        return @intCast(self.n * 4);
    }

    fn emit(self: *HostPush, w: u32) void {
        if (self.n >= self.cap) @panic("gpu.hostpush: pushbuffer overflow");
        self.buf[self.n] = w;
        self.n += 1;
    }
};
