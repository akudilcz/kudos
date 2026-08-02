//! IPresent — the contract between the GPU present/compositor frame path
//! (src/drivers/gpu/present/present.zig) and the GPU hardware. A runtime vtable of function
//! pointers: the present layer calls through this instead of reaching directly
//! into ce/fifo/gmmu/vram/shim/modeset/chan, so the addressing + sequencing logic
//! above the seam is hardware-independent and host-testable.
//!
//! The REAL backend (present_real.zig, wraps the GPU modules) satisfies it on
//! the native 4090. The contract's addressing/pacing logic is covered on the
//! host by its pure sub-component suites — flip_stats, flip_pacing, fps_window,
//! tri_ring, overlay_plane — rather than a whole-vtable fake; the vtable itself
//! carries no logic to fake (every address/pitch is passed in per call).
//!
//! This module is a LEAF under src/iface/ (the cross-layer interface group): it
//! imports nothing hardware/freestanding, so both the kernel and the host tests
//! compile it. Do not add a HW import here.

/// Map / allocate failures. Fold back into the present layer's existing loud
/// "window un-mirrored" / "mirror OFF" fallbacks at the call sites.
pub const MapError = error{ BackendMapFailed, BackendVaExhausted, BackendVramExhausted };
/// Submit / drain / flip failures (fence timeout, flip drain timeout, flip submit).
pub const SubmitError = error{ BackendFenceTimeout, BackendDrainTimeout, BackendFlipFailed };

/// The vtable: one function pointer per hardware operation the steady-state frame
/// path performs. `ctx` is the backend's opaque state (RealCtx on HW).
/// Signatures deliberately carry every address/pitch PER CALL so the
/// interesting addressing logic (which VA, which pitch, source resolution, the
/// fence-carrying self-copy) stays ABOVE the seam in present.zig.
pub const VTable = struct {
    // ── addressing / residency ────────────────────────────────────────────────
    /// Map `len` bytes of coherent sysmem (contiguous phys) at GPU VA `va`. Every
    /// page in the range must be UNMAPPED — the backend errors loudly on overlap
    /// with a live mapping (never silently overwrites; use `remapSysmem` for that).
    mapSysmem: *const fn (ctx: *anyopaque, va: u64, phys: u64, len: u64) MapError!void,
    /// Re-point `len` bytes at GPU VA `va` (a slot the caller knows is currently
    /// mapped) to a NEW `phys`, overwriting the existing PTEs. Used to recycle a
    /// reclaimed mirror slot's sysmem VA onto the next window's surface without a
    /// fresh VA bump (mirror-slot reclaim on close). Every page in the range
    /// must already be validly mapped — an unmapped page is a caller accounting bug
    /// and errors loudly rather than falling back to a fresh map.
    remapSysmem: *const fn (ctx: *anyopaque, va: u64, phys: u64, len: u64) MapError!void,
    /// Map `len` bytes of VRAM (contiguous phys) at GPU VA `va`.
    mapVram: *const fn (ctx: *anyopaque, va: u64, phys: u64, len: u64) MapError!void,
    /// Allocate `size` bytes of VRAM aligned to `alignment`; returns its phys.
    allocVram: *const fn (ctx: *anyopaque, size: u64, alignment: u64) MapError!u64,
    /// Flush the CPU cache for [addr, addr+len) so the GPU reads fresh bytes.
    flushRange: *const fn (ctx: *anyopaque, addr: u64, len: u64) void,

    // ── batch lifecycle (one CE submission) ─────────────────────────────────────
    /// Open the (single) command batch. Asserts no batch is already open — the
    /// single shared pushbuffer means a nested open corrupts the outer batch.
    beginBatch: *const fn (ctx: *anyopaque) void,
    /// Stage one pitch-copy into the open batch. `fence`==0 → no completion
    /// semaphore; `fence`!=0 → this copy carries the CE semaphore release. The
    /// backend owns the semaphore address (always VA_SEM) and the pushbuffer.
    copyPitch: *const fn (ctx: *anyopaque, dst_va: u64, dst_pitch: u32, src_va: u64, src_pitch: u32, line_bytes: u32, lines: u32, fence: u32) void,
    /// Kick the staged batch and block until `fence` is signalled. Closes the batch.
    endBatch: *const fn (ctx: *anyopaque, fence: u32) SubmitError!void,
    /// Kick the staged batch and close it WITHOUT blocking on its fence. The caller must
    /// later `waitFence(fence)` before any consumer (e.g. the flip) reads the result.
    /// Lets the CE work overlap the caller's own idle time (the vblank wait) so the
    /// fence round-trip is off the critical path. Same channel → CE in-order.
    endBatchKick: *const fn (ctx: *anyopaque, fence: u32) SubmitError!void,
    /// Block until a fence kicked by `endBatchKick` is signalled (sysmem semaphore poll).
    waitFence: *const fn (ctx: *anyopaque, fence: u32) SubmitError!void,
    /// Allocate the next monotonic fence payload.
    nextFence: *const fn (ctx: *anyopaque) u32,

    // ── per-frame flip ──────────────────────────────────────────────────────────
    /// Block until the PREVIOUS flip on `head_index` has latched (its window
    /// channel drained at vblank) — the backstop before the CE may touch "back".
    waitFlipLatched: *const fn (ctx: *anyopaque, head_index: usize) SubmitError!void,
    /// Non-blocking: has the last flip on `head_index` latched? (paces the pump).
    flipReady: *const fn (ctx: *anyopaque, head_index: usize) bool,
    /// Flip `head_index` to scan out `scanout_phys` (build window image methods +
    /// interval=1 UPDATE, submit on the head's window channel). Latches next vblank.
    presentFlip: *const fn (ctx: *anyopaque, head_index: usize, scanout_phys: u64) SubmitError!void,
};

