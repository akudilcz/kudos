//! Copy-engine (NVA0B5 on AMPERE_DMA_COPY_B) method emission + host fence.
//!
//! Grounded in cla0b5.h, clc36f.h and nouveau_boa0b5.c. Emits into a HostPush;
//! fifo.zig submits and waits.

const hostpush = @import("hostpush");
const nvrm = @import("../base/nvrm.zig");

// NVA0B5 (CE) methods.
const OFFSET_IN_UPPER: u32 = 0x400; // ..LOWER 0x404, OUT 0x408/0x40c,
// PITCH_IN 0x410, PITCH_OUT 0x414, LINE_LENGTH_IN 0x418, LINE_COUNT 0x41c
const LAUNCH_DMA: u32 = 0x300;

// NVC36F (host) semaphore methods.
const SEM_ADDR_LO: u32 = 0x5c; // ..HI 0x60, PAYLOAD_LO 0x64, PAYLOAD_HI 0x68
const SEM_EXECUTE: u32 = 0x6c;
const SEM_EXECUTE_RELEASE: u32 = 0x1; // 32-bit payload, no WFI, no timestamp

// CE semaphore (clc7b5.h): SET_SEMAPHORE_A 0x240 (UPPER 16:0), _B 0x244
// (LOWER), _PAYLOAD 0x248. LAUNCH_DMA.SEMAPHORE_TYPE bits4:3 = 1 (release, no
// timestamp) makes the CE write the payload AFTER the copy completes (with
// FLUSH_ENABLE) — the true completion fence. A HOST-engine release signals at
// dispatch time, NOT completion (observed: "32 MB copied" fenced in 9 µs, then
// the next submit corrupted the still-in-flight pushbuffer).
const SET_SEMAPHORE_A: u32 = 0x240;

/// LAUNCH_DMA for a multi-line PITCH→PITCH virtual copy with CE semaphore
/// release: NON_PIPELINED | FLUSH_ENABLE | SEMAPHORE_TYPE=RELEASE | layouts
/// PITCH | MULTI_LINE. Used for the FINAL copy of a chain (its flush+release is the
/// true completion fence).
const LAUNCH_PITCH_COPY_SEM: u13 = 0x386 | (1 << 3);

/// Bind the CE class to subchannel 4 (host SET_OBJECT, nve0_bo_move_init).
pub fn bind(p: *hostpush.HostPush) void {
    p.incr(hostpush.SUBCH_CE, 0x0000, 1);
    p.data(nvrm.AMPERE_DMA_COPY_B & 0xffff);
}

/// Pitch-linear copy: `lines` rows of `line_bytes`, independent strides.
/// Addresses are GPU VAs in the channel's VA space. The CE releases `payload`
/// to `sem_va` after the copy completes — poll it for completion.
pub fn copyPitch(p: *hostpush.HostPush, dst_va: u64, dst_pitch: u32, src_va: u64, src_pitch: u32, line_bytes: u32, lines: u32, sem_va: u64, payload: u32) void {
    p.incr(hostpush.SUBCH_CE, SET_SEMAPHORE_A, 3);
    p.data(@intCast(sem_va >> 32));
    p.data(@truncate(sem_va));
    p.data(payload);
    p.incr(hostpush.SUBCH_CE, OFFSET_IN_UPPER, 8);
    p.data(@intCast(src_va >> 32));
    p.data(@truncate(src_va));
    p.data(@intCast(dst_va >> 32));
    p.data(@truncate(dst_va));
    p.data(src_pitch);
    p.data(dst_pitch);
    p.data(line_bytes);
    p.data(lines);
    p.immd(hostpush.SUBCH_CE, LAUNCH_DMA, LAUNCH_PITCH_COPY_SEM);
}

/// Host-engine semaphore release: writes `payload` to the sysmem word at
/// `sem_va` after all preceding methods (incl. flushed CE copies) complete.
pub fn semRelease(p: *hostpush.HostPush, sem_va: u64, payload: u32) void {
    p.incr(hostpush.SUBCH_HOST, SEM_ADDR_LO, 5);
    p.data(@truncate(sem_va));
    p.data(@intCast(sem_va >> 32));
    p.data(payload);
    p.data(0);
    p.data(SEM_EXECUTE_RELEASE);
}

/// Block-linear → pitch copy (de-tile): the GR engine renders color to a
/// block-linear surface when a Z buffer is bound (pitch color + Z is a HW
/// no-go — NVK "tiled shadow" fallback, nvk_cmd_draw.c:946-974); this brings
/// the frame back to pitch for the scanout. Src block geometry per
/// clc9b5.h: SET_SRC_BLOCK_SIZE 0x728 (HEIGHT 7:4 = log2 GOBs, GOB_HEIGHT
/// 15:12 = FERMI_8), SET_SRC_WIDTH 0x72c (bytes), _HEIGHT/_DEPTH/_LAYER,
/// SET_SRC_ORIGIN 0x73c. LAUNCH_DMA: 0x386 with SRC_MEMORY_LAYOUT (bit 7)
/// = BLOCKLINEAR (0) + SEMAPHORE release = 0x30e.
pub fn copyBlToPitch(p: *hostpush.HostPush, dst_va: u64, dst_pitch: u32, src_va: u64, src_row_bytes: u32, src_h: u32, src_bh_log2: u5, line_bytes: u32, lines: u32, sem_va: u64, payload: u32) void {
    p.incr(hostpush.SUBCH_CE, SET_SEMAPHORE_A, 3);
    p.data(@intCast(sem_va >> 32));
    p.data(@truncate(sem_va));
    p.data(payload);
    p.incr(hostpush.SUBCH_CE, 0x728, 5); // SET_SRC_BLOCK_SIZE..SET_SRC_LAYER
    p.data((@as(u32, src_bh_log2) << 4) | (1 << 12)); // HEIGHT log2, GOB_HEIGHT_FERMI_8
    p.data(src_row_bytes); // SET_SRC_WIDTH (bytes)
    p.data(src_h); // SET_SRC_HEIGHT
    p.data(1); // SET_SRC_DEPTH
    p.data(0); // SET_SRC_LAYER
    p.incr(hostpush.SUBCH_CE, 0x73c, 1); // SET_SRC_ORIGIN
    p.data(0);
    p.incr(hostpush.SUBCH_CE, OFFSET_IN_UPPER, 8);
    p.data(@intCast(src_va >> 32));
    p.data(@truncate(src_va));
    p.data(@intCast(dst_va >> 32));
    p.data(@truncate(dst_va));
    p.data(0); // PITCH_IN: unused for blocklinear src
    p.data(dst_pitch);
    p.data(line_bytes);
    p.data(lines);
    p.immd(hostpush.SUBCH_CE, LAUNCH_DMA, 0x30e); // BL src | pitch dst | MULTI_LINE | FLUSH | sem RELEASE | NON_PIPELINED
}
