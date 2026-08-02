//! GSP shared message queues + libos args + the RPC receive/poll loop used to
//! reach GSP_INIT_DONE (nouveau r535_gsp_shared_init, r535_gsp_rmargs_init,
//! r535_gsp_libos_init, r535_gsp_msg_recv, rm_r535_rpc.c).
//!
//! Layout of the one contiguous shared DMA region (low -> high):
//!   [ PTEs 0x1000 ][ cmdq 0x40000 ][ msgq 0x40000 ]   total 0x81000
//! The PTE page holds `ptes.nr` 64-bit bus addresses, one per 4 KiB page of the
//! whole region. Each queue's page 0 is its tx/rx header info page; ring entries
//! start at page 1. Ring depth `cnt = (0x40000 - 0x1000) / 0x1000 = 63`.
//!
//! Pointer crossover (nouveau): the host owns cmdq.writePtr + msgq.readPtr; the
//! GSP owns cmdq.readPtr + msgq.writePtr. Each side's RX header lives in the
//! OTHER region (cmdq.rptr = &msgq.rx.readPtr, msgq.rptr = &cmdq.rx.readPtr).

const shim = @import("../base/shim.zig");
const gspfw = @import("../base/gspfw.zig");
const mmio = @import("../base/mmio.zig");
const falcon = @import("falcon.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const spinwait = @import("../../../kernel/debug/spinwait.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const log = @import("../base/log.zig").gpu;

const PAGE: u32 = @intCast(gspfw.GSP_PAGE_SIZE); // single source: gspfw.GSP_PAGE_SIZE
const QUEUE_SIZE: u32 = 0x40000;
const PTES_SIZE: u32 = 0x1000; // ptes.size after ALIGN (see compute below)
const SHARED_SIZE: u32 = PTES_SIZE + QUEUE_SIZE + QUEUE_SIZE; // 0x81000
const RING_CNT: u32 = (QUEUE_SIZE - PAGE) / PAGE; // 63

/// cmdq doorbell: ringing the GSP after writing the cmdq write pointer
/// (rm_r535_rpc.c:413 — nvkm_falcon_wr32(&gsp->falcon, 0xc00, 0)).
const DOORBELL_REG: u64 = 0xc00;

pub const Error = error{
    MsgqAlloc,
    MsgqInitTimeout,
    MsgqReplyBudget,
    MsgqRpcError,
};

/// Live shared-queue state, mirroring nouveau gsp->shm + gsp->cmdq/msgq.
pub const Shared = struct {
    mem_phys: u64, // bus/physical base of the whole region
    ptes_nr: u32, // number of PTE entries (== pageTableEntryCount)
    cmdq_off: u64, // cmdq backing-store offset within the region (= PTES_SIZE)
    statq_off: u64, // msgq (status) backing-store offset (= PTES_SIZE + QUEUE_SIZE)

    // ring cursors (pointers into the DMA region)
    cmd_wptr: *volatile u32, // host writes (cmdq tx.writePtr)
    cmd_rptr: *volatile u32, // GSP writes (msgq rx.readPtr)
    msg_wptr: *volatile u32, // GSP writes (msgq tx.writePtr)
    msg_rptr: *volatile u32, // host writes (cmdq rx.readPtr)
};

/// Byte pointer into the shared DMA region at `phys + off`.
fn regionPtr(phys: u64, off: u64) [*]volatile u8 {
    return @ptrFromInt(phys + off);
}

/// Build the shared region (PTEs + cmdq + msgq), fill the cmdq tx header, and
/// wire the ring cursors. nouveau r535_gsp_shared_init.
pub fn buildShared(dma: *shim.DmaTracker) Error!Shared {
    const pages: u32 = SHARED_SIZE / PAGE; // 0x81
    // The shared queue region is device-visible for the GSP's whole runtime.
    const mem = dma.alloc(pages) orelse return error.MsgqAlloc;

    // Zero the whole region: PMM frames are not guaranteed zero and the queue
    // headers / cursors must start at 0 (nouveau gotcha).
    const all: [*]volatile u8 = @ptrFromInt(mem);
    var z: u32 = 0;
    while (z < SHARED_SIZE) : (z += 1) all[z] = 0;

    // PTE count: (cmdq+msgq) pages, plus the pages the PTE array itself spans.
    var ptes_nr: u32 = (QUEUE_SIZE + QUEUE_SIZE) / PAGE; // 0x80 = 128
    ptes_nr += (ptes_nr * 8 + PAGE - 1) / PAGE; // += ceil(1024/4096) = 1 -> 129

    // Fill the PTE array: one bus address per 4 KiB page of the whole region.
    const ptes: [*]volatile u64 = @ptrFromInt(mem);
    var i: u32 = 0;
    while (i < ptes_nr) : (i += 1) ptes[i] = mem + @as(u64, i) * PAGE;

    const cmdq_off: u64 = PTES_SIZE;
    const statq_off: u64 = PTES_SIZE + QUEUE_SIZE;

    // cmdq tx header (host->GSP). msgq headers are left zero (GSP fills its tx).
    const cmd_tx: *volatile gspfw.MsgqTxHeader = @ptrFromInt(mem + cmdq_off);
    cmd_tx.version = 0;
    cmd_tx.size = QUEUE_SIZE;
    cmd_tx.msgSize = PAGE;
    cmd_tx.msgCount = RING_CNT; // 63
    cmd_tx.writePtr = 0;
    cmd_tx.flags = 1;
    cmd_tx.rxHdrOff = @sizeOf(gspfw.MsgqTxHeader); // 32: rx follows tx
    cmd_tx.entryOff = PAGE;

    // Ring cursors (crossover wiring). rx.readPtr sits at rxHdrOff in each region.
    const cmd_rx_readptr: *volatile u32 = @ptrFromInt(mem + cmdq_off + @sizeOf(gspfw.MsgqTxHeader));
    const msg_rx_readptr: *volatile u32 = @ptrFromInt(mem + statq_off + @sizeOf(gspfw.MsgqTxHeader));
    const cmd_tx_writeptr: *volatile u32 = @ptrFromInt(mem + cmdq_off + @offsetOf(gspfw.MsgqTxHeader, "writePtr"));
    const msg_tx_writeptr: *volatile u32 = @ptrFromInt(mem + statq_off + @offsetOf(gspfw.MsgqTxHeader, "writePtr"));

    log("gpu.msgq: shared @0x{x} ({} pages), ptes_nr={}, cmdq@+0x{x} statq@+0x{x} cnt={}\n", .{ mem, pages, ptes_nr, cmdq_off, statq_off, RING_CNT });

    return .{
        .mem_phys = mem,
        .ptes_nr = ptes_nr,
        .cmdq_off = cmdq_off,
        .statq_off = statq_off,
        .cmd_wptr = cmd_tx_writeptr,
        .cmd_rptr = msg_rx_readptr,
        .msg_wptr = msg_tx_writeptr,
        .msg_rptr = cmd_rx_readptr,
    };
}

/// The libos arg buffer (LibosMemoryRegionInitArgument[]) that falcon 0x040/0x044
/// points at, plus the rmargs buffer it references. Allocated and filled per
/// nouveau r535_gsp_libos_init. Returns the libos buffer's bus address.
pub const Libos = struct {
    libos_phys: u64, // -> falcon 0x040/0x044
    rmargs_phys: u64,
    loginit_phys: u64, // GSP early-boot log + exception dumps
    logintr_phys: u64, // GSP interrupt-path log
    logrm_phys: u64, // subsequent GSP logs
};

/// Set by buildLibos so the drain loop can dump GSP logs on an OS_ERROR_LOG.
var logbufs: ?Libos = null;

/// Dump readable ASCII runs (>=4 chars) from a GSP log buffer — assert/panic
/// context appears as plain text amid the printf-encoded stream.
fn dumpLogText(name: []const u8, phys: u64) void {
    const SIZE: u64 = 0x10000;
    var off: u64 = 0;
    while (off < SIZE) : (off += 64) shim.invalidateLine(phys + off);
    const b: [*]volatile u8 = @ptrFromInt(phys);
    var line: [128]u8 = undefined;
    var nl: usize = 0;
    var runs: u32 = 0;
    var i: u64 = 8;
    while (i < SIZE and runs < 60) : (i += 1) {
        const c = b[i];
        if (c >= 0x20 and c < 0x7f) {
            if (nl < line.len) {
                line[nl] = c;
                nl += 1;
            }
        } else {
            if (nl >= 4) {
                log("gpu.msgq:   {s}: {s}\n", .{ name, line[0..nl] });
                runs += 1;
            }
            nl = 0;
        }
    }
}

/// Dump the GSP log buffers' "put pointers" (offset 0 of each, in u64 units) and
/// a few leading data dwords. A non-zero put pointer / non-zero data means GSP-RM
/// got far enough to log (or panic) — the key signal for whether the GSP can read
/// its args. nouveau: logs are valid iff 1 <= pp < size/8.
pub fn dumpLogs(libos: Libos) void {
    // Invalidate the whole 0x10000 of each buffer (line by line) so we read the
    // GSP's DMA writes, then scan for ASCII runs and print them. The GSP libos
    // log is printf-encoded, but embedded format strings / file names / assert
    // text are plain ASCII and reveal where the RM wedged.
    dumpOne("loginit", libos.loginit_phys);
    dumpOne("logrm", libos.logrm_phys);
}

/// Invalidate one GSP log buffer, print its put-pointer, then dump every ASCII
/// run (>=4 chars) with its byte offset — reveals where the RM logged/wedged.
fn dumpOne(name: []const u8, phys: u64) void {
    const SIZE: u64 = 0x10000;
    var off: u64 = 0;
    while (off < SIZE) : (off += 64) shim.invalidateLine(phys + off);
    const b: [*]volatile u8 = @ptrFromInt(phys);
    const pp: [*]volatile u64 = @ptrFromInt(phys);
    log("gpu.msgq: {s} pp(0)=0x{x} scanning ASCII runs...\n", .{ name, pp[0] });

    // Print ASCII runs of length >= 4. Buffer them into a small stack line.
    var line: [128]u8 = undefined;
    var n: usize = 0;
    var i: u64 = 8; // skip the put-pointer dword
    var runs: u32 = 0;
    while (i < SIZE and runs < 80) : (i += 1) {
        const c = b[i];
        if (c >= 0x20 and c < 0x7f) {
            if (n < line.len) {
                line[n] = c;
                n += 1;
            }
        } else {
            if (n >= 4) {
                log("gpu.msgq:   {s}[0x{x}]: {s}\n", .{ name, i - n, line[0..n] });
                runs += 1;
            }
            n = 0;
        }
    }
}

const LOG_SIZE: u64 = 0x10000;

/// Zero a freshly-allocated DMA buffer. PMM frames are NOT zeroed and hold stale
/// kudos data; the GSP reads these (log put-pointers, libos table, rmargs) and
/// would misparse garbage. nouveau's dma_alloc_coherent likewise must start clean
/// for the put-pointer convention (pp=0) to hold.
fn zeroBuf(phys: u64, size: u64) void {
    const p: [*]volatile u8 = @ptrFromInt(phys);
    var i: u64 = 0;
    while (i < size) : (i += 1) p[i] = 0;
}

/// Write a buffer's own PTE array starting at byte offset 8 (offset[0] is the
/// "put pointer", left 0). nouveau create_pte_array.
fn createPteArray(buf_phys: u64, size: u64) void {
    const num_pages = (size + PAGE - 1) / PAGE;
    const ptes: [*]volatile u64 = @ptrFromInt(buf_phys + 8);
    var i: u64 = 0;
    while (i < num_pages) : (i += 1) ptes[i] = buf_phys + i * PAGE;
}

/// Build the libos args (LOGINIT/LOGINTR/LOGRM/RMARGS) + the rmargs GSP_ARGUMENTS_CACHED
/// pointing at the shared queues. nouveau r535_gsp_libos_init + set_rmargs.
pub fn buildLibos(dma: *shim.DmaTracker, shared: Shared) Error!Libos {
    // Three 0x10000 log buffers, each zeroed (PMM frames hold stale kudos data
    // the GSP would misread) then carrying its own PTE array at +8. All are
    // device-visible for the GSP's runtime, so track them for teardown.
    const loginit = dma.alloc(@intCast(LOG_SIZE / PAGE)) orelse return error.MsgqAlloc;
    const logintr = dma.alloc(@intCast(LOG_SIZE / PAGE)) orelse return error.MsgqAlloc;
    const logrm = dma.alloc(@intCast(LOG_SIZE / PAGE)) orelse return error.MsgqAlloc;
    zeroBuf(loginit, LOG_SIZE);
    zeroBuf(logintr, LOG_SIZE);
    zeroBuf(logrm, LOG_SIZE);
    createPteArray(loginit, LOG_SIZE);
    createPteArray(logintr, LOG_SIZE);
    createPteArray(logrm, LOG_SIZE);

    // rmargs (GSP_ARGUMENTS_CACHED, 0x1000), zeroed then filled.
    const rmargs_phys = dma.alloc(1) orelse return error.MsgqAlloc;
    zeroBuf(rmargs_phys, PAGE);
    const args: *volatile gspfw.GspArgumentsCached = @ptrFromInt(rmargs_phys);
    args.* = @import("std").mem.zeroes(gspfw.GspArgumentsCached);
    args.messageQueueInitArguments.sharedMemPhysAddr = shared.mem_phys;
    args.messageQueueInitArguments.pageTableEntryCount = shared.ptes_nr;
    args.messageQueueInitArguments.cmdQueueOffset = shared.cmdq_off;
    args.messageQueueInitArguments.statQueueOffset = shared.statq_off;
    args.bDmemStack = 1; // r570 set_rmargs sets this (DMEM stack for the RM)
    // srInitArguments stay 0 (cold boot).

    // libos arg array (0x1000): four 32-byte entries; zero first so any unused
    // tail isn't read by the GSP as a bogus extra region.
    const libos_phys = dma.alloc(1) orelse return error.MsgqAlloc;
    zeroBuf(libos_phys, PAGE);
    const entries: [*]volatile gspfw.LibosMemoryRegionInitArgument = @ptrFromInt(libos_phys);
    const tbl = [_]struct { name: []const u8, pa: u64, size: u64 }{
        .{ .name = "LOGINIT", .pa = loginit, .size = LOG_SIZE },
        .{ .name = "LOGINTR", .pa = logintr, .size = LOG_SIZE },
        .{ .name = "LOGRM", .pa = logrm, .size = LOG_SIZE },
        .{ .name = "RMARGS", .pa = rmargs_phys, .size = PAGE },
    };
    for (tbl, 0..) |e, idx| {
        entries[idx] = .{
            .id8 = gspfw.libosId8(e.name),
            .pa = e.pa,
            .size = e.size,
            .kind = gspfw.LIBOS_REGION_KIND_CONTIGUOUS,
            .loc = gspfw.LIBOS_REGION_LOC_SYSMEM,
        };
    }

    log("gpu.msgq: libos @0x{x} (loginit@0x{x} logintr@0x{x} logrm@0x{x} rmargs@0x{x})\n", .{ libos_phys, loginit, logintr, logrm, rmargs_phys });
    const lb = Libos{ .libos_phys = libos_phys, .rmargs_phys = rmargs_phys, .loginit_phys = loginit, .logintr_phys = logintr, .logrm_phys = logrm };
    logbufs = lb;
    return lb;
}

/// FIX B (uniform flush discipline): push every CPU-written buffer the GSP reads
/// to RAM before the falcon 0x040/0x044 libos-args handoff. The shared queue
/// mapping is not reliably snooped for the GSP's DMA (the reason cmdqSend/drainUntil
/// clflush the ring), so the whole shared region + libos arg table + rmargs + all
/// three log put-pointer pages must be flushed too — otherwise the GSP may read a
/// stale (pre-zero) header/cursor and misparse the queues or the log convention.
/// Sizes are owned here (single source of truth: SHARED_SIZE, PAGE, LOG_SIZE);
/// gsp.zig calls this rather than re-deriving them. clflush per line, never wbinvd
/// (a full write-back with the GPU BAR mapped costs seconds and trips GSP init).
pub fn flushForHandoff(shared: Shared, libos: Libos) void {
    shim.flushRange(shared.mem_phys, SHARED_SIZE); // PTEs + cmdq + msgq (headers/cursors)
    shim.flushRange(libos.libos_phys, PAGE); // libos region table
    shim.flushRange(libos.rmargs_phys, PAGE); // GSP_ARGUMENTS_CACHED
    shim.flushRange(libos.loginit_phys, LOG_SIZE); // log put-pointer + PTE array pages
    shim.flushRange(libos.logintr_phys, LOG_SIZE);
    shim.flushRange(libos.logrm_phys, LOG_SIZE);
}

/// Pointer to ring entry `rptr` in the msgq (status) region. Skips the info page
/// (page 0), then `rptr` pages (nouveau r535_gsp_msgq_get_entry).
fn msgqEntry(shared: Shared, rptr: u32) *volatile gspfw.GspMsgQueueElement {
    const base = shared.mem_phys + shared.statq_off + PAGE + @as(u64, rptr) * PAGE;
    return @ptrFromInt(base);
}

/// The RPC header within an element (at element + 48).
fn elemRpc(elem: *volatile gspfw.GspMsgQueueElement) *volatile gspfw.RpcMessageHeader {
    const p: u64 = @intFromPtr(elem) + gspfw.GSP_MSG_HDR_SIZE;
    return @ptrFromInt(p);
}

// --- Command queue (host -> GSP) -------------------------------------------

/// Per-queue + per-RPC sequence counters (single GSP instance). nouveau keeps
/// these in gsp->cmdq.seq / gsp->rpc_seq.
var cmdq_seq: u32 = 0;
var rpc_seq: u32 = 0;

const RPC_SIGNATURE: u32 = ('C' << 24) | ('P' << 16) | ('R' << 8) | 'V'; // 'VRPC'

/// When set, cmdqSend hex-dumps the full RPC payload (for byte-diffing against
/// nouveau's debug=trace dump). gsp.zig toggles it around specific RPCs.
pub var dump_payload: bool = false;

/// Log one 16-byte hex row (`off: b0 b1 ...`) for the RPC payload dump; short
/// rows are zero-padded so the layout lines up with nouveau's debug=trace dump.
fn dumpHexOff(label: []const u8, off: usize, b: []const u8) void {
    var line: [16]u8 = .{0} ** 16;
    for (b, 0..) |x, i| line[i] = x;
    log("gpu.msgq: {s}: {x:0>8}: {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n", .{ label, off, line[0], line[1], line[2], line[3], line[4], line[5], line[6], line[7], line[8], line[9], line[10], line[11], line[12], line[13], line[14], line[15] });
}

const CStr = struct { buf: [64]u8, len: usize };

/// Read a NUL-terminated ASCII string (printable, else '.') from a volatile
/// buffer at `start`, up to 64 bytes — for diagnostic record fields.
fn readCStr(p: [*]volatile u8, start: usize) CStr {
    var r: CStr = .{ .buf = undefined, .len = 0 };
    while (r.len < 63) : (r.len += 1) {
        const c = p[start + r.len];
        if (c == 0) break;
        r.buf[r.len] = if (c >= 0x20 and c < 0x7f) c else '.';
    }
    return r;
}

/// Pointer to cmdq ring entry `wptr` (skip info page, then wptr pages).
fn cmdqEntry(shared: Shared, wptr: u32) *volatile gspfw.GspMsgQueueElement {
    const base = shared.mem_phys + shared.cmdq_off + PAGE + @as(u64, wptr) * PAGE;
    return @ptrFromInt(base);
}

/// Staging buffer for one outbound message (element hdr + rpc hdr + payload),
/// page-padded. Max 16 pages (GSP_MSG_MAX_SIZE) — covers all control/alloc RPCs.
var send_buf: [16 * PAGE]u8 align(8) = undefined;

/// Frame an RPC into the cmdq and ring the doorbell. `function` is the
/// NV_VGPU_MSG_FUNCTION id; `payload` is copied after the 32-byte RPC header.
/// The full message (48-byte element hdr + 32-byte rpc hdr + payload), padded to
/// a whole number of pages, gets a seq/elem_count/XOR-checksum element header and
/// is written across `elem_count` consecutive ring pages (wrapping), then the
/// doorbell is rung. nouveau r535_gsp_rpc_get + rpc_send + cmdq_push.
pub fn cmdqSend(flcn: falcon.Falcon, shared: Shared, function: u32, payload: []const u8) Error!void {
    const hdr_size = gspfw.GSP_MSG_HDR_SIZE + @sizeOf(gspfw.RpcMessageHeader);
    const total = hdr_size + payload.len;
    const len = (total + PAGE - 1) & ~(@as(usize, PAGE) - 1); // page-aligned
    const n_pages: u32 = @intCast(len / PAGE);
    if (len > send_buf.len) {
        log("gpu.msgq: cmdqSend message too large ({} bytes)\n", .{total});
        return error.MsgqRpcError;
    }

    // Build the whole message in the staging buffer (zeroed pad).
    @memset(send_buf[0..len], 0);
    const elem: *gspfw.GspMsgQueueElement = @ptrCast(@alignCast(&send_buf[0]));
    const rpc: *gspfw.RpcMessageHeader = @ptrCast(@alignCast(&send_buf[gspfw.GSP_MSG_HDR_SIZE]));
    rpc.header_version = 0x03000000;
    rpc.signature = RPC_SIGNATURE;
    rpc.function = function;
    rpc.rpc_result = 0xffffffff;
    rpc.rpc_result_private = 0xffffffff;
    rpc.length = @intCast(@sizeOf(gspfw.RpcMessageHeader) + payload.len);
    rpc.sequence = rpc_seq;
    rpc_seq +%= 1;
    rpc.u = 0;
    @memcpy(send_buf[hdr_size .. hdr_size + payload.len], payload);

    elem.seqNum = cmdq_seq;
    cmdq_seq +%= 1;
    elem.elemCount = n_pages;
    elem.checkSum = 0;
    // XOR checksum over the whole (page-padded, checksum-zero) message.
    var csum: u64 = 0;
    const words: [*]const u64 = @ptrCast(@alignCast(&send_buf[0]));
    var i: usize = 0;
    while (i < len / 8) : (i += 1) csum ^= words[i];
    elem.checkSum = @as(u32, @truncate(csum >> 32)) ^ @as(u32, @truncate(csum));

    // nouveau-parity byte-sum over the RPC payload only (KSUM send in rpc.c:369 =
    // `s += d[i]` over gsp_rpc_len bytes). Lets us instantly tell if our fn=72
    // GSP_SET_SYSTEM_INFO payload is byte-identical to nv's (nv logged sum=0x1a2b
    // for fn=72 len=0x3a0) without dumping all 928 bytes.
    {
        var bsum: u64 = 0;
        const pbytes = send_buf[gspfw.GSP_MSG_HDR_SIZE .. gspfw.GSP_MSG_HDR_SIZE + @sizeOf(gspfw.RpcMessageHeader) + payload.len];
        for (pbytes) |b| bsum += b;
        log("gpu.msgq: KSUM send fn={} len=0x{x} sum=0x{x}\n", .{ function, rpc.length, bsum });
    }

    // Dump the full RPC PAYLOAD (after the 48B element + 32B rpc headers) at
    // payload-relative offsets, so it lines up 1:1 with nouveau's debug=trace
    // "rpc: <off>:" dump for a byte-for-byte diff. Only the actual payload length.
    if (dump_payload) {
        const pay = send_buf[hdr_size..total];
        var po: usize = 0;
        while (po < pay.len) : (po += 16) {
            const end = @min(po + 16, pay.len);
            dumpHexOff("rpc", po, pay[po..end]);
        }
    }

    // Wait for `n_pages` free cmdq slots (free = rptr + cnt - wptr - 1, wrapped).
    // Busy-spin against a TSC deadline (~2 s, matching nouveau's usleep-based
    // ceiling) — NOT shim.delayUs(1), which rounds up to a full ~1 ms PIT tick and
    // *sleeps*: on this latency-sensitive init/RPC path (the rest of this file
    // deliberately busy-spins) a 1M-iteration sleep loop would be a ~16 min ceiling.
    var wptr = shared.cmd_wptr.*;
    const deadline = tsc.rdtsc() + tsc.msTicks(2000);
    while (true) {
        shim.invalidateLine(@intFromPtr(shared.cmd_rptr));
        var free = shared.cmd_rptr.* + RING_CNT - wptr - 1;
        if (free >= RING_CNT) free -= RING_CNT;
        if (free >= n_pages) break;
        if (tsc.rdtsc() >= deadline) return error.MsgqRpcError;
        asm volatile ("pause");
    }

    // Copy the message into consecutive ring pages (wrapping at RING_CNT).
    var off: usize = 0;
    var p: u32 = 0;
    while (p < n_pages) : (p += 1) {
        const dst: [*]volatile u8 = @ptrFromInt(@intFromPtr(cmdqEntry(shared, wptr)));
        var b: u32 = 0;
        while (b < PAGE) : (b += 1) dst[b] = send_buf[off + b];
        // Flush this ring page to RAM (line-by-line clflush).
        var f: u32 = 0;
        while (f < PAGE) : (f += 64) shim.invalidateLine(@intFromPtr(dst) + f);
        off += PAGE;
        wptr += 1;
        if (wptr == RING_CNT) wptr = 0;
    }

    // Publish wptr + ring the doorbell.
    cpuBarrier();
    shared.cmd_wptr.* = wptr;
    shim.invalidateLine(@intFromPtr(shared.cmd_wptr));
    cpuBarrier();
    flcn.wr(DOORBELL_REG, 0);
}

/// Full memory fence: order the ring-page writes + flushes before the wptr
/// publish (and the wptr publish before the doorbell), so the GSP never sees a
/// bumped write pointer over stale ring contents.
fn cpuBarrier() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// Poll the status (msgq) queue until an element with rpc.function == `want`
/// is dequeued, servicing intervening events (notably GSP_RUN_CPU_SEQUENCER,
/// which the GSP issues mid-init and the host MUST handle or boot stalls).
/// nouveau r535_gsp_msg_recv retry loop + r535_gsp_rpc_poll.
pub fn poll(flcn: falcon.Falcon, sec2: falcon.Falcon, regs: mmio.Mapping, shared: Shared, libos_phys: u64, app_version: u32, want: u32) Error!void {
    _ = try drainUntil(flcn, sec2, regs, shared, libos_phys, app_version, want, null);
}

/// Reply summary returned by recvReply: the matched message's RPC result and
/// payload length, plus the physical address of its element (for parsing).
pub const Reply = struct { result: u32, len: u32, elem_phys: u64 };

/// Like poll, but returns the matched message's RPC header info (for an RPC whose
/// reply we want to read, e.g. GET_GSP_STATIC_INFO).
pub fn recvReply(flcn: falcon.Falcon, sec2: falcon.Falcon, regs: mmio.Mapping, shared: Shared, libos_phys: u64, app_version: u32, want: u32) Error!Reply {
    return drainUntil(flcn, sec2, regs, shared, libos_phys, app_version, want, null);
}

/// Like recvReply, but the whole drain also carries a WALL-CLOCK budget. The
/// idle budget below resets on every message, which is right for the boot
/// stream (a busy sequencer is productive work) and wrong for teardown: a GSP
/// spewing queued Xid/NOCAT diagnostics can hold the drain hostage
/// indefinitely — messages keep arriving, the idle clock keeps resetting, and
/// the caller's own deadline (the test harness's 60 s kill) fires first,
/// hard-killing the machine before its storage flush. A bounded caller states
/// its budget; the drain honors it even mid-flood.
pub fn recvReplyBudget(flcn: falcon.Falcon, sec2: falcon.Falcon, regs: mmio.Mapping, shared: Shared, libos_phys: u64, app_version: u32, want: u32, budget_ms: u64) Error!Reply {
    return drainUntil(flcn, sec2, regs, shared, libos_phys, app_version, want, budget_ms);
}

/// Drain the status queue until a message with rpc.function == `want`, servicing
/// intervening events (notably GSP_RUN_CPU_SEQUENCER). nouveau r535_gsp_msg_recv.
fn drainUntil(flcn: falcon.Falcon, sec2: falcon.Falcon, regs: mmio.Mapping, shared: Shared, libos_phys: u64, app_version: u32, want: u32, budget_ms: ?u64) Error!Reply {
    // Idle budget is a BUSY-spin count (each iteration is a clflush + a couple of
    // volatile reads, ~sub-µs). Resets on every message processed, so a busy init
    // stream never times out. ~100M spins ≈ a few seconds of patience between
    // messages — generous, while keeping per-poll latency at hardware speed.
    const idle_budget: u32 = 100_000_000;
    var idle: u32 = 0;
    const start_ms = timer.millis();
    var drained: u32 = 0; // messages consumed without seeing `want` (flood accounting)
    // Diagnostic (Xid-62): record the ordered fn sequence of received messages so
    // the kudos stream can be compared to nouveau's (which drains ~80 fn:4108
    // UCODE_LIBOS_PRINT events past the Xid). No per-message I/O — buffered, dumped
    // once at exit below.
    var fn_trace: [256]u16 = undefined;
    var fn_ts: [256]u32 = undefined; // millis when each message was dequeued
    var fn_n: usize = 0;
    var nocat_dumped: u32 = 0; // dump the first few NOCAT records (ASCII tail)
    while (idle < idle_budget) {
        // The GSP's DMA writes to the shared queue are NOT observed by a plain
        // cached read on this mapping (verified: dropping the flush → 0 messages),
        // so we must clflush msg_wptr before reading it to detect a new message.
        // This is a single 8-byte line — cheap; it is the per-element page/line
        // flushes and verbose diagnostics that added the deadline-missing latency.
        shim.invalidateLine(@intFromPtr(shared.msg_wptr));
        const wptr = shared.msg_wptr.*;
        var rptr = shared.msg_rptr.*;
        if (rptr == wptr) {
            // BUSY-spin (no sleep): GSP init is timing-sensitive — nouveau polls
            // with usleep_range(1,2) (~µs), not ms. A 1ms sleep per empty poll
            // slows servicing enough to trip the GSP's NOT_READY timeout. The idle
            // budget is a spin count (~ large) rather than ms.
            idle += 1;
            continue; // empty
        }
        idle = 0; // got a message — reset the idle timeout
        drained += 1;
        // The wall-clock budget outranks the idle clock: a flood of queued
        // diagnostics must not hold a bounded caller past its deadline. Checked
        // on the message path only — the empty path is already idle-bounded,
        // and the message path is the one a flood keeps alive.
        if (budget_ms) |budget| {
            const now_ms = timer.millis();
            if (now_ms - start_ms > budget) {
                log("gpu.msgq: reply budget ({}ms) exhausted: {} messages drained without fn={} — giving up\n", .{ budget, drained, want });
                dumpFnTrace(fn_trace[0..fn_n], fn_ts[0..fn_n]);
                return error.MsgqReplyBudget;
            }
        }

        const elem = msgqEntry(shared, rptr);
        // Invalidate the element's first two lines (element hdr + RPC header live in
        // the first ~80 bytes) so we read the GSP's DMA-written framing, not stale
        // cache. The rest of the payload span is invalidated below once elemCount is
        // validated (the CPU sequencer walks a multi-page command buffer).
        shim.invalidateLine(@intFromPtr(elem));
        shim.invalidateLine(@intFromPtr(elem) + 64);
        const rpc = elemRpc(elem);
        const func = rpc.function;
        const result = rpc.rpc_result;
        // FIX D (framing guard): elemCount is GSP-written and drives the rptr advance.
        // A garbage count (0, or larger than the ring depth) would desync rptr from
        // the GSP's framing and misparse EVERY following RPC — treat it as a protocol
        // error and bail loud rather than limping on. We validate defensively because
        // this mapping is read through a non-snooped path (per the clflush workaround);
        // nouveau trusts a well-formed queue on a coherent mapping.
        const elem_count = elem.elemCount;
        if (elem_count == 0 or elem_count > RING_CNT) {
            log("gpu.msgq: GSP element framing error: elemCount={} (ring depth {}) at rptr={} fn={}\n", .{ elem_count, RING_CNT, rptr, func });
            dumpFnTrace(fn_trace[0..fn_n], fn_ts[0..fn_n]);
            return error.MsgqRpcError;
        }
        // Wrap guard: `msgqEntry` returns a LINEAR pointer, and both the full-span
        // invalidate below and runCpuSequencer's cmds[] walk read `elem_count` pages
        // forward from it. If this element would cross the ring end
        // (rptr + elem_count > RING_CNT) those reads run past the status region into
        // adjacent DMA — nouveau (r535_gsp_msgq_recv_one_elem) instead reassembles
        // the element from the tail pages plus the pages at ring start. kudos does
        // not yet stage a wrapped element, so rather than silently read out of
        // bounds (garbage sequencer opcodes → GPU fault/Xid) we fail loud here. This
        // does not fire during INIT (the ring starts at rptr=0 with small elements
        // before the sequencer); it guards the once-cycled case until wrap-assembly
        // is implemented and validated on the passthrough rig.
        if (rptr + elem_count > RING_CNT) {
            log("gpu.msgq: multi-page element wraps the ring (rptr={} elemCount={} depth={}) — reassembly not implemented\n", .{ rptr, elem_count, RING_CNT });
            dumpFnTrace(fn_trace[0..fn_n], fn_ts[0..fn_n]);
            return error.MsgqRpcError;
        }
        // FIX A (full-span invalidate): the shared queue mapping is not reliably
        // snooped for the GSP's DMA — the very reason cmdqSend/drainUntil clflush the
        // ring. Having read the framing from the first two lines, invalidate the REST
        // of this element's page footprint (elemCount pages, covering GSP_MSG_HDR_SIZE
        // + rpc.length rounded up to pages) so any consumer that walks it reads the
        // GSP's DMA, not stale cache. runCpuSequencer in particular walks up to ~1594
        // dwords spanning multiple pages; invalidating only the header let it execute
        // stale-cache REG_WRITE opcodes → GPU fault/Xid. Skip the two lines already
        // invalidated above.
        {
            const span_bytes: u64 = @as(u64, elem_count) * PAGE;
            var so: u64 = 128;
            while (so < span_bytes) : (so += 64) shim.invalidateLine(@intFromPtr(elem) + so);
        }
        if (fn_n < fn_trace.len) {
            fn_trace[fn_n] = @truncate(func);
            fn_ts[fn_n] = @truncate(timer.millis());
            fn_n += 1;
        }
        // Hot path: NO per-message logging (synchronous trace ~5ms/line would
        // slow servicing enough to trip the GSP's NOT_READY timeout). Only the
        // matched reply, the sequencer, and errors log (below).

        // 0x1020 GSP_POST_NOCAT_RECORD: the GSP emits these before it requests the
        // CPU sequencer when its early init hits a catastrophe. The record carries
        // ASCII at +0x18 (the assert/engine name). Dump the readable tail of the
        // first few to name which subsystem the GSP-RM is unhappy about at startup.
        if (func == @intFromEnum(gspfw.MsgEvent.post_nocat_record) and nocat_dumped < 4) {
            nocat_dumped += 1;
            const p: [*]volatile u8 = @ptrFromInt(@intFromPtr(elem) + gspfw.GSP_MSG_HDR_SIZE + @sizeOf(gspfw.RpcMessageHeader));
            // type word at +0x10; tag string at +0x18 (e.g. "ASSERT"); detail
            // string at +0x20 (e.g. "NV_PGC6_AON_..._GFW_BOOT_PROGRESS").
            const ty = @as(u32, p[16]) | (@as(u32, p[17]) << 8) | (@as(u32, p[18]) << 16) | (@as(u32, p[19]) << 24);
            const tag = readCStr(p, 24);
            const detail = readCStr(p, 32);
            log("gpu.msgq: nocat[{}] type={} tag='{s}' detail='{s}'\n", .{ nocat_dumped, ty, tag.buf[0..tag.len], detail.buf[0..detail.len] });
        }

        // 0x1006 OS_ERROR_LOG: dump exceptType (Xid) + errString. Layout is
        // rpc_os_error_log_v17_00 (r570 nvrm/gsp.h): exceptType@0, runlistId@4,
        // chid@8, char errString[0x100]@12. The errString is the GSP-RM's own
        // human-readable fault reason — the decisive evidence for Xid 62.
        if (func == @intFromEnum(gspfw.MsgEvent.os_error_log)) {
            const p: [*]volatile u8 = @ptrFromInt(@intFromPtr(elem) + gspfw.GSP_MSG_HDR_SIZE + @sizeOf(gspfw.RpcMessageHeader));
            const except = @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
            const chid = @as(u32, p[8]) | (@as(u32, p[9]) << 8) | (@as(u32, p[10]) << 16) | (@as(u32, p[11]) << 24);
            log("gpu.msgq: GSP OS_ERROR_LOG Xid={} chid={} t={}ms\n", .{ except, chid, timer.millis() });
            // errString at +12, NUL-terminated within 0x100 bytes.
            var s: [256]u8 = undefined;
            var n: usize = 0;
            while (n < 255) : (n += 1) {
                const c = p[12 + n];
                if (c == 0) break;
                s[n] = c;
            }
            if (n > 0) log("gpu.msgq: GSP Xid errString: {s}\n", .{s[0..n]});
        }

        // nouveau parity (r535_gsp_msg_recv, rpc.c:480): a nonzero rpc_result on
        // ANY received message is terminal — nouveau dumps it and returns -EINVAL,
        // it does NOT keep polling for the result to become 0 (0x55=NV_ERR_NOT_READY
        // and 0x66=TIMEOUT_RETRY both map to -EBUSY in r535_rpc_status_to_errno, but
        // the INIT_DONE poll path treats any nonzero as failure).
        //
        // So a nonzero result must be checked on EVERY received message, not only on the
        // one we were waiting for. Ignore it anywhere else and a failed init reports
        // itself as success, and the failure resurfaces much later as an unexplained
        // hang. Bail here.
        if (result != 0) {
            log("gpu.msgq: GSP RPC fn={} returned result=0x{x} (terminal) t={}ms\n", .{ func, result, timer.millis() });
            dumpFnTrace(fn_trace[0..fn_n], fn_ts[0..fn_n]);
            return error.MsgqRpcError;
        }

        const match = func == want;
        const reply = Reply{ .result = result, .len = rpc.length, .elem_phys = @intFromPtr(elem) };

        // Service the CPU sequencer BEFORE advancing rptr is fine either way; do
        // it before advancing to mirror nouveau's handler-then-done ordering.
        if (func == @intFromEnum(gspfw.MsgEvent.gsp_run_cpu_sequencer)) {
            runCpuSequencer(flcn, sec2, regs, elem, libos_phys, app_version) catch |e| {
                log("gpu.msgq: cpu-sequencer failed: {}\n", .{e});
                return error.MsgqRpcError;
            };
        }

        // Advance rptr past this element (one or more pages) and PUBLISH it to the
        // GSP. This mapping is not plain-coherent for the GSP's DMA (verified: the
        // GSP's writes need a clflush to be observed), so our rptr write must be
        // flushed too — else the GSP cannot see how far the host consumed the status
        // queue, treats the host as stalled, and floods NOCATs / faults. (One 8-byte
        // line per message — cheap.)
        rptr = (rptr + elem_count) % RING_CNT;
        shared.msg_rptr.* = rptr;
        shim.flushRange(@intFromPtr(shared.msg_rptr), 8);

        if (match) {
            dumpFnTrace(fn_trace[0..fn_n], fn_ts[0..fn_n]);
            return reply;
        }
        // other async events: ignored at boot (logged above).
    }
    dumpFnTrace(fn_trace[0..fn_n], fn_ts[0..fn_n]);
    return error.MsgqInitTimeout;
}

/// Dump the ordered received-message fn sequence + per-fn counts (Xid-62
/// diagnostic). Logged once at drainUntil exit, not per-message, to avoid the
/// trace latency that would itself slow servicing.
fn dumpFnTrace(trace: []const u16, ts: []const u32) void {
    const span = if (trace.len > 0) ts[trace.len - 1] -% ts[0] else 0;
    log("gpu.msgq: drainUntil received {} messages over {}ms\n", .{ trace.len, span });
    // Per-fn counts.
    var seen: [16]u16 = [_]u16{0} ** 16;
    var cnt: [16]u32 = [_]u32{0} ** 16;
    var nseen: usize = 0;
    for (trace) |f| {
        var j: usize = 0;
        while (j < nseen) : (j += 1) {
            if (seen[j] == f) break;
        }
        if (j == nseen and nseen < seen.len) {
            seen[nseen] = f;
            nseen += 1;
        }
        if (j < cnt.len) cnt[j] += 1;
    }
    var k: usize = 0;
    while (k < nseen) : (k += 1) {
        log("gpu.msgq:   fn={} (0x{x}) x{}\n", .{ seen[k], seen[k], cnt[k] });
    }
    // Ordered first-16 fn sequence (with relative ms) to compare the early stream
    // vs nouveau-success (where INIT_DONE arrives as msg #6).
    const show = @min(trace.len, 16);
    var o: usize = 0;
    while (o < show) : (o += 1) {
        const rel = if (trace.len > 0) ts[o] -% ts[0] else 0;
        log("gpu.msgq:   [{}] fn=0x{x} +{}ms\n", .{ o, trace[o], rel });
    }
    // Largest inter-message gaps: where is the time spent? Print a window of the
    // 6 messages leading up to each big gap, so we can see what the GSP was doing
    // just before it stalled (the ~4s gap before the failing NOCAT burst).
    var idx: usize = 1;
    while (idx < trace.len) : (idx += 1) {
        const gap = ts[idx] -% ts[idx - 1];
        if (gap >= 100) {
            log("gpu.msgq:   GAP {}ms before msg[{}] fn=0x{x}; preceding window:\n", .{ gap, idx, trace[idx] });
            const lo = if (idx >= 6) idx - 6 else 0;
            var w: usize = lo;
            while (w < idx) : (w += 1) {
                log("gpu.msgq:     [{}] fn=0x{x} +{}ms\n", .{ w, trace[w], ts[w] -% ts[0] });
            }
        }
    }
}

/// FIX C: TSC wall-clock budget for GSP-path register polls. A fixed iteration
/// count is wrong across MMIO speeds (a budget tuned to vfio's ~1µs/trapped-read
/// is 1000× off on a faster path), so these helpers spin against a `tsc.rdtsc()`
/// deadline instead — the same policy as falcon.waitMemScrubbing. 2s is generous
/// for every sequencer poll (nouveau uses nvkm_msec(2000,...) on these paths).
const SPIN_TIMEOUT_US: u64 = 2_000_000; // 2 s

/// Busy-spin until `(regs.read32(addr) & mask) == val`, bounded by a TSC deadline
/// `timeout_us` µs out (NO sleep — the GSP init is µs-timing-sensitive). Returns
/// false on timeout. nouveau uses nvkm_usec/nvkm_msec which busy-loop similarly.
fn spinReg(regs: mmio.Mapping, addr: u32, mask: u32, val: u32, timeout_us: u64) bool {
    const deadline = tsc.rdtsc() + tsc.usTicks(timeout_us);
    var n: u32 = 0;
    while (tsc.rdtsc() < deadline) : (n +%= 1) {
        if ((regs.read32(addr) & mask) == val) return true;
        // These polls run for whole seconds inside the drain-pumping system
        // task; without this leg the trace goes quiet and the drain deadman
        // (correctly) reports the silence on a healthy boot.
        if (n % 1024 == 0) if (spinwait.pump) |pp| pp();
    }
    return false;
}

/// Like spinReg but returns the number of register reads taken (for profiling how
/// long the sequencer's polls actually spin). 0 on timeout is impossible; a value
/// equal to the reads done up to the deadline signals a timed-out poll only in
/// conjunction with the `ok` flag returned via the out-param.
fn spinRegCount(regs: mmio.Mapping, addr: u32, mask: u32, val: u32, timeout_us: u64, ok: *bool) u64 {
    const deadline = tsc.rdtsc() + tsc.usTicks(timeout_us);
    var reads: u64 = 0;
    while (tsc.rdtsc() < deadline) {
        reads += 1;
        if ((regs.read32(addr) & mask) == val) {
            ok.* = true;
            return reads;
        }
        // Same pump leg as spinReg — see the note there.
        if (reads % 1024 == 0) if (spinwait.pump) |pp| pp();
    }
    ok.* = false;
    return reads;
}

/// Like spinReg but polls a falcon register (`flcn.rd(off)`) instead of an
/// absolute BAR0 offset — used by the sequencer's CORE_WAIT_FOR_HALT opcode.
fn spinFalcon(flcn: falcon.Falcon, off: u64, mask: u32, val: u32, timeout_us: u64) bool {
    const deadline = tsc.rdtsc() + tsc.usTicks(timeout_us);
    var n: u32 = 0;
    while (tsc.rdtsc() < deadline) : (n +%= 1) {
        if ((flcn.rd(off) & mask) == val) return true;
        // Same pump leg as spinReg — see the note there.
        if (n % 1024 == 0) if (spinwait.pump) |pp| pp();
    }
    return false;
}

/// Service a GSP_RUN_CPU_SEQUENCER event: walk the command buffer and apply each
/// opcode to device MMIO / the GSP falcon. nouveau r535_gsp_msg_run_cpu_sequencer.
/// Payload = rpc_run_cpu_sequencer_v17_00 at element+80. `sec2` is needed for the
/// CORE_RESUME opcode (it restarts the booter to relaunch the GSP RISC-V core).
fn runCpuSequencer(flcn: falcon.Falcon, sec2: falcon.Falcon, regs: mmio.Mapping, elem: *volatile gspfw.GspMsgQueueElement, libos_phys: u64, app_version: u32) !void {
    const payload: u64 = @intFromPtr(elem) + gspfw.GSP_MSG_HDR_SIZE + @sizeOf(gspfw.RpcMessageHeader);
    const hdr: [*]volatile u32 = @ptrFromInt(payload);
    const cmd_index = hdr[1]; // cmdIndex
    const cmds: [*]volatile u32 = @ptrFromInt(payload + 40); // commandBuffer[]
    log("gpu.msgq: cpu-sequencer START t={}ms\n", .{timer.millis()});

    // Count opcodes for a one-line summary (don't log per-op: 1594 dwords).
    var counts = [_]u32{0} ** 9;
    var poll_spins: u64 = 0;
    var ptr: u32 = 0;
    while (ptr < cmd_index) {
        const opcode = cmds[ptr];
        const args: [*]volatile u32 = cmds + ptr + 1;
        const payload_dw = seqPayloadDwords(opcode);
        if (opcode <= 8) counts[opcode] += 1;
        switch (opcode) {
            0 => regs.write32(args[0], args[1]), // REG_WRITE
            1 => { // REG_MODIFY: (rd & ~mask) | val
                const v = (regs.read32(args[0]) & ~args[1]) | args[2];
                regs.write32(args[0], v);
            },
            2 => { // REG_POLL: (rd & mask) == val
                var ok = false;
                const sc = spinRegCount(regs, args[0], args[1], args[2], SPIN_TIMEOUT_US, &ok);
                poll_spins +%= sc;
                if (!ok) {
                    log("gpu.msgq: seq REG_POLL TIMEOUT addr=0x{x} mask=0x{x} want=0x{x} got=0x{x}\n", .{ args[0], args[1], args[2], regs.read32(args[0]) });
                    return error.MsgqRpcError;
                }
            },
            3 => { // DELAY_US: busy-wait exactly args[0] µs against the TSC (Linux
                // udelay parity, same as falcon.resetEng). A TSC deadline is exact
                // and MMIO-rate-independent; an MMIO-read spin count is not.
                tsc.udelay(args[0]);
            },
            4 => {}, // REG_STORE: regSaveArea unused at boot
            5 => { // CORE_RESET: nvkm_falcon_reset = disable+enable (= falcon.enable),
                // NOT ga102_gsp_reset. Using reset_eng alone leaves the DMA reg
                // block (0x110118) gated -> reads 0xbadf poison and the poll hangs.
                falcon.enable(flcn) catch |e| {
                    log("gpu.msgq: seq CORE_RESET enable failed: {}\n", .{e});
                    return error.MsgqRpcError;
                };
                flcn.mask(0x624, 0x80, 0x80);
                flcn.wr(0x10c, 0);
            },
            6 => { // CORE_START
                if ((flcn.rd(0x100) & 0x40) != 0) flcn.wr(0x130, 2) else flcn.wr(0x100, 2);
            },
            7 => { // CORE_WAIT_FOR_HALT: 0x100 & 0x10 (halted). nvkm_falcon_wait_for_halt
                // WARNs and returns -ETIMEDOUT on timeout; the sequencer must NOT
                // proceed against a non-halted core (its next opcodes assume the core
                // is stopped), so a timeout is a hard error here, not a silent pass.
                if (!spinFalcon(flcn, 0x100, 0x10, 0x10, SPIN_TIMEOUT_US)) {
                    log("gpu.msgq: seq CORE_WAIT_FOR_HALT timeout (cpuctl=0x{x}) — core never halted\n", .{flcn.rd(0x100)});
                    return error.MsgqRpcError;
                }
            },
            8 => { // CORE_RESUME: re-launch the GSP RISC-V core via SEC2 (booter).
                falcon.reset(flcn) catch |e| {
                    log("gpu.msgq: seq CORE_RESUME falcon reset failed: {}\n", .{e});
                    return error.MsgqRpcError;
                };
                flcn.wr(0x040, @truncate(libos_phys));
                flcn.wr(0x044, @truncate(libos_phys >> 32));
                // nvkm_falcon_start(sec2) = nvkm_falcon_v1_start: if cpuctl&0x40
                // (alias_en) write 0x130=2, else 0x100=2.
                if ((sec2.rd(0x100) & 0x40) != 0) sec2.wr(0x130, 2) else sec2.wr(0x100, 2);
                // wait device 0x1180f8 & 0x04000000 (SEC2 booter re-staged GSP).
                if (!spinReg(regs, 0x1180f8, 0x04000000, 0x04000000, SPIN_TIMEOUT_US)) {
                    log("gpu.msgq: seq CORE_RESUME wait 0x1180f8 timeout (got=0x{x}, sec2 cpuctl=0x{x} mbox0=0x{x})\n", .{ regs.read32(0x1180f8), sec2.rd(0x100), sec2.rd(0x040) });
                    return error.MsgqRpcError;
                }
                const m0 = sec2.rd(0x040);
                if (m0 != 0) {
                    log("gpu.msgq: seq CORE_RESUME sec2 mbox0=0x{x}\n", .{m0});
                    return error.MsgqRpcError;
                }
                flcn.wr(0x080, app_version);
                if (!flcn.riscvActive()) {
                    log("gpu.msgq: seq CORE_RESUME riscv not active\n", .{});
                    return error.MsgqRpcError;
                }
            },
            else => {
                log("gpu.msgq: cpu-sequencer unknown opcode {} at dw {}\n", .{ opcode, ptr });
                return error.MsgqRpcError;
            },
        }
        ptr += 1 + payload_dw;
    }
    log("gpu.msgq: cpu-sequencer poll_spins={}\n", .{poll_spins});
    log("gpu.msgq: cpu-sequencer done ({} dw) t={}ms: wr={} mod={} poll={} delay={} store={} reset={} start={} halt={} resume={}\n", .{ cmd_index, timer.millis(), counts[0], counts[1], counts[2], counts[3], counts[4], counts[5], counts[6], counts[7], counts[8] });
}

/// GSP_SEQUENCER_PAYLOAD_SIZE_DWORDS (nvrm/gsp.h:684-694).
fn seqPayloadDwords(opcode: u32) u32 {
    return switch (opcode) {
        0 => 2, // REG_WRITE
        1 => 3, // REG_MODIFY
        2 => 5, // REG_POLL
        3 => 1, // DELAY_US
        4 => 2, // REG_STORE
        else => 0, // CORE_* take no payload
    };
}

/// Ring the cmdq doorbell after publishing a command (for later command sends).
pub fn ringDoorbell(flcn: falcon.Falcon) void {
    flcn.wr(DOORBELL_REG, 0);
}
