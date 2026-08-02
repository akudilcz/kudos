//! Host GPFIFO channel + copy-engine object over GSP-RM (AD102, r570).
//!
//! Grounded in nouveau rm/r570/fifo.c r570_chan_alloc and rm/r535/{vmm,ce}.c.
//! Alloc order: FERMI_VASPACE_A → COPY_SERVER_RESERVED_PDES
//! → AMPERE_CHANNEL_GPFIFO_A → BIND → GPFIFO_SCHEDULE → AMPERE_DMA_COPY_B.
//! GSP owns runlists — after SCHEDULE(bEnable=1) the channel is submitted to
//! purely via CPU writes (GPFIFO entry, USERD GP_PUT, BAR0 doorbell).

const std = @import("std");
const log = @import("../base/log.zig").gpu;
const gsp = @import("../gsp/gsp.zig");
const rm = @import("../gsp/rm.zig");
const nvrm = @import("../base/nvrm.zig");
const vram = @import("vram.zig");
const gmmu = @import("gmmu.zig");
const shim = @import("../base/shim.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const hostpush = @import("hostpush");
const ce = @import("ce.zig");

pub const Error = error{ FifoSysmemAlloc, FifoBadMthdbufSize, FifoNoCopyEngine, FifoSemTimeout, FifoRingStuck } || rm.Error || gmmu.Error || error{VramOutOfMemory};

/// Doorbell register: the VFN subdev lives at BAR0+0xb80000 on Ampere/Ada
/// (ga100_vfn_new's addr arg) and the usermode aperture is +0x030000 within it
/// (ga100_vfn .user) — doorbell at +0x90: BAR0 + 0xbb0090. The 0x030000 is
/// vfn-relative, not BAR0-relative; reading it as BAR0-relative gives a dead
/// doorbell that swallows every submission silently.
const DOORBELL: u64 = 0xbb0090;
const USERD_GP_PUT: u64 = 0x8c;
const USERD_GP_GET: u64 = 0x88;

/// First driver-usable channel id: r570 reserves chid 0 (rsvd_chids = 1).
const CHID: u32 = 1;
const GPFIFO_ENTRIES: u32 = 512; // 512 × 8 B = one 4 KiB page
const USERD_SIZE: u64 = 0x200;

/// A live (scheduled) GPFIFO channel with its CE engine object.
pub const Fifo = struct {
    vaspace: u32, // RM handle
    chan: u32, // RM handle
    ce: u32, // RM handle
    chid: u32,
    runlist: u32, // COPY0's runlist id (doorbell token high half)
    inst_phys: u64, // VRAM instance block (4 KiB)
    userd_phys: u64, // this channel's USERD (within the VRAM userd page)
    ring_phys: u64, // sysmem GPFIFO ring (4 KiB)
    push_phys: u64, // sysmem pushbuffer (4 KiB, VA_PUSH)
    sem_phys: u64, // sysmem semaphore page (4 KiB, VA_SEM)
    mthdbuf_phys: u64, // sysmem CE fault-method buffer
    gp_put: u32, // next GPFIFO ring slot
    fence: u32, // monotonic fence payload (last emitted)
    mmu: gmmu.Gmmu,

    /// Submit the staged pushbuffer: flush it, write the GPFIFO ring entry,
    /// bump GP_PUT in USERD (PRAMIN), flush-read USERD, ring the doorbell.
    /// nvif_chanc36f_gpfifo_kick, one entry per submit. GP_PUT/GP_GET are
    /// RING-ENTRY INDICES modulo GPFIFO_ENTRIES (nouveau masks the cursor) —
    /// a free-running GP_PUT works until kick #512, then wedges the fullness
    /// math forever. Blocks (2 s budget) when the ring is full (one slot is
    /// kept open so GET==PUT is unambiguously "empty"); on timeout returns
    /// FifoRingStuck LOUDLY instead of panicking — a wedged GPU (Xid, engine
    /// fault) is a recoverable device failure, not a kernel-panic-worthy bug,
    /// and the present-path callers already have a disable-hooks fallback.
    pub fn kick(self: *Fifo, g: gsp.Gsp, push_bytes: u32) Error!void {
        try kickChannel(g, self.userd_phys, self.ring_phys, gmmu.VA_PUSH, self.push_phys, push_bytes, &self.gp_put, self.runlist, self.chid);
    }

    /// Poll the sysmem semaphore word until it equals `want` (2 s budget).
    pub fn waitSem(self: *Fifo, g: gsp.Gsp, want: u32) Error!u64 {
        return pollSem(g, self.userd_phys, self.gp_put, self.sem_phys, want);
    }

    /// Begin staging a submission into the (single, reused) pushbuffer page.
    /// Pair with submitSync — the fence wait guarantees the page is idle before
    /// the next begin.
    pub fn begin(self: *Fifo) hostpush.HostPush {
        return hostpush.HostPush.init(self.push_phys, 0x1000);
    }

    /// Allocate the next monotonic fence payload (stage it via ce.copyPitch's
    /// CE completion semaphore, then submitWait for it).
    pub fn nextFence(self: *Fifo) u32 {
        self.fence +%= 1;
        if (self.fence == 0) self.fence = 1;
        return self.fence;
    }

    /// Kick the staged stream and wait for `fence` (a CE completion semaphore
    /// staged by ce.copyPitch). Returns the wait duration in TSC ticks.
    pub fn submitWait(self: *Fifo, g: gsp.Gsp, p: *hostpush.HostPush, fence: u32) Error!u64 {
        try self.kick(g, p.bytes());
        return self.waitSem(g, fence);
    }

    /// Append a HOST-engine fence release, kick, and wait. The host release
    /// signals when the methods are DISPATCHED — not when async CE work
    /// completes — so this is only valid for streams with no async engine work
    /// (the heartbeat). Copies fence via ce.copyPitch's CE semaphore.
    pub fn submitSync(self: *Fifo, g: gsp.Gsp, p: *hostpush.HostPush) Error!u64 {
        const fence = self.nextFence();
        ce.semRelease(p, gmmu.VA_SEM, fence);
        return self.submitWait(g, p, fence);
    }

    /// Phase-3 heartbeat: bind CE to subch 4 + fence release, one submission.
    /// Proves the entire path: GMMU translation, GPFIFO fetch, host method
    /// decode, doorbell, fence.
    pub fn heartbeat(self: *Fifo, g: gsp.Gsp) Error!void {
        var p = self.begin();
        ce.bind(&p);
        const dt = try self.submitSync(g, &p);
        log("gpu.fifo: CE heartbeat: fence {} observed in {} us\n", .{ self.fence, tsc.ticksToUs(dt) });
    }
};

/// Channel-agnostic GPFIFO submit, shared by the CE Fifo and the GR channel: wait
/// for ring space, flush the pushbuffer, write the ring entry (push VA + dword
/// count), bump GP_PUT in USERD, flush-read, ring the doorbell. Returns
/// FifoRingStuck loudly on timeout instead of panicking — a wedged GPU (Xid,
/// engine fault) is a recoverable device failure the present path already handles
/// (disableHooks), not a reason to take down the trace/the whole kernel.
pub fn kickChannel(g: gsp.Gsp, userd_phys: u64, ring_phys: u64, push_va: u64, push_phys: u64, push_bytes: u32, gp_put: *u32, runlist: u32, chid: u32) Error!void {
    const full_deadline = tsc.rdtsc() + tsc.msTicks(2000);
    while (true) {
        const get = vram.read32(g.regs, userd_phys + USERD_GP_GET);
        const used = (gp_put.* + GPFIFO_ENTRIES - get) % GPFIFO_ENTRIES;
        if (used < GPFIFO_ENTRIES - 1) break;
        if (tsc.rdtsc() >= full_deadline) {
            log("gpu.fifo: GPFIFO ring stuck full (GP_GET={} gp_put={})\n", .{ get, gp_put.* });
            return error.FifoRingStuck;
        }
        asm volatile ("pause");
    }
    shim.flushRange(push_phys, push_bytes);
    const entry: [*]volatile u32 = @ptrFromInt(ring_phys + @as(u64, gp_put.*) * 8);
    entry[0] = @truncate(push_va);
    entry[1] = @as(u32, @intCast(push_va >> 32)) | ((push_bytes >> 2) << 10);
    shim.flushRange(ring_phys + @as(u64, gp_put.*) * 8, 8);
    gp_put.* = (gp_put.* + 1) % GPFIFO_ENTRIES;
    vram.write32(g.regs, userd_phys + USERD_GP_PUT, gp_put.*);
    _ = vram.read32(g.regs, userd_phys); // flush before the doorbell
    g.regs.write32(DOORBELL, (runlist << 16) | chid);
}

/// Channel-agnostic semaphore poll (2 s budget). Returns wait duration in TSC
/// ticks. Shared by Fifo.waitSem and the GR channel.
pub fn pollSem(g: gsp.Gsp, userd_phys: u64, gp_put: u32, sem_phys: u64, want: u32) Error!u64 {
    const sem: *volatile u32 = @ptrFromInt(sem_phys);
    const t0 = tsc.rdtsc();
    const deadline = t0 + tsc.msTicks(2000);
    while (true) {
        shim.invalidateLine(sem_phys);
        if (sem.* == want) return tsc.rdtsc() - t0;
        if (tsc.rdtsc() >= deadline) {
            log("gpu.fifo: semaphore timeout (sem=0x{x} want=0x{x} GP_GET={} GP_PUT={})\n", .{ sem.*, want, vram.read32(g.regs, userd_phys + USERD_GP_GET), gp_put });
            return error.FifoSemTimeout;
        }
        asm volatile ("pause");
    }
}

/// Bring up the host channel: VA space (+ mandatory server-PDE handoff), the
/// GPFIFO channel bound+scheduled on COPY0, and the CE object. Every RM status
/// must be 0 — any failure is loud and fatal to the caller. `g` is `*gsp.Gsp` (not
/// by value like the rest of this bring-up chain) so every persistent sysmem page
/// this function allocates (mthdbuf, GPFIFO ring, sem, push) is registered on
/// `g.dma` as it's allocated — gsp.shutdown(g) then frees them, and an error partway
/// through unwinds via `errdefer g.dma.freeAll()` instead of leaking. Every persistent
/// page must be registered, with no exceptions: one untracked allocation is enough to
/// make "a re-run does not leak memory" quietly false.
pub fn init(g: *gsp.Gsp, valloc: *vram.Allocator, objs: rm.RmObjects) Error!Fifo {
    const dma_mark = g.dma.len; // unwind point: free only what THIS call added
    errdefer {
        var i = dma_mark;
        while (i < g.dma.len) : (i += 1) shim.freePagesPhys(g.dma.entries[i].phys, g.dma.entries[i].pages);
        g.dma.len = dma_mark;
    }

    // CE fault-method buffer size (r535_fifo_ectx: ctrl 0x20802a08 on subdevice).
    var fmb = extern struct { size: u32 }{ .size = 0 };
    {
        const p: [*]u8 = @ptrCast(&fmb);
        try rm.control(g.*, objs.subdevice, nvrm.CTRL_CE_GET_FAULT_METHOD_BUFFER_SIZE, p[0..4]);
    }
    if (fmb.size == 0 or fmb.size > 0x100000) {
        log("gpu.fifo: bad CE fault-method buffer size {}\n", .{fmb.size});
        return error.FifoBadMthdbufSize;
    }
    const mthdbuf_pages: u32 = @intCast((fmb.size + 0xfff) / 0x1000);
    const mthdbuf = g.dma.alloc(mthdbuf_pages) orelse return error.FifoSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(mthdbuf))[0 .. @as(u64, mthdbuf_pages) * 0x1000], 0);
    log("gpu.fifo: CE mthdbuf {} B @0x{x}\n", .{ fmb.size, mthdbuf });

    // FERMI_VASPACE_A (index=GPU_NEW, everything else zero).
    const hVaspace: u32 = nvrm.FERMI_VASPACE_A << 16;
    var vsp = std.mem.zeroes(nvrm.VaspaceAllocParams);
    {
        const p: [*]const u8 = @ptrCast(&vsp);
        try rm.allocObject(g.*, nvrm.RM_CLIENT0, objs.device, hVaspace, nvrm.FERMI_VASPACE_A, p[0..@sizeOf(nvrm.VaspaceAllocParams)]);
    }
    log("gpu.fifo: vaspace OK (obj=0x{x})\n", .{hVaspace});

    // CPU-built GP100 page tables + the mandatory server-reserved-PDE handoff:
    // GSP splices its own PDs for VA [4GiB, 4GiB+512MiB) into our chain
    // (root→L3→L2 — the same instances that serve our low window).
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
        try rm.control(g.*, hVaspace, nvrm.CTRL_VASPACE_COPY_SERVER_RESERVED_PDES, p[0..@sizeOf(nvrm.CopyServerReservedPdesParams)]);
    }
    log("gpu.fifo: server-reserved PDEs handed to GSP (root=0x{x})\n", .{mmu.root});

    // GPFIFO ring: one sysmem page, mapped at VA_RING.
    const ring = g.dma.alloc(1) orelse return error.FifoSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(ring))[0..0x1000], 0);
    try mmu.mapSysmem(gmmu.VA_RING, ring, 0x1000);

    // Instance block (4 KiB VRAM, zeroed; RAMFC inside is written by GSP-RM) and
    // USERD (0x200 within a zeroed VRAM page; nouveau addresses the chid's slot).
    const inst = try valloc.alloc(0x1000, 0x1000);
    vram.fill(g.regs, inst, 0x1000, 0);
    // VMM join (gf100_vmm_join_/gp100_vmm_join): the CPU writes the channel's
    // PAGE_DIR_BASE into the instance block BEFORE the RM alloc — the engine
    // reads the PDB from here to translate the GPFIFO/pushbuffer VAs. Without
    // it the channel never fetches and GP_GET stays 0.
    //   +0x200 u64 = root PD phys | target VRAM(0) | BIT(10) VER2 | BIT(11) 64KiB big page
    //   +0x208 u64 = VA limit - 1
    const pdb: u64 = mmu.root | (1 << 10) | (1 << 11);
    const va_limit: u64 = (1 << 47) - 1;
    vram.write32(g.regs, inst + 0x200, @truncate(pdb));
    vram.write32(g.regs, inst + 0x204, @truncate(pdb >> 32));
    vram.write32(g.regs, inst + 0x208, @truncate(va_limit));
    vram.write32(g.regs, inst + 0x20c, @truncate(va_limit >> 32));
    const userd_page = try valloc.alloc(0x1000, 0x1000);
    vram.fill(g.regs, userd_page, 0x1000, 0);
    const userd = userd_page + CHID * USERD_SIZE;

    // AMPERE_CHANNEL_GPFIFO_A — parent = device (r570_chan_alloc field-for-field).
    const hChan: u32 = (nvrm.AMPERE_CHANNEL_GPFIFO_A << 16) | CHID;
    var cp = std.mem.zeroes(nvrm.ChannelGpfifoAllocParams);
    cp.gpFifoOffset = gmmu.VA_RING;
    cp.gpFifoEntries = GPFIFO_ENTRIES;
    // PHYSICAL | PRIVILEGED | USERD_INDEX=chid%8 | USERD_PAGE=chid/8 | PAGE_FIXED
    cp.flags = (1 << 5) | ((CHID % 8) << 8) | ((CHID / 8) << 12) | (1 << 21);
    cp.hVASpace = hVaspace;
    cp.engineType = nvrm.NV2080_ENGINE_TYPE_COPY0;
    cp.instanceMem = .{ .base = inst, .size = 0x1000, .addressSpace = nvrm.ADDR_SPACE_VIDMEM, .cacheAttrib = 1 };
    cp.userdMem = .{ .base = userd, .size = USERD_SIZE, .addressSpace = nvrm.ADDR_SPACE_VIDMEM, .cacheAttrib = 1 };
    cp.ramfcMem = .{ .base = inst, .size = 0x200, .addressSpace = nvrm.ADDR_SPACE_VIDMEM, .cacheAttrib = 1 };
    cp.mthdbufMem = .{ .base = mthdbuf, .size = fmb.size, .addressSpace = nvrm.ADDR_SPACE_SYSMEM, .cacheAttrib = 0 };
    cp.internalFlags = 1 | (1 << 2) | (1 << 4); // PRIVILEGE=ADMIN, both notifiers NONE
    {
        const p: [*]const u8 = @ptrCast(&cp);
        const bytes = p[0..@sizeOf(nvrm.ChannelGpfifoAllocParams)];
        try rm.allocObject(g.*, nvrm.RM_CLIENT0, objs.device, hChan, nvrm.AMPERE_CHANNEL_GPFIFO_A, bytes);
    }
    log("gpu.fifo: channel OK (obj=0x{x} chid={} inst@0x{x} userd@0x{x} ring@0x{x})\n", .{ hChan, CHID, inst, userd, ring });

    // BIND to COPY0, then SCHEDULE onto the GSP-owned runlist.
    var bind = nvrm.GpfifoBindParams{ .engineType = nvrm.NV2080_ENGINE_TYPE_COPY0 };
    {
        const p: [*]u8 = @ptrCast(&bind);
        try rm.control(g.*, hChan, nvrm.CTRL_GPFIFO_BIND, p[0..@sizeOf(nvrm.GpfifoBindParams)]);
    }
    var sched = nvrm.GpfifoScheduleParams{ .bEnable = 1, .bSkipSubmit = 0 };
    {
        const p: [*]u8 = @ptrCast(&sched);
        try rm.control(g.*, hChan, nvrm.CTRL_GPFIFO_SCHEDULE, p[0..@sizeOf(nvrm.GpfifoScheduleParams)]);
    }
    log("gpu.fifo: channel bound + scheduled on COPY0\n", .{});

    // AMPERE_DMA_COPY_B engine object — child of the channel.
    const hCe: u32 = nvrm.AMPERE_DMA_COPY_B << 16;
    var cep = nvrm.Cb5AllocParams{ .version = 1, .engineType = nvrm.NV2080_ENGINE_TYPE_COPY0 };
    {
        const p: [*]const u8 = @ptrCast(&cep);
        try rm.allocObject(g.*, nvrm.RM_CLIENT0, hChan, hCe, nvrm.AMPERE_DMA_COPY_B, p[0..@sizeOf(nvrm.Cb5AllocParams)]);
    }
    log("gpu.fifo: CE object OK (obj=0x{x})\n", .{hCe});

    // COPY0's runlist id (doorbell token) from the FIFO device-info table.
    const runlist = try engineRunlist(g.*, objs.subdevice, nvrm.NV2080_ENGINE_TYPE_COPY0);
    log("gpu.fifo: COPY0 runlist id {}\n", .{runlist});

    // Semaphore + pushbuffer pages (sysmem), mapped at their fixed VAs.
    const sem = g.dma.alloc(1) orelse return error.FifoSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(sem))[0..0x1000], 0);
    shim.flushRange(sem, 0x1000);
    try mmu.mapSysmem(gmmu.VA_SEM, sem, 0x1000);
    const push = g.dma.alloc(1) orelse return error.FifoSysmemAlloc;
    @memset(@as([*]u8, @ptrFromInt(push))[0..0x1000], 0);
    try mmu.mapSysmem(gmmu.VA_PUSH, push, 0x1000);

    return .{
        .vaspace = hVaspace,
        .chan = hChan,
        .ce = hCe,
        .chid = CHID,
        .runlist = runlist,
        .inst_phys = inst,
        .userd_phys = userd,
        .ring_phys = ring,
        .push_phys = push,
        .sem_phys = sem,
        .mthdbuf_phys = mthdbuf,
        .gp_put = 0,
        .fence = 0,
        .mmu = mmu,
    };
}

