//! WPR2 VRAM content dump (Xid-62 diagnostic, Step 3).
//!
//! After booter_load, the signed Booter has DMAed GSP-RM into WPR2 and FRTS has
//! staged the FRTS sub-region. The bytes the GSP-RM actually validates at init
//! live there — invisible in host registers or the DMA structs we hand over, so a
//! byte-for-byte mismatch vs nouveau there is the prime remaining Xid-62 suspect.
//!
//! Read method: the BAR0 PRAMIN window (nouveau shadowramin.c). Set the window
//! base register 0x001700 = (vram_byte_addr >> 16); the 1 MiB aperture at
//! 0x700000 then mirrors VRAM starting at (base << 16). WPR2 starts 1 MiB-aligned
//! (fblayout carves wpr2.addr at 0x100000 granularity), so a single window set
//! covers the leading content we dump.
//!
//! Output format MIRRORS the instrumented nouveau `kudos_dump2` (tu102.c:299):
//!   KDUMP <name> <offset>: <w0> <w1> <w2> <w3>
//! so the two traces diff line-for-line.

const mmio = @import("../base/mmio.zig");
const log = @import("../base/log.zig").gpu;

const PRAMIN_WINDOW_REG: u64 = 0x001700; // window base = vram_addr >> 16
const PRAMIN_APERTURE: u64 = 0x700000; // 1 MiB BAR0 mirror of (base << 16)
const PRAMIN_APERTURE_SIZE: u64 = 0x100000;

/// Dump `len` bytes of VRAM starting at FB byte offset `vram_addr`, in the same
/// hex layout as nouveau's kudos_dump2 (4 dwords per line, byte-offset prefix).
/// `len` must fit the 1 MiB PRAMIN aperture from the windowed base; callers dump
/// small leading regions (WprMeta + heap header), so this holds.
pub fn dump(regs: mmio.Mapping, name: []const u8, vram_addr: u64, len: u32) void {
    const saved = regs.read32(PRAMIN_WINDOW_REG);
    defer regs.write32(PRAMIN_WINDOW_REG, saved); // restore window on the way out

    const base: u32 = @truncate(vram_addr >> 16);
    regs.write32(PRAMIN_WINDOW_REG, base);
    const win_off: u64 = vram_addr & 0xffff; // byte offset within the windowed base

    log("gpu.wpr2dump: KDUMP {s} vram_addr=0x{x} len={} (window base=0x{x})\n", .{ name, vram_addr, len, base });

    var i: u32 = 0;
    while (i + 16 <= len) : (i += 16) {
        const o = win_off + i;
        // If a 16-byte row would cross the aperture, re-window. (WPR2 leading dumps
        // stay within 1 MiB, but keep this correct rather than silently wrapping.)
        if (o + 16 > PRAMIN_APERTURE_SIZE) {
            const nb: u32 = @truncate((vram_addr + i) >> 16);
            regs.write32(PRAMIN_WINDOW_REG, nb);
        }
        const ro = (vram_addr + i) & 0xffff;
        const w0 = regs.read32(PRAMIN_APERTURE + ro + 0);
        const w1 = regs.read32(PRAMIN_APERTURE + ro + 4);
        const w2 = regs.read32(PRAMIN_APERTURE + ro + 8);
        const w3 = regs.read32(PRAMIN_APERTURE + ro + 12);
        log("gpu.wpr2dump: KDUMP {s} {x:0>4}: {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{ name, i, w0, w1, w2, w3 });
    }
}
