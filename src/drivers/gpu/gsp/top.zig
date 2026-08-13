//! Minimal GPU TOP (topology) table parser — enumerates on-chip engines and
//! their PMC reset bits (nouveau subdev/top/ga100.c). We need it to find SEC2's
//! reset bit so we can power the engine on (PMC enable reg 0x000600) before
//! running the booter on it.
//!
//! Table: size = rd32(0x0224fc) >> 20; entries are dwords at 0x022800 + i*4,
//! grouped into 3-dword records per device (bit31 = "more dwords follow").
//! Record dword 0: type@[29:24]; dword 1: addr@[23:12], reset@[4:0].

const mmio = @import("../rm/mmio.zig");
const log = @import("../rm/log.zig").gpu;

const REG_TOP_SIZE: u64 = 0x0224fc;
const REG_TOP_BASE: u64 = 0x022800;

pub const ENGINE_SEC2: u32 = 0x0d;
pub const ENGINE_GSP: u32 = 0x14;

pub const EngineInfo = struct {
    addr: u32, // falcon base (BAR0)
    reset: u5, // PMC reset/enable bit index in 0x000600
};

/// Find an engine by TOP type (e.g. ENGINE_SEC2). Returns its falcon base +
/// reset bit, or null if absent.
pub fn find(regs: mmio.Mapping, want_type: u32) ?EngineInfo {
    const size = regs.read32(REG_TOP_SIZE) >> 20;
    var i: u32 = 0;
    var n: u32 = 0;
    var etype: u32 = ~@as(u32, 0);
    var addr: u32 = 0;
    var reset: u5 = 0;
    while (i < size) : (i += 1) {
        const data = regs.read32(REG_TOP_BASE + i * 4);
        if (data == 0 and n == 0) continue;
        switch (n) {
            0 => etype = (data & 0x3f000000) >> 24,
            1 => {
                addr = data & 0x00fff000;
                reset = @intCast(data & 0x0000001f);
            },
            else => {},
        }
        n += 1;
        if (data & 0x80000000 != 0) continue; // more dwords for this device
        n = 0;
        if (etype == want_type) {
            log("gpu.top: engine type 0x{x}: addr=0x{x} reset_bit={}\n", .{ want_type, addr, reset });
            return .{ .addr = addr, .reset = reset };
        }
    }
    return null;
}
