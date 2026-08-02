//! GR (3D) engine bring-up: golden-context staging, the GR GPFIFO channel,
//! the ADA_A (0xc997) object, the P1 heartbeat fence, and the one-time
//! channel context init every rendered frame relies on.
//!
//! Builds on the GPU driver's channel, memory and firmware machinery and adds
//! only what the 3D engine needs on top:
//!
//!   1. golden staging (once): throwaway GR channel on a fresh VA space →
//!      ctx-buffer size query → allocate all 9 buffers → PROMOTE_CTX(golden)
//!      → alloc 0xc997 → free everything (GSP caches the golden context)
//!   2. user GR channel (chid 2): same GPFIFO machinery as the CE channel but
//!      engineType GR0, sharing the CE channel's VA space, plus
//!      PROMOTE_CTX(per-channel) BEFORE its own 0xc997 alloc
//!   3. heartbeat: SET_OBJECT on subchannel 0 + host semaphore release —
//!      proves the GR engine schedules and completes (netdebug GRBEAT)
//!   4. initContext: the context-init method stream (minimal init + the
//!      bisected NVK full-init prefix), fenced — rendering (opengl.zig)
//!      assumes this channel state
//!
//! The consumer of all of this is opengl.zig, which renders the windows.

const std = @import("std");
const log = @import("../../gpu/base/log.zig").gpu;
const gsp = @import("../../gpu/gsp/gsp.zig");
const rm = @import("../../gpu/gsp/rm.zig");
const nvrm = @import("../../gpu/base/nvrm.zig");
const vram = @import("../../gpu/core/vram.zig");
const gmmu = @import("../../gpu/core/gmmu.zig");
const shim = @import("../../gpu/base/shim.zig");
const fifo = @import("../../gpu/core/fifo.zig");
const hostpush = @import("hostpush");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const methods = @import("../ada/methods.zig");
const ctx_init_full = @import("../ada/ctx_init_full.zig");

pub const Error = error{ GrSysmemAlloc, GrBadCtxBufSize, GrVaExhausted } || fifo.Error;

/// 3D class binds on subchannel 0 (NVK convention).
pub const SUBCH_3D: u32 = 0;

const GR_CHID: u32 = 2; // CE channel is 1; golden uses 3 (never concurrent)
const GOLDEN_CHID: u32 = 3;
const GPFIFO_ENTRIES: u32 = 512;
const USERD_SIZE: u64 = 0x200;

/// The 9-entry GR context-buffer table (r535_gr_get_ctxbuf_info map[]):
/// query engine-id → promote bufferId + flags.
const CtxBufDesc = struct {
    engine_id: u32,
    buffer_id: u16,
    global: bool,
    init: bool,
    ro: bool,
};
const CTXBUFS = [_]CtxBufDesc{
    .{ .engine_id = 0x00, .buffer_id = nvrm.GrBufferId.MAIN, .global = false, .init = true, .ro = false },
    .{ .engine_id = 0x0d, .buffer_id = nvrm.GrBufferId.PAGEPOOL, .global = true, .init = false, .ro = false },
    .{ .engine_id = 0x10, .buffer_id = nvrm.GrBufferId.PATCH, .global = false, .init = true, .ro = false },
    .{ .engine_id = 0x11, .buffer_id = nvrm.GrBufferId.BUFFER_BUNDLE_CB, .global = true, .init = false, .ro = false },
    .{ .engine_id = 0x13, .buffer_id = nvrm.GrBufferId.ATTRIBUTE_CB, .global = true, .init = false, .ro = false },
    .{ .engine_id = 0x14, .buffer_id = nvrm.GrBufferId.RTV_CB_GLOBAL, .global = true, .init = false, .ro = false },
    .{ .engine_id = 0x17, .buffer_id = nvrm.GrBufferId.FECS_EVENT, .global = true, .init = true, .ro = false },
    .{ .engine_id = 0x18, .buffer_id = nvrm.GrBufferId.PRIV_ACCESS_MAP, .global = true, .init = true, .ro = true },
    // UNRESTRICTED_PRIV_ACCESS_MAP duplicates PRIV_ACCESS_MAP's storage
    // (gr.c:240-248) and is promoted only in the golden pass (gr.c:98-100).
    .{ .engine_id = 0x18, .buffer_id = nvrm.GrBufferId.UNRESTRICTED_PRIV_ACCESS_MAP, .global = true, .init = true, .ro = true },
};

