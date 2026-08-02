//! `memfault` — deliberately read unmapped memory in THIS session's address
//! space (test-hooks builds only): the MEM-005/006 regression trigger. The
//! access faults; the handler classifies it as this session's
//! (sessionspace.containCurrentFault), counts it in `mem.space_faults`, and
//! kills only this session — its window closes, the desktop and every other
//! session survive. Never compiled into a shipping image.

const buildinfo = @import("buildinfo");
const Out = @import("../out.zig").Out;

/// Canonical, and far above the session identity map (which tops out at
/// 512 GiB) — unmapped in every session space by construction, so the read
/// below is a guaranteed page fault, never a wild hit.
const UNMAPPED_PROBE_ADDR: usize = 1 << 45; // 32 TiB

pub fn run(out: Out, args: []const u8) void {
    _ = args;
    if (comptime !buildinfo.smp) {
        // No session spaces on the single-core kernel: the fault would take
        // the kernel path and the machine with it — refuse loudly instead.
        out.str("memfault: needs the smp kernel (per-session address spaces)\n");
        return;
    }
    out.str("memfault: reading unmapped memory (fault-containment test)\n");
    const p: *volatile u8 = @ptrFromInt(UNMAPPED_PROBE_ADDR);
    _ = p.*;
    // Unreachable on a correct kernel: the fault kills this task.
    out.str("memfault: SURVIVED an unmapped read — containment is broken\n");
}