/// A backend handle: an opaque context + its vtable. The present State holds one.
/// Thin forwarding methods so call sites read `st.backend.copyPitch(...)`.
pub const IPresent = struct {
    ctx: *anyopaque,
    vt: *const VTable,

    pub fn mapSysmem(self: IPresent, va: u64, phys: u64, len: u64) MapError!void {
        return self.vt.mapSysmem(self.ctx, va, phys, len);
    }
    pub fn remapSysmem(self: IPresent, va: u64, phys: u64, len: u64) MapError!void {
        return self.vt.remapSysmem(self.ctx, va, phys, len);
    }
    pub fn mapVram(self: IPresent, va: u64, phys: u64, len: u64) MapError!void {
        return self.vt.mapVram(self.ctx, va, phys, len);
    }
    pub fn allocVram(self: IPresent, size: u64, alignment: u64) MapError!u64 {
        return self.vt.allocVram(self.ctx, size, alignment);
    }
    pub fn flushRange(self: IPresent, addr: u64, len: u64) void {
        self.vt.flushRange(self.ctx, addr, len);
    }
    pub fn beginBatch(self: IPresent) void {
        self.vt.beginBatch(self.ctx);
    }
    pub fn copyPitch(self: IPresent, dst_va: u64, dst_pitch: u32, src_va: u64, src_pitch: u32, line_bytes: u32, lines: u32, fence: u32) void {
        self.vt.copyPitch(self.ctx, dst_va, dst_pitch, src_va, src_pitch, line_bytes, lines, fence);
    }
    pub fn endBatch(self: IPresent, fence: u32) SubmitError!void {
        return self.vt.endBatch(self.ctx, fence);
    }
    pub fn endBatchKick(self: IPresent, fence: u32) SubmitError!void {
        return self.vt.endBatchKick(self.ctx, fence);
    }
    pub fn waitFence(self: IPresent, fence: u32) SubmitError!void {
        return self.vt.waitFence(self.ctx, fence);
    }
    pub fn nextFence(self: IPresent) u32 {
        return self.vt.nextFence(self.ctx);
    }
    pub fn waitFlipLatched(self: IPresent, head_index: usize) SubmitError!void {
        return self.vt.waitFlipLatched(self.ctx, head_index);
    }
    pub fn flipReady(self: IPresent, head_index: usize) bool {
        return self.vt.flipReady(self.ctx, head_index);
    }
    pub fn presentFlip(self: IPresent, head_index: usize, scanout_phys: u64) SubmitError!void {
        return self.vt.presentFlip(self.ctx, head_index, scanout_phys);
    }
};