/// One allocated ctx buffer: phys always; per-address-space VAs are assigned
/// at promote time (golden VMM for the golden pass, the shared VMM per-chan).
const CtxBuf = struct {
    phys: u64,
    size: u64,
    page_shift: u6,
    va_align: u64,
};

/// The live GR channel + its 0xc997 object.
pub const Gr = struct {
    chan: u32, // RM handle
    threed: u32, // RM handle
    chid: u32,
    runlist: u32,
    inst_phys: u64,
    userd_phys: u64,
    ring_phys: u64,
    push_phys: u64,
    sem_phys: u64,
    gp_put: u32,
    fence: u32,

    /// Begin staging into the GR pushbuffer page.
    pub fn beginPush(self: *Gr) hostpush.HostPush {
        return hostpush.HostPush.init(self.push_phys, 0x1000);
    }

    pub fn nextFence(self: *Gr) u32 {
        self.fence +%= 1;
        if (self.fence == 0) self.fence = 1;
        return self.fence;
    }

    /// Kick the staged stream on the GR channel and wait for `want` at the GR
    /// semaphore. Same machinery as the CE channel (fifo.kickChannel/pollSem).
    pub fn submitWait(self: *Gr, g: gsp.Gsp, p: *hostpush.HostPush, want: u32) Error!u64 {
        try self.submit(g, p, gmmu.VA_GR_PUSH, self.push_phys);
        return fifo.pollSem(g, self.userd_phys, self.gp_put, self.sem_phys, want);
    }

    /// Kick WITHOUT waiting, from an arbitrary mapped push page — the GL
    /// context pool submits every context's frames through here (opengl.zig,
    /// each context from its OWN page so N frames queue concurrently). The
    /// caller must not rewrite `push_phys` until its fence reports the kicked
    /// stream retired. A wedged ring is propagated as fifo.Error.FifoRingStuck
    /// for the caller to handle, never a panic.
    pub fn submit(self: *Gr, g: gsp.Gsp, p: *hostpush.HostPush, push_va: u64, push_phys: u64) Error!void {
        try fifo.kickChannel(g, self.userd_phys, self.ring_phys, push_va, push_phys, p.bytes(), &self.gp_put, self.runlist, self.chid);
    }

    /// P1 heartbeat: bind ADA_A to subchannel 0, then a host semaphore release.
    /// Completion proves channel fetch, SET_OBJECT engine bind, and the GR
    /// runlist scheduling this channel — the whole P1 surface.
    pub fn heartbeat(self: *Gr, g: gsp.Gsp) Error!void {
        var p = self.beginPush();
        p.incr(SUBCH_3D, 0x0000, 1); // SET_OBJECT
        p.data(nvrm.ADA_A & 0xffff); // class 15:0, engine_id 20:16 = 0
        const fence = self.nextFence();
        semRelease(&p, gmmu.VA_GR_SEM, fence);
        const dt = try self.submitWait(g, &p, fence);
        log("gl.gr: GRBEAT fence={} us={}\n", .{ fence, tsc.ticksToUs(dt) });
    }

    /// One-time GR channel context init (bring-up, right after the heartbeat):
    /// the known-good minimal init, then the first BISECT_N dwords
    /// (packet-aligned) of the full NVK init stream layered on top. Neither half
    /// works alone: the full stream hangs the first draw, the minimal one hangs
    /// the first Z op.
    /// Fenced behind a WFI so the state is committed before the first frame.
    /// Every later render (opengl.zig) assumes this channel state.
    pub fn initContext(self: *Gr, g: gsp.Gsp) Error!void {
        var p = self.beginPush();
        methods.ctxInit(&p, gmmu.VA_GR_ZERO);
        var full_buf: [512]u32 = undefined;
        var pf = hostpush.HostPush.init(@intFromPtr(&full_buf), full_buf.len * 4);
        ctx_init_full.emit(&pf, gmmu.VA_GR_ZERO);
        const copied = copyPackets(&p, full_buf[0 .. pf.bytes() / 4], BISECT_N);
        log("gl.gr: ctx init: {}/{} full-init dwords layered\n", .{ copied, pf.bytes() / 4 });
        p.incr(hostpush.SUBCH_HOST, hostpush.WFI, 1); // WFI: context state committed
        p.data(0);
        const fence = self.nextFence();
        semRelease(&p, gmmu.VA_GR_SEM, fence);
        _ = try self.submitWait(g, &p, fence);
    }
};