/// NV2080_CTRL_CMD_FIFO_GET_DEVICE_INFO_TABLE (0x20801112): find the row whose
/// engineData[RM_ENGINE_TYPE=2] == `engine_type` and return engineData[RUNLIST=3].
/// Layout: baseIndex u32, numEntries u32, bMore u8, pad, entries[32] @ +12;
/// entry = 96 B (engineData[15], pbdmaIds[2], pbdmaFaultIds[2], numPbdmas,
/// engineName[16]). COPY0=0x09, GR0=0x01.
pub fn engineRunlist(g: gsp.Gsp, subdevice: u32, engine_type: u32) Error!u32 {
    const ENTRY = 100; // engineData[16] + pbdmaIds[2] + pbdmaFaultIds[2] + numPbdmas + name[16]
    const PARAMS = 12 + 32 * ENTRY;
    var buf = [_]u8{0} ** PARAMS;
    try rm.control(g, subdevice, 0x20801112, buf[0..]);
    const numEntries = std.mem.readInt(u32, buf[4..8], .little);
    var i: usize = 0;
    while (i < numEntries and i < 32) : (i += 1) {
        const e = 12 + i * ENTRY;
        const rm_type = std.mem.readInt(u32, buf[e + 2 * 4 ..][0..4], .little);
        const runlist = std.mem.readInt(u32, buf[e + 3 * 4 ..][0..4], .little);
        if (rm_type == engine_type) return runlist;
    }
    log("gpu.fifo: engine type 0x{x} not in device-info table ({} entries)\n", .{ engine_type, numEntries });
    return error.FifoNoCopyEngine;
}
