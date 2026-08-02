//! Host-built disp scanout ctxdma + RAMHT entry (AD102, GSP-RM).
//!
//! On Ada the window binds its scanout surface by a CTXDMA HANDLE
//! (SET_CONTEXT_DMA_ISO). That ctxdma is NOT an RM object — it is a 24-byte DMA
//! descriptor plus a RAMHT entry that the driver writes itself into `disp->inst`
//! (the 0x10000 VRAM RAMIN already registered to the GSP via WRITE_INST_MEM). The
//! display engine HW reads both directly out of that VRAM block; the GSP-RM is
//! never involved (nouveau usergv100.c / ramht.c / wndw.c / r535-disp.c).

const log = @import("../base/log.zig").gpu;
const mmio = @import("../base/mmio.zig");
const vram = @import("vram.zig");

/// The handle pushed in SET_CONTEXT_DMA_ISO(0): NV50_DISP_HANDLE_WNDW_CTX(kind=0).
pub const WNDW_CTX_HANDLE: u32 = 0xfb000000;

/// RAMHT occupies the first 0x1000 of disp->inst: 512 entries × 8 bytes, hash bits=9.
const RAMHT_BASE: u64 = 0x0;
const RAMHT_BYTES: u64 = 0x1000;
const RAMHT_ENTRIES: u32 = 512;
const RAMHT_BITS: u5 = 9;

/// Descriptors live after the RAMHT region (≥0x1000), 16-byte aligned.
const DESC_BASE: u64 = 0x1000;
const DESC_SIZE: u64 = 0x20; // 24-byte node, padded to 0x20

/// ctxdma descriptor flags0 for a linear (kind=0) VRAM, read-write aperture:
/// 0x4 (rw) | 0x1 (VRAM). No 0x40 (page) / 0x100000 (kind) bits. (usergv100.c)
const FLAGS0_LINEAR_VRAM_RW: u32 = 0x00000005;

/// nvkm_ramht_hash (ramht.c:26): fold the handle into 9-bit chunks, XOR the chid.
fn ramhtSlot(handle: u32, chid: u32) u32 {
    var hash: u32 = 0;
    var h: u32 = handle;
    const mask: u32 = (@as(u32, 1) << RAMHT_BITS) - 1;
    while (h != 0) : (h >>= RAMHT_BITS) hash ^= (h & mask);
    hash ^= chid << (RAMHT_BITS - 4);
    return hash & (RAMHT_ENTRIES - 1);
}

/// Create the host-side disp ctxdma for a linear VRAM surface and install its
/// RAMHT entry so SET_CONTEXT_DMA_ISO(handle) resolves to it. Per-`window` so each
/// head/monitor gets a DISTINCT handle, descriptor slot, and RAMHT entry (no
/// collisions when driving multiple monitors).
///
///   regs/inst_phys/vram_size : PRAMIN into disp->inst, full-VRAM aperture
///   client : disp RM client handle (low 14 bits = context tag)
///   window : the window index (chid). handle = WNDW_CTX_HANDLE | window.
///
/// Returns the ctxdma handle to push in SET_CONTEXT_DMA_ISO(0).
pub fn createScanout(regs: mmio.Mapping, inst_phys: u64, vram_size: u64, client: u32, window: u32) error{RamhtFull}!u32 {
    // Handle = NV50_DISP_HANDLE_WNDW_CTX(kind=0) = 0xfb000000 for every window
    // (linear). The RAMHT chid is the WINDOW CHANNEL's chid.user = window-user-base
    // (1) + instance = **1 + window** — PER-INSTANCE, not a constant 1.
    // HW-discriminated with the identity ILUT in place: constant chid=1 lit ONLY
    // head 0's panel (window 0, where 1+window == 1) while heads 1/2 committed but
    // scanned black — their engines resolve SET_CONTEXT_DMA_ISO/ILUT with chid 3/5,
    // so a chid-1 entry is invisible to them (an unresolvable ISO doesn't fail the
    // commit; it just fetches nothing).
    return createCtxdma(regs, inst_phys, 0, vram_size - 1, client, WNDW_CTX_HANDLE, 1 + window, window);
}

/// Notifier ctxdma for the CORE channel (chid.user=0; handle 0xfa000000). The core
/// SET_CONTEXT_DMA_NOTIFIER references this so the engine writes the FINISHED status
/// into the notifier buffer mapped by this ctxdma. Uses a distinct descriptor slot.
pub const CORE_NTFY_HANDLE: u32 = 0xfa000000;
/// The notifier ctxdma maps ONLY the notifier buffer (start=notifier), so the core
/// SET_NOTIFIER_CONTROL.OFFSET (an 11:4 field, tiny range) = 0 points at it. Mapping
/// all-VRAM-from-0 would require OFFSET=notifier>>4 which overflows the field.
pub fn createNotifier(regs: mmio.Mapping, inst_phys: u64, notifier: u64, client: u32) error{RamhtFull}!u32 {
    return createCtxdma(regs, inst_phys, notifier, notifier + 0x1000 - 1, client, CORE_NTFY_HANDLE, 0, 8);
}