/// How many dwords (packet-aligned) of the NVK full init to layer on top of
/// the minimal init (initContext). The full stream is ~234 dwords; 175 is the
/// longest prefix the 4090 accepts without hanging.
const BISECT_N: usize = 175;

/// Copy whole GPFIFO packets from `words` into `dst` until adding the next
/// packet would exceed `max_words`. Returns dwords copied. Header: SEC_OP in
/// bits 31:29 (INC=1 carries COUNT<<16 data dwords; IMMD=4 carries none).
fn copyPackets(dst: *hostpush.HostPush, words: []const u32, max_words: usize) usize {
    var i: usize = 0;
    while (i < words.len) {
        const hdr = words[i];
        const secop = hdr >> 29;
        const n: usize = if (secop == 1) 1 + ((hdr >> 16) & 0x1fff) else 1;
        if (i + n > max_words) break;
        var k: usize = 0;
        while (k < n) : (k += 1) dst.data(words[i + k]);
        i += n;
    }
    return i;
}

/// NVC36F host semaphore release (methods 0x5c-0x6c, engine-agnostic — same
/// stream ce.semRelease emits; duplicated here so gl/ does not depend on the
/// CE module for host methods.)
/// Pub: opengl.zig fences its GR frames with the same release.
pub fn semRelease(p: *hostpush.HostPush, sem_va: u64, payload: u32) void {
    p.incr(hostpush.SUBCH_HOST, 0x5c, 5); // SEM_ADDR_LO..SEM_EXECUTE
    p.data(@truncate(sem_va)); // SEM_ADDR_LO
    p.data(@intCast(sem_va >> 32)); // SEM_ADDR_HI
    p.data(payload); // SEM_PAYLOAD_LO
    p.data(0); // SEM_PAYLOAD_HI
    p.data(0x1); // SEM_EXECUTE: RELEASE, 32-bit payload
}

/// NVC36F host semaphore ACQUIRE: stall the channel until the 32-bit word at
/// `sem_va` EQUALS `payload`. opengl.zig chains each frame's CE de-tile behind
/// its GR render fence GPU-side with this — no CPU in the render→de-tile
/// handoff. The acquire blocks every later method on that channel until it
/// passes.
pub fn semAcquire(p: *hostpush.HostPush, sem_va: u64, payload: u32) void {
    p.incr(hostpush.SUBCH_HOST, 0x5c, 5); // SEM_ADDR_LO..SEM_EXECUTE
    p.data(@truncate(sem_va)); // SEM_ADDR_LO
    p.data(@intCast(sem_va >> 32)); // SEM_ADDR_HI
    p.data(payload); // SEM_PAYLOAD_LO
    p.data(0); // SEM_PAYLOAD_HI
    p.data(0x0); // SEM_EXECUTE: ACQUIRE (equality), 32-bit payload
}

/// VA bump allocator over the VA_GRCTX window (one per VMM the buffers are
/// promoted into). ATTRIBUTE_CB's alignment can reach 128 MiB.
const VaBump = struct {
    cursor: u64,

    fn take(self: *VaBump, size: u64, alignment: u64) Error!u64 {
        const va = std.mem.alignForward(u64, self.cursor, alignment);
        if (va + size > gmmu.VA_GRCTX + gmmu.GRCTX_SIZE) return error.GrVaExhausted;
        self.cursor = va + size;
        return va;
    }
};

