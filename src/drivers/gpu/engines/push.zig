//! NvDisplay (EVO) pushbuffer method encoding (nouveau include/nvif/pushc37b.h).
//!
//! The disp core/window channels execute a stream of method dwords from a VRAM
//! pushbuffer. Each logical "set method M to value V" emits a header dword then the
//! data dword(s):
//!
//!   header = OPCODE_METHOD(0) | (count << 18) | ((mthd >> 2) << 2)
//!
//! (NVC37B_DMA: OPCODE 31:29, METHOD_COUNT 27:18, METHOD_OFFSET 13:2.) An
//! incrementing-method run writes one header then `count` consecutive data dwords
//! for methods 4 bytes apart.

const vram = @import("vram.zig");
const mmio = @import("../rm/mmio.zig");

const OPCODE_METHOD: u32 = 0; // 31:29 = 0
const OPCODE_NONINC: u32 = 2 << 29;

/// Builds a method-dword stream into a CPU-side buffer, then flushes it to the
/// channel's VRAM pushbuffer via the PRAMIN window. The caller advances the
/// channel PUT pointer (see disp channel code) to make the engine execute it.
pub const Push = struct {
    buf: []u32, // CPU staging for the dword stream
    n: usize = 0, // dwords written

    /// Start building into caller-owned staging `buf` (the caller sizes it for the
    /// worst-case method count of the stream it emits).
    pub fn init(buf: []u32) Push {
        return .{ .buf = buf, .n = 0 };
    }

    /// Append one raw dword to the staging buffer and advance the cursor.
    fn put(self: *Push, dw: u32) void {
        self.buf[self.n] = dw;
        self.n += 1;
    }

    /// Emit `mthd = val` (single incrementing method, count 1).
    pub fn mthd(self: *Push, m: u32, val: u32) void {
        self.put(OPCODE_METHOD | (1 << 18) | ((m >> 2) << 2));
        self.put(val);
    }

    /// Emit an incrementing run: `mthd, mthd+4, …` taking the values in `vals`.
    pub fn mthdRun(self: *Push, m: u32, vals: []const u32) void {
        self.put(OPCODE_METHOD | (@as(u32, @intCast(vals.len)) << 18) | ((m >> 2) << 2));
        for (vals) |v| self.put(v);
    }

    /// Emit a non-incrementing run: `mthd` repeated, taking the values in `vals`.
    pub fn mthdNonInc(self: *Push, m: u32, vals: []const u32) void {
        self.put(OPCODE_NONINC | (@as(u32, @intCast(vals.len)) << 18) | ((m >> 2) << 2));
        for (vals) |v| self.put(v);
    }

    /// Number of bytes written so far (PUT advances by this).
    pub fn bytes(self: Push) u64 {
        return self.n * 4;
    }

    /// Copy the staged dword stream into the channel's VRAM pushbuffer at
    /// `pb_phys` via the PRAMIN window.
    pub fn flushTo(self: Push, regs: mmio.Mapping, pb_phys: u64) void {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            vram.write32(regs, pb_phys + i * 4, self.buf[i]);
        }
    }
};