/// OLUT ctxdma for the CORE channel (chid.user=0; handle 0xfc000000). nouveau binds
/// the OLUT via the core channel's all-VRAM mapping and HEAD_SET_OFFSET_OLUT =
/// olut_phys>>8, so this maps all of VRAM from 0 (like the scanout ctxdma) and the
/// caller passes the OLUT byte offset. Distinct descriptor slot (9).
pub const CORE_OLUT_HANDLE: u32 = 0xfc000000;
pub fn createOlut(regs: mmio.Mapping, inst_phys: u64, vram_size: u64, client: u32) error{RamhtFull}!u32 {
    return createCtxdma(regs, inst_phys, 0, vram_size - 1, client, CORE_OLUT_HANDLE, 0, 9);
}

/// Cursor-image ctxdma for the CORE channel (chid.user=0; handle 0xfd000000).
/// Like the OLUT: an all-VRAM linear mapping; HEAD_SET_OFFSET_CURSOR carries the
/// image's VRAM byte offset >>8 (nouveau binds the cursor via the core channel's
/// all-VRAM ctxdma). Distinct slot (10).
pub const CORE_CURS_HANDLE: u32 = 0xfd000000;
pub fn createCursor(regs: mmio.Mapping, inst_phys: u64, vram_size: u64, client: u32) error{RamhtFull}!u32 {
    return createCtxdma(regs, inst_phys, 0, vram_size - 1, client, CORE_CURS_HANDLE, 0, 10);
}

/// Notifier ctxdma for a WINDOW channel (chid.user = 1+window). The window
/// SET_CONTEXT_DMA_NOTIFIER (NVC57E 0x21C) references this so the display engine
/// writes the flip completion STATUS (BEGUN, at vblank) into the per-window
/// notifier buffer — the vsync-pacing signal that replaces the GET==PUT drain
/// (the session update cycle + vsync pacing; nouveau
/// wndwc37e_ntfy_set + base507c_ntfy_wait_begun). Maps ONLY the notifier buffer
/// (start=notifier) so SET_NOTIFIER_CONTROL.OFFSET(11:4) = 0 points at it, exactly
/// like the core notifier. Per-window handle + descriptor slot so multiple heads
/// don't collide. Handle = WNDW_NTFY_HANDLE | window; distinct slots from 16 up.
pub const WNDW_NTFY_HANDLE: u32 = 0xf9000000;
pub fn createWindowNotifier(regs: mmio.Mapping, inst_phys: u64, notifier: u64, client: u32, window: u32) error{RamhtFull}!u32 {
    return createCtxdma(regs, inst_phys, notifier, notifier + 0x1000 - 1, client, WNDW_NTFY_HANDLE | window, 1 + window, 16 + window);
}

/// Build a ctxdma descriptor + RAMHT entry mapping VRAM `[start, limit]`. `handle`
/// is pushed in SET_CONTEXT_DMA_*; `chid` is the channel's chid.user; `slot_idx`
/// picks a descriptor slot in disp->inst (each 0x20 apart after the RAMHT region).
fn createCtxdma(regs: mmio.Mapping, inst_phys: u64, start: u64, limit: u64, client: u32, handle: u32, chid: u32, slot_idx: u32) error{RamhtFull}!u32 {
    const desc_off: u32 = @as(u32, @intCast(DESC_BASE)) + slot_idx * @as(u32, @intCast(DESC_SIZE));

    // 24-byte descriptor: start/limit shifted >>8 (usergv100.c:41).
    const desc = inst_phys + desc_off;
    const start_s: u64 = start >> 8;
    const limit_s: u64 = limit >> 8;
    vram.write32(regs, desc + 0x00, FLAGS0_LINEAR_VRAM_RW);
    vram.write32(regs, desc + 0x04, @truncate(start_s));
    vram.write32(regs, desc + 0x08, @truncate(start_s >> 32));
    vram.write32(regs, desc + 0x0c, @truncate(limit_s));
    vram.write32(regs, desc + 0x10, @truncate(limit_s >> 32));
    vram.write32(regs, desc + 0x14, 0);

    // RAMHT entry: entry[0]=handle, entry[1]=(chid<<25)|(client&0x3fff)|(off<<9).
    const slot = try findFreeSlot(regs, inst_phys, ramhtSlot(handle, chid));
    const context: u32 = (chid << 25) | (client & 0x3fff) | (desc_off << 9);
    const entry = inst_phys + RAMHT_BASE + @as(u64, slot) * 8;
    vram.write32(regs, entry + 0, handle);
    vram.write32(regs, entry + 4, context);

    log("gpu.ctxdma: handle=0x{x} chid={} slot={} desc@inst+0x{x} ctx=0x{x}\n", .{ handle, chid, slot, desc_off, context });
    return handle;
}

/// Linear-probe forward for a free RAMHT slot (handle word == 0; the table starts
/// zeroed and 0xfb000000 is never 0).
fn findFreeSlot(regs: mmio.Mapping, inst_phys: u64, start: u32) error{RamhtFull}!u32 {
    var co = start;
    var i: u32 = 0;
    while (i < RAMHT_ENTRIES) : (i += 1) {
        if (vram.read32(regs, inst_phys + RAMHT_BASE + @as(u64, co) * 8) == 0) return co;
        co = if (co + 1 >= RAMHT_ENTRIES) 0 else co + 1;
    }
    return error.RamhtFull;
}