/// Query GR0's context-buffer sizes (ctrl 0x20800a32, r570 1664 B layout) and
/// allocate the 9 buffers in VRAM per the size/alignment rules of gr.c:216-226.
/// UNRESTRICTED_PRIV_ACCESS_MAP shares PRIV_ACCESS_MAP's storage.
fn allocCtxBufs(g: gsp.Gsp, valloc: *vram.Allocator, subdevice: u32, bufs: *[CTXBUFS.len]CtxBuf) Error!void {
    var info = std.mem.zeroes(nvrm.GrCtxBuffersInfoParams);
    {
        const p: [*]u8 = @ptrCast(&info);
        try rm.control(g, subdevice, nvrm.CTRL_KGR_GET_CONTEXT_BUFFERS_INFO, p[0..@sizeOf(nvrm.GrCtxBuffersInfoParams)]);
    }
    for (CTXBUFS, 0..) |desc, i| {
        if (desc.buffer_id == nvrm.GrBufferId.UNRESTRICTED_PRIV_ACCESS_MAP) {
            bufs[i] = bufs[i - 1]; // alias of PRIV_ACCESS_MAP (gr.c:240-248)
            continue;
        }
        var size: u64 = info.engineContextBuffersInfo[0][desc.engine_id].size;
        if (size == 0) {
            log("gl.gr: ctx buffer engine_id=0x{x} has size 0\n", .{desc.engine_id});
            return error.GrBadCtxBufSize;
        }
        if (desc.buffer_id == nvrm.GrBufferId.MAIN)
            size = std.mem.alignForward(u64, size, 0x1000) + 64 * 0x1000;
        const page_shift: u6 = if (size >= 2 * 1024 * 1024) 21 else if (size >= 64 * 1024) 16 else 12;
        size = std.mem.alignForward(u64, size, @as(u64, 1) << page_shift);
        const phys = try valloc.alloc(size, @as(u64, 1) << page_shift);
        if (desc.init) vram.fill(g.regs, phys, size, 0);
        const va_align: u64 = if (desc.buffer_id == nvrm.GrBufferId.ATTRIBUTE_CB)
            std.math.ceilPowerOfTwo(u64, size) catch return error.GrBadCtxBufSize
        else
            @as(u64, 1) << page_shift;
        bufs[i] = .{ .phys = phys, .size = size, .page_shift = page_shift, .va_align = va_align };
        log("gl.gr: ctxbuf id={} size=0x{x} @0x{x} (pg=2^{}, va_align=0x{x})\n", .{ desc.buffer_id, size, phys, page_shift, va_align });
    }
}

/// PROMOTE_CTX (0x2080012b). golden=true: promote all 9 buffers with phys+size
/// for the init ones; golden=false: skip UNRESTRICTED, re-promote with fresh
/// VAs in the target VMM, bInitialize only for the per-channel (non-global)
/// buffers. Every non-bNonmapped entry is mapped into `mmu` here.
fn promoteCtx(g: gsp.Gsp, subdevice: u32, hChan: u32, mmu: *gmmu.Gmmu, bump: *VaBump, bufs: *const [CTXBUFS.len]CtxBuf, golden: bool) Error!void {
    var params = std.mem.zeroes(nvrm.PromoteCtxParams);
    params.engineType = nvrm.NV2080_ENGINE_TYPE_GR0;
    params.hChanClient = nvrm.RM_CLIENT0;
    params.hObject = hChan;
    for (CTXBUFS, 0..) |desc, i| {
        const alloc_now = golden or !desc.global;
        if (!golden and desc.buffer_id == nvrm.GrBufferId.UNRESTRICTED_PRIV_ACCESS_MAP) continue;
        const e = &params.promoteEntry[params.entryCount];
        e.bufferId = desc.buffer_id;
        e.bInitialize = if (desc.init and alloc_now) 1 else 0;
        // bNonmapped only for PRIV_ACCESS_MAP while allocating (gr.c:94-96).
        if (alloc_now and desc.buffer_id == nvrm.GrBufferId.PRIV_ACCESS_MAP) e.bNonmapped = 1;
        if (e.bNonmapped == 0) {
            const va = try bump.take(bufs[i].size, bufs[i].va_align);
            try mmu.mapVram(va, bufs[i].phys, bufs[i].size);
            e.gpuVirtAddr = va;
        }
        if (e.bInitialize == 1) {
            e.gpuPhysAddr = bufs[i].phys;
            e.size = bufs[i].size;
            e.physAttr = 4;
        }
        log("gl.gr: promote id={} pa=0x{x} va=0x{x} sz=0x{x} init={} nm={}\n", .{ e.bufferId, e.gpuPhysAddr, e.gpuVirtAddr, e.size, e.bInitialize, e.bNonmapped });
        params.entryCount += 1;
    }
    const p: [*]u8 = @ptrCast(&params);
    try rm.control(g, subdevice, nvrm.CTRL_GPU_PROMOTE_CTX, p[0..@sizeOf(nvrm.PromoteCtxParams)]);
}

