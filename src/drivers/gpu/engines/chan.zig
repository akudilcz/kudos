//! Disp CORE channel alloc + EVO pushbuffer submission (AD102, GSP-RM).
//!
//! Grounded in the nouveau tree (`nvkm/subdev/gsp/rm/r570/disp.c`
//! r570_disp_chan_set_pushbuf; `dispnv50/disp.c` nv50_dmac_create/nv50_dmac_kick).
//! AD102 core class is the c37d-family AD102_DISP_CORE_CHANNEL_DMA (0xc77d),
//! chid.user = 0.
//!
//! Bring-up: 4 KiB page-aligned VRAM pushbuffer (zeroed) → CHANNEL_PUSHBUFFER ctrl
//! (0x20800a58, → subdevice) → CHANNELDMA alloc (RM_ALLOC 0xc77d, parent = disp
//! root 0xc770). Submission: write dwords to the pushbuffer, VRAM-flush handshake
//! (wr 0x070000=1, poll &0x2), then wr32(0x680000, put_dwords<<2). No doorbell.

const log = @import("../rm/log.zig").gpu;
const gsp = @import("../gsp/gsp.zig");
const rm = @import("../gsp/rm.zig");
const nvrm = @import("../rm/nvrm.zig");
const vram = @import("vram.zig");
const mmio = @import("../rm/mmio.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const Push = @import("push.zig").Push;

/// Channel USER windows in BAR0 (r535_chan_user, disp.c:45). PUT @+0x00,
/// GET @+0x04 (PTR field 11:2). nv50_dmac_kick / disp.c.
pub const CORE_USER_BASE: u64 = 0x680000; // core (size 0x10000)
pub const WNDW_USER_BASE: u64 = 0x690000; // window w: +w*USER_STRIDE
const USER_PUT: u64 = 0x00;
const USER_GET: u64 = 0x04;
/// Per-instance stride of the window/WIMM/cursor USER pages: one 4 KiB page
/// per channel instance (r535_chan_user, disp.c:45).
const USER_STRIDE: u64 = 0x1000;
/// USER_GET PTR field, bits 11:2 — the consumed byte offset into the 4 KiB
/// pushbuffer (nv50_dmac_kick reads it the same way).
const USER_GET_PTR_MASK: u32 = 0xffc;

/// VRAM-flush handshake register (nv50_dmac_kick): write 1, poll until the
/// BUSY bit (bit1) clears.
const VRAM_FLUSH: u64 = 0x070000;
const VRAM_FLUSH_PENDING: u32 = 0x1;
const VRAM_FLUSH_BUSY: u32 = 0x2;

/// Pushbuffer is one 4 KiB page → 1024 dwords; cap usable method dwords at 1023.
const PB_SIZE: u64 = 0x1000;
const PB_MAX_DWORDS: usize = 1023;

/// EVO pushbuffer JUMP-to-offset-0 dword: OPCODE_JUMP (1) in bits 31:29,
/// target byte offset 0 in the low bits — the ring-wrap restart nouveau emits
/// in nv50_dmac_wait.
const PB_JUMP_TO_START: u32 = 0x20000000;

/// Wall-clock budget for the channel-drain and VRAM-flush polls, matching the
/// 2 s nouveau uses in nv50_dmac_wait / nv50_dmac_free.
const DRAIN_TIMEOUT_MS: u64 = 2000;

pub const Error = error{
    ChannelPushbufTooBig,
    VramFlushTimeout,
} || rm.Error || error{VramOutOfMemory};

/// A live disp CORE channel: its VRAM pushbuffer, the current PUT dword cursor,
/// and the BAR0 USER window base.
pub const CoreChan = struct {
    pb_phys: u64,
    pb_size: u64,
    put: u32,
    user_base: u64,

    /// Read the channel GET pointer as a dword index (PTR field 11:2 of USER_GET is
    /// a byte offset; >>2 gives the dword count, directly comparable to `put`).
    pub fn readGet(self: CoreChan, regs: mmio.Mapping) u32 {
        return (regs.read32(self.user_base + USER_GET) & USER_GET_PTR_MASK) >> 2;
    }

    /// Non-blocking drain check: true when GET has caught up to PUT, i.e. the
    /// last submitted UPDATE (e.g. an interval=1 vsync flip) has been consumed
    /// by the engine. The present pump's flip gate polls this instead of
    /// blocking in waitDrained (the session update cycle).
    pub fn drained(self: CoreChan, regs: mmio.Mapping) bool {
        return self.readGet(regs) == self.put;
    }

    /// Free dwords writable RIGHT NOW without overtaking the engine, measured against
    /// GET (never PUT) — nouveau nv50_dmac_free (dispnv50/disp.c:160). If GET is
    /// ahead of our write cursor, stay 5 dwords behind it (an NVIDIA HW quirk); if
    /// GET is behind us (or equal), the ring is free from `put` to the end.
    fn freeDwords(self: CoreChan, regs: mmio.Mapping) u32 {
        const get = self.readGet(regs);
        if (get > self.put) {
            // Stay 5 behind GET; if GET is within 5 dwords ahead, no room yet (0, not
            // an unsigned wrap of `get - put - 5`).
            const gap = get - self.put;
            return if (gap > 5) gap - 5 else 0;
        }
        return @as(u32, PB_MAX_DWORDS) - self.put;
    }

    /// Ring-wrap reuse — the nouveau nv50_dmac_wind model (dispnv50/disp.c:168): reuse
    /// the pushbuffer start as soon as the engine's GET pointer has DEPARTED it, NOT
    /// when the channel has fully drained (GET==PUT). Waiting for a full drain here is
    /// the residual idle-jitter bug: a NON_TEARING interval=1 flip's UPDATE is not
    /// consumed until its vblank latch, so GET lags PUT for most of the refresh and a
    /// full-drain wrap-wait blocked up to a whole refresh (pushbuffer
    /// ring reuse). Waits only for GET != 0 (2 s budget), then emits the EVO JUMP-to-0
    /// and resets the write cursor. Under a live flip stream GET is already past 0, so
    /// this is ~free. Returns error.VramFlushTimeout if GET never departs the start.
    fn windAtWrap(self: *CoreChan, regs: mmio.Mapping) Error!void {
        // Only block if GET still sits at the ring start (dword 0) — else the JUMP
        // target is already free to overwrite.
        if (self.readGet(regs) == 0) {
            const deadline = tsc.rdtsc() + tsc.msTicks(DRAIN_TIMEOUT_MS);
            while (self.readGet(regs) == 0) {
                if (tsc.rdtsc() >= deadline) {
                    log("gpu.chan: ring-wind timeout: GET stuck at 0 (PUT={} user=0x{x})\n", .{ self.put, self.user_base });
                    return error.VramFlushTimeout;
                }
                asm volatile ("pause");
            }
        }
        // Emit JUMP-to-0 at the current cursor and restart the ring. The JUMP dword
        // must be in VRAM before the PUT kick that follows in submit().
        vram.write32(regs, self.pb_phys + @as(u64, self.put) * 4, PB_JUMP_TO_START);
        try vramFlush(regs);
        regs.write32(self.user_base + USER_PUT, 0); // engine follows the jump
        self.put = 0;
    }

    /// Wait until the engine has DRAINED this channel's pushbuffer (GET catches up to
    /// PUT), i.e. every method we pushed has been consumed — the nouveau
    /// nv50_dmac_wait / nv50_dmac_free drain poll (2 s wall-clock budget). A window
    /// channel whose UPDATE hasn't drained is not yet armed; committing the core
    /// (head latch) before that leaves the head scanning an un-composited window →
    /// black. Used ONLY at bring-up/modeset, where GET==PUT is the correct "this
    /// window latched" signal; the per-frame flip path must NOT full-drain (see
    /// windAtWrap). Returns error.VramFlushTimeout if it never drains.
    pub fn waitDrained(self: CoreChan, regs: mmio.Mapping) Error!void {
        const deadline = tsc.rdtsc() + tsc.msTicks(DRAIN_TIMEOUT_MS);
        // Drained ⇔ GET == PUT. An ordered (<) compare breaks on the frame
        // after a pushbuffer wrap: GET still reads near the ring end while PUT
        // is small again, so `<` sees "drained" while the flip is in flight.
        while (self.readGet(regs) != self.put) {
            if (tsc.rdtsc() >= deadline) {
                log("gpu.chan: channel drain timeout GET={} PUT={} user=0x{x}\n", .{ self.readGet(regs), self.put, self.user_base });
                return error.VramFlushTimeout;
            }
            asm volatile ("pause");
        }
    }
};

/// Allocate the disp CORE channel (class 0xc77d, instance 0, USER 0x680000).
pub fn coreChannelInit(g: gsp.Gsp, valloc: *vram.Allocator, dispRoot: u32, subdevice: u32) Error!CoreChan {
    return channelInit(g, valloc, dispRoot, subdevice, nvrm.AD102_DISP_CORE_CHANNEL_DMA, 0, CORE_USER_BASE);
}

/// Allocate the disp WINDOW channel (class 0xc67e, instance = window index). Its
/// BAR0 USER window is strided by the WINDOW INDEX, not the head: 0x690000 +
/// window*0x1000. (Was head*0x1000 — wrong for head>0: head 1's window is index 2,
/// so its PUT must go to 0x692000, not 0x691000. head 2 only "worked" by landing on
/// another valid channel's slot by coincidence.)
pub fn windowChannelInit(g: gsp.Gsp, valloc: *vram.Allocator, dispRoot: u32, subdevice: u32, window: u32) Error!CoreChan {
    return channelInit(g, valloc, dispRoot, subdevice, nvrm.GA102_DISP_WINDOW_CHANNEL_DMA, window, WNDW_USER_BASE + @as(u64, window) * USER_STRIDE);
}

/// Window-immediate (WIMM) channel USER base (r535_chan_user: 0x6b0000 + window*0x1000).
pub const WIMM_USER_BASE: u64 = 0x6b0000;

/// Cursor PIO channel USER base (r535_chan_user: 0x6d8000 + head*0x1000).
pub const CURS_USER_BASE: u64 = 0x6d8000;

// c37a cursor immediate-method offsets within the USER page
// (clc37a.h — NOT the 507a offsets).
const CURS_UPDATE: u64 = 0x200;
const CURS_POINT_OUT: u64 = 0x208;

/// Allocate the per-head cursor PIO channel (GA102_DISP_CURSOR 0xc67a).
/// Unlike the DMA channels: NO pushbuffer (the PUSHBUFFER ctrl is still sent,
/// with valid=0 — r535_curs_init parity), no RAMHT bind, no doorbell. Returns
/// the BAR0 USER page base; moves are raw MMIO via cursorMove.
pub fn cursorChannelInit(g: gsp.Gsp, dispRoot: u32, subdevice: u32, head: u32) Error!u64 {
    var pbp = nvrm.ChannelPushbufferParams{
        .addressSpace = 0,
        .physicalAddr = 0,
        .limit = 0,
        .cacheSnoop = 0,
        .hclass = nvrm.GA102_DISP_CURSOR,
        .channelInstance = head,
        .valid = 0, // (oclass & 0xff) == 0x7a → no pushbuffer (r535 disp.c:108)
        .pbTargetAperture = 0,
        .channelPBSize = 0,
        .subDeviceId = nvrm.DISP_SUBDEVICE_ID_BIT0,
    };
    {
        const p: [*]u8 = @ptrCast(&pbp);
        try rm.control(g, subdevice, nvrm.CTRL_INTERNAL_DISPLAY_CHANNEL_PUSHBUFFER, p[0..@sizeOf(nvrm.ChannelPushbufferParams)]);
    }
    const hObject: u32 = (nvrm.GA102_DISP_CURSOR << 16) | head;
    var pio = nvrm.ChannelPioAllocParams{
        .channelInstance = head,
        .hObjectNotify = 0,
        .pControl = 0,
    };
    {
        const p: [*]const u8 = @ptrCast(&pio);
        try rm.allocObject(g, nvrm.RM_CLIENT0, dispRoot, hObject, nvrm.GA102_DISP_CURSOR, p[0..@sizeOf(nvrm.ChannelPioAllocParams)]);
    }
    const user_base = CURS_USER_BASE + @as(u64, head) * USER_STRIDE;
    log("gpu.chan: CURSOR PIO OK (obj=0x{x}, head={}, user=0x{x})\n", .{ hObject, head, user_base });
    return user_base;
}

/// Move the HW cursor: two MMIO writes into the cursor USER page —
/// SET_CURSOR_HOT_SPOT_POINT_OUT (x low/y high 16 bits) then UPDATE=1. The HW
/// subtracts the image hotspot; coordinates are head-raster pixels. No flush
/// handshake (PIO, not a VRAM pushbuffer).
pub fn cursorMove(regs: mmio.Mapping, user_base: u64, x: i32, y: i32) void {
    const xv: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
    const yv: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
    regs.write32(user_base + CURS_POINT_OUT, xv | (yv << 16));
    regs.write32(user_base + CURS_UPDATE, 1);
}

/// Allocate the WIMM channel (class 0xc67b, instance = window index). USER window is
/// strided by the WINDOW INDEX: 0x6b0000 + window*0x1000. (Was head*0x1000 — the
/// bug that left head 1's WIMM PUT writing to the wrong USER window, so its channel
/// never drained; GET stayed 0 → head 1 dark.)
pub fn wimmChannelInit(g: gsp.Gsp, valloc: *vram.Allocator, dispRoot: u32, subdevice: u32, window: u32) Error!CoreChan {
    return channelInit(g, valloc, dispRoot, subdevice, nvrm.GA102_DISP_WINDOW_IMM_CHANNEL_DMA, window, WIMM_USER_BASE + @as(u64, window) * USER_STRIDE);
}

/// Allocate a disp DMA channel of `hclass` at `instance` (handle (hclass<<16)|inst)
/// over the booted GSP-RM, with its USER window at `user_base`. `dispRoot` is the
/// AD102_DISP root; `subdevice` is the CHANNEL_PUSHBUFFER ctrl target. Fails loudly.
fn channelInit(g: gsp.Gsp, valloc: *vram.Allocator, dispRoot: u32, subdevice: u32, hclass: u32, instance: u32, user_base: u64) Error!CoreChan {
    // 1. Allocate + zero the 4 KiB page-aligned VRAM pushbuffer.
    const pb = try valloc.alloc(PB_SIZE, PB_SIZE);
    vram.fill(g.regs, pb, PB_SIZE, 0);
    log("gpu.chan: cls=0x{x} inst={} pushbuffer @0x{x}\n", .{ hclass, instance, pb });

    // 2. CHANNEL_PUSHBUFFER ctrl (0x20800a58) → subdevice (r570 set_pushbuf).
    var pbp = nvrm.ChannelPushbufferParams{
        .addressSpace = nvrm.ADDR_FBMEM,
        .physicalAddr = pb,
        .limit = PB_SIZE - 1,
        .cacheSnoop = 0,
        .hclass = hclass,
        .channelInstance = instance,
        .valid = 1,
        .pbTargetAperture = nvrm.PBTARGET_PHYS_NVM,
        .channelPBSize = nvrm.DISP_CHANNEL_PB_SIZE_4KB,
        .subDeviceId = nvrm.DISP_SUBDEVICE_ID_BIT0,
    };
    {
        const p: [*]u8 = @ptrCast(&pbp);
        try rm.control(g, subdevice, nvrm.CTRL_INTERNAL_DISPLAY_CHANNEL_PUSHBUFFER, p[0..@sizeOf(nvrm.ChannelPushbufferParams)]);
    }

    // 3. CHANNELDMA alloc — handle (hclass<<16)|instance, parent = disp root.
    const hObject: u32 = (hclass << 16) | instance;
    var dma = nvrm.ChannelDmaAllocParams{
        .channelInstance = instance,
        .hObjectBuffer = 0,
        .hObjectNotify = 0,
        .offset = 0,
        .pControl = 0,
        .flags = 0,
        .channelPBSize = nvrm.DISP_CHANNEL_PB_SIZE_4KB,
        .subDeviceId = nvrm.DISP_SUBDEVICE_ID_BIT0,
    };
    {
        const p: [*]const u8 = @ptrCast(&dma);
        try rm.allocObject(g, nvrm.RM_CLIENT0, dispRoot, hObject, hclass, p[0..@sizeOf(nvrm.ChannelDmaAllocParams)]);
    }
    log("gpu.chan: CHANNELDMA OK (obj=0x{x}, parent=0x{x}, user=0x{x})\n", .{ hObject, dispRoot, user_base });

    return .{ .pb_phys = pb, .pb_size = PB_SIZE, .put = 0, .user_base = user_base };
}

/// Flush a staged method-dword stream into the pushbuffer at the PUT cursor and
/// kick the channel: VRAM-flush handshake, then advance PUT.
pub fn submit(self: *CoreChan, regs: mmio.Mapping, push: Push) Error!void {
    const n = push.n;
    if (n > PB_MAX_DWORDS) {
        log("gpu.chan: pushbuf overflow: {} > {}\n", .{ n, PB_MAX_DWORDS });
        return error.ChannelPushbufTooBig;
    }
    if (self.put + n + 1 > PB_MAX_DWORDS) {
        // Ring wrap: JUMP-to-0 and reuse the start, waiting ONLY for GET to depart the
        // start — not a full drain (windAtWrap; nouveau nv50_dmac_wind parity). Full-
        // draining here was the residual flip-submit stall (pushbuffer
        // ring reuse): a NON_TEARING interval=1 flip's UPDATE isn't consumed until its
        // vblank latch, so GET lags PUT and a drain-wait cost a whole refresh.
        try self.windAtWrap(regs);
    }
    // After a wrap `put` is 0, so `n` (≤ PB_MAX_DWORDS) always fits; away from a wrap,
    // ensure the engine's GET has freed enough room ahead of the write cursor before we
    // overwrite it (nouveau nv50_dmac_wait: free measured vs GET, stay 5 behind — never
    // a full drain). Bounded; under a live flip stream GET keeps advancing so this rarely
    // blocks. A co-flipped overlay channel that wrapped a frame behind waits here briefly.
    if (self.put != 0) {
        const deadline = tsc.rdtsc() + tsc.msTicks(DRAIN_TIMEOUT_MS);
        while (self.freeDwords(regs) < n) {
            if (tsc.rdtsc() >= deadline) {
                log("gpu.chan: ring-free timeout: free<{} (GET={} PUT={})\n", .{ n, self.readGet(regs), self.put });
                return error.ChannelPushbufTooBig;
            }
            asm volatile ("pause");
        }
    }
    push.flushTo(regs, self.pb_phys + @as(u64, self.put) * 4);
    try vramFlush(regs);

    self.put += @intCast(n);
    regs.write32(self.user_base + USER_PUT, @as(u32, self.put) << 2);
}

/// The VRAM write-flush handshake preceding every PUT kick (nv50_dmac_kick,
/// disp.c:145-149): write 1 to 0x070000, then poll until bit1 CLEARS — bit1 is
/// a BUSY flag, not a done flag (waiting for it to become set inverts the
/// handshake and provides no ordering guarantee). 2 s wall-clock budget.
fn vramFlush(regs: mmio.Mapping) Error!void {
    regs.write32(VRAM_FLUSH, VRAM_FLUSH_PENDING);
    const flush_deadline = tsc.rdtsc() + tsc.msTicks(DRAIN_TIMEOUT_MS);
    while ((regs.read32(VRAM_FLUSH) & VRAM_FLUSH_BUSY) != 0) {
        if (tsc.rdtsc() >= flush_deadline) {
            log("gpu.chan: VRAM-flush handshake timeout (0x070000=0x{x})\n", .{regs.read32(VRAM_FLUSH)});
            return error.VramFlushTimeout;
        }
        asm volatile ("pause");
    }
}