/// Allocate a GR GPFIFO channel: instance block (+ optional PDB join), USERD,
/// channel alloc (engineType GR0), BIND, SCHEDULE. Mirrors fifo.init's CE
/// channel field-for-field (only engineType differs).
fn allocGrChannel(g: gsp.Gsp, objs: rm.RmObjects, hVaspace: u32, chid: u32, inst: u64, userd: u64, ring_va: u64, mthdbuf: u64, mthdbuf_size: u32) Error!u32 {
    const hChan: u32 = (nvrm.AMPERE_CHANNEL_GPFIFO_A << 16) | chid;
    var cp = std.mem.zeroes(nvrm.ChannelGpfifoAllocParams);
    cp.gpFifoOffset = ring_va;
    cp.gpFifoEntries = GPFIFO_ENTRIES;
    cp.flags = (1 << 5) | ((chid % 8) << 8) | ((chid / 8) << 12) | (1 << 21);
    cp.hVASpace = hVaspace;
    cp.engineType = nvrm.NV2080_ENGINE_TYPE_GR0;
    cp.instanceMem = .{ .base = inst, .size = 0x1000, .addressSpace = nvrm.ADDR_SPACE_VIDMEM, .cacheAttrib = 1 };
    cp.userdMem = .{ .base = userd, .size = USERD_SIZE, .addressSpace = nvrm.ADDR_SPACE_VIDMEM, .cacheAttrib = 1 };
    cp.ramfcMem = .{ .base = inst, .size = 0x200, .addressSpace = nvrm.ADDR_SPACE_VIDMEM, .cacheAttrib = 1 };
    // Declared SYSMEM in both uses: real sysmem for the user channel; the
    // golden channel's points at VRAM but is never fetched (nouveau does the
    // same — fifo.c:138-141, mirrored deliberately).
    cp.mthdbufMem = .{ .base = mthdbuf, .size = mthdbuf_size, .addressSpace = nvrm.ADDR_SPACE_SYSMEM, .cacheAttrib = 0 };
    cp.internalFlags = 1 | (1 << 2) | (1 << 4); // ADMIN, notifiers NONE
    {
        const p: [*]const u8 = @ptrCast(&cp);
        try rm.allocObject(g, nvrm.RM_CLIENT0, objs.device, hChan, nvrm.AMPERE_CHANNEL_GPFIFO_A, p[0..@sizeOf(nvrm.ChannelGpfifoAllocParams)]);
    }
    var bind = nvrm.GpfifoBindParams{ .engineType = nvrm.NV2080_ENGINE_TYPE_GR0 };
    {
        const p: [*]u8 = @ptrCast(&bind);
        try rm.control(g, hChan, nvrm.CTRL_GPFIFO_BIND, p[0..@sizeOf(nvrm.GpfifoBindParams)]);
    }
    var sched = nvrm.GpfifoScheduleParams{ .bEnable = 1, .bSkipSubmit = 0 };
    {
        const p: [*]u8 = @ptrCast(&sched);
        try rm.control(g, hChan, nvrm.CTRL_GPFIFO_SCHEDULE, p[0..@sizeOf(nvrm.GpfifoScheduleParams)]);
    }
    return hChan;
}

/// Fault-method buffer size (same ctrl the CE channel uses — nouveau allocates
/// a mthdbuf for every channel, r535/fifo.c:177-181).
fn mthdbufSize(g: gsp.Gsp, subdevice: u32) Error!u32 {
    var fmb = extern struct { size: u32 }{ .size = 0 };
    const p: [*]u8 = @ptrCast(&fmb);
    try rm.control(g, subdevice, nvrm.CTRL_CE_GET_FAULT_METHOD_BUFFER_SIZE, p[0..4]);
    if (fmb.size == 0 or fmb.size > 0x10000) {
        log("gl.gr: bad fault-method buffer size {}\n", .{fmb.size});
        return error.GrBadCtxBufSize;
    }
    return fmb.size;
}

/// Stage the golden context (once per boot): throwaway GR
/// channel on a FRESH VA space (mirroring nouveau exactly — its golden channel
/// gets its own VMM), all 9 ctx buffers, PROMOTE_CTX(golden), 0xc997 alloc,
/// then free object + channel + vaspace. The ctx buffers live on as the global
/// set; the golden VMM's page tables leak a few VRAM pages (one-time, by
/// design — the bump VRAM allocator has no free).
fn goldenInit(g: gsp.Gsp, valloc: *vram.Allocator, objs: rm.RmObjects, bufs: *[CTXBUFS.len]CtxBuf) Error!void {
    // Fresh vaspace + page tables + mandatory server-PDE handoff.
    const hVaspace: u32 = (nvrm.FERMI_VASPACE_A << 16) | 1;
    var vsp = std.mem.zeroes(nvrm.VaspaceAllocParams);
    {
        const p: [*]const u8 = @ptrCast(&vsp);
        try rm.allocObject(g, nvrm.RM_CLIENT0, objs.device, hVaspace, nvrm.FERMI_VASPACE_A, p[0..@sizeOf(nvrm.VaspaceAllocParams)]);
    }
    var mmu = try gmmu.Gmmu.init(g.regs, valloc);
    var pdes = std.mem.zeroes(nvrm.CopyServerReservedPdesParams);
    pdes.pageSize = 1 << 29;
    pdes.virtAddrLo = nvrm.SPLIT_VAS_SERVER_VA_START;
    pdes.virtAddrHi = nvrm.SPLIT_VAS_SERVER_VA_START + nvrm.SPLIT_VAS_SERVER_VA_SIZE - 1;
    pdes.numLevelsToCopy = 3;
    pdes.levels[0] = .{ .physAddress = mmu.root, .size = 4 * 8, .aperture = 1, .pageShift = 47 };
    pdes.levels[1] = .{ .physAddress = mmu.l3, .size = 0x1000, .aperture = 1, .pageShift = 38 };
    pdes.levels[2] = .{ .physAddress = mmu.l2, .size = 0x1000, .aperture = 1, .pageShift = 29 };
    {
        const p: [*]u8 = @ptrCast(&pdes);
        try rm.control(g, hVaspace, nvrm.CTRL_VASPACE_COPY_SERVER_RESERVED_PDES, p[0..@sizeOf(nvrm.CopyServerReservedPdesParams)]);
    }

    // Throwaway channel block: 0x12000 zeroed VRAM — inst @+0, userd page
    // @+0x1000, mthdbuf @+0x2000. Quirks mirrored from nouveau (gr.c:289-306):
    // NO CPU VMM join (the channel never fetches; RM/FECS works from the
    // promoted phys addrs) and mthdbufMem declared SYSMEM while pointing at
    // VRAM (bogus but unused).
    const block = try valloc.alloc(0x12000, 0x1000);
    vram.fill(g.regs, block, 0x12000, 0);
    const inst = block;
    const userd = block + 0x1000 + GOLDEN_CHID * USERD_SIZE;
    const mthdbuf = block + 0x2000;
    const fmb_size = try mthdbufSize(g, objs.subdevice);
    const hChan = try allocGrChannel(g, objs, hVaspace, GOLDEN_CHID, inst, userd, 0, mthdbuf, fmb_size);
    log("gl.gr: golden channel OK (obj=0x{x} chid={})\n", .{ hChan, GOLDEN_CHID });

    // Ctx buffers (the global set — lives on after the golden teardown).
    try allocCtxBufs(g, valloc, objs.subdevice, bufs);
    var bump = VaBump{ .cursor = gmmu.VA_GRCTX };
    try promoteCtx(g, objs.subdevice, hChan, &mmu, &bump, bufs, true);

    // First ADA_A alloc → GSP creates + caches the golden context (argc=0).
    const hThreed: u32 = 0x97000000;
    try rm.allocObject(g, nvrm.RM_CLIENT0, hChan, hThreed, nvrm.ADA_A, &.{});
    log("gl.gr: golden 0xc997 alloc OK — GSP golden context created\n", .{});

    // Teardown: object, channel, vaspace (RM caches the context, gr.c:329-332).
    try rm.freeObject(g, nvrm.RM_CLIENT0, hThreed);
    try rm.freeObject(g, nvrm.RM_CLIENT0, hChan);
    try rm.freeObject(g, nvrm.RM_CLIENT0, hVaspace);
    log("gl.gr: golden staging complete\n", .{});
}

/// Bring up the GR engine: golden staging, then the user GR channel (chid 2)
/// sharing the CE channel's VA space, per-channel PROMOTE_CTX, the 0xc997
/// object, and the P1 heartbeat.
pub fn init(g: gsp.Gsp, valloc: *vram.Allocator, objs: rm.RmObjects, f: *fifo.Fifo) Error!Gr {
    var bufs: [CTXBUFS.len]CtxBuf = undefined;
    try goldenInit(g, valloc, objs, &bufs);

    // Ring / push / sem sysmem pages in the SHARED VA space.
    const ring = shim.allocPagesPhys(1) orelse return error.GrSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(ring))[0..0x1000], 0);
    try f.mmu.mapSysmem(gmmu.VA_GR_RING, ring, 0x1000);
    const push = shim.allocPagesPhys(1) orelse return error.GrSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(push))[0..0x1000], 0);
    try f.mmu.mapSysmem(gmmu.VA_GR_PUSH, push, 0x1000);
    const sem = shim.allocPagesPhys(1) orelse return error.GrSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(sem))[0..0x1000], 0);
    shim.flushRange(sem, 0x1000);
    try f.mmu.mapSysmem(gmmu.VA_GR_SEM, sem, 0x1000);
    // All-zero page: substitute source for disabled vertex streams (ctxInit).
    const zero = shim.allocPagesPhys(1) orelse return error.GrSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(zero))[0..0x1000], 0);
    shim.flushRange(zero, 0x1000);
    try f.mmu.mapSysmem(gmmu.VA_GR_ZERO, zero, 0x1000);

    // Instance block WITH the CPU VMM join (this channel does fetch), USERD.
    const inst = try valloc.alloc(0x1000, 0x1000);
    vram.fill(g.regs, inst, 0x1000, 0);
    const pdb: u64 = f.mmu.root | (1 << 10) | (1 << 11);
    const va_limit: u64 = (1 << 47) - 1;
    vram.write32(g.regs, inst + 0x200, @truncate(pdb));
    vram.write32(g.regs, inst + 0x204, @truncate(pdb >> 32));
    vram.write32(g.regs, inst + 0x208, @truncate(va_limit));
    vram.write32(g.regs, inst + 0x20c, @truncate(va_limit >> 32));
    const userd_page = try valloc.alloc(0x1000, 0x1000);
    vram.fill(g.regs, userd_page, 0x1000, 0);
    const userd = userd_page + GR_CHID * USERD_SIZE;

    // Real sysmem fault-method buffer for the user channel.
    const fmb_size = try mthdbufSize(g, objs.subdevice);
    const mthdbuf_pages: u32 = (fmb_size + 0xfff) / 0x1000;
    const mthdbuf = shim.allocPagesPhys(mthdbuf_pages) orelse return error.GrSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(mthdbuf))[0 .. @as(u64, mthdbuf_pages) * 0x1000], 0);

    const hChan = try allocGrChannel(g, objs, f.vaspace, GR_CHID, inst, userd, gmmu.VA_GR_RING, mthdbuf, fmb_size);
    const runlist = try fifo.engineRunlist(g, objs.subdevice, nvrm.NV2080_ENGINE_TYPE_GR0);
    log("gl.gr: user channel OK (obj=0x{x} chid={} runlist={})\n", .{ hChan, GR_CHID, runlist });

    // Per-channel MAIN + PATCH are FRESH allocations (alloc = !global in
    // gr.c:82 — the golden pass's MAIN/PATCH belonged to the freed golden
    // channel and are not reused). Globals keep the golden pass's storage.
    for (CTXBUFS, 0..) |desc, i| {
        if (desc.global) continue;
        const phys = try valloc.alloc(bufs[i].size, @as(u64, 1) << bufs[i].page_shift);
        if (desc.init) vram.fill(g.regs, phys, bufs[i].size, 0);
        bufs[i].phys = phys;
    }

    // Per-channel promote (fresh VAs in the shared VMM) BEFORE the object alloc.
    var bump = VaBump{ .cursor = gmmu.VA_GRCTX + gmmu.GRCTX_SIZE / 2 };
    try promoteCtx(g, objs.subdevice, hChan, &f.mmu, &bump, &bufs, false);

    const hThreed: u32 = 0x97000001;
    try rm.allocObject(g, nvrm.RM_CLIENT0, hChan, hThreed, nvrm.ADA_A, &.{});
    log("gl.gr: 0xc997 object OK (obj=0x{x})\n", .{hThreed});

    var gr = Gr{
        .chan = hChan,
        .threed = hThreed,
        .chid = GR_CHID,
        .runlist = runlist,
        .inst_phys = inst,
        .userd_phys = userd,
        .ring_phys = ring,
        .push_phys = push,
        .sem_phys = sem,
        .gp_put = 0,
        .fence = 0,
    };
    try gr.heartbeat(g);
    try gr.initContext(g);
    return gr;
}
