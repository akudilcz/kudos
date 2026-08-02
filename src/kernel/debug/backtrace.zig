//! RBP frame-pointer backtrace. The
//! kernel is built with `omit_frame_pointer = false` (build.zig), so at any point
//! RBP points at the current frame's saved-RBP slot: `[rbp]` = the caller's RBP,
//! `[rbp+8]` = the return address into the caller. Walking that chain yields the
//! call stack, symbolized offline against the ELF (addr2line) — the kernel only
//! emits raw addresses.
//!
//! Pure logic at the core: `walk` takes the seed RBP, an emit callback, and the
//! stack bounds, so it is host-unit-tested against a synthetic stack. `here()`
//! (the one asm) reads the caller's RBP for the panic seed. One walker, two
//! sinks on top of it: `emitKlog` streams to the trace bus (the deadman's
//! wedge report), and crashlog.emitBacktrace writes into a fatal path's crash
//! record — fatal paths never touch the bus (crashlog.zig owns that invariant).

const std = @import("std");
const klog = @import("klog.zig");

/// Hard cap on frames walked, so a corrupt chain (a cycle, or garbage RBP) can
/// never loop forever or wander off into unmapped memory. Deep enough for any real
/// kernel call stack; a truncated trace still shows the top frames that matter.
pub const MAX_FRAMES: usize = 32;

/// Read the CALLER's RBP — the frame-pointer seed for a backtrace taken inline
/// (the panic handler). `noinline` so this function actually has its own frame and
/// `[rbp]` is the caller's saved RBP; the walk then skips this frame by starting at
/// `[rbp]`. Returns 0 if frame pointers were somehow omitted (walk then no-ops).
pub noinline fn here() usize {
    return asm volatile ("mov %%rbp, %[r]"
        : [r] "=r" (-> usize),
    );
}

/// Read the current RSP — the low bound for a backtrace on the stack we are running
/// on. Every frame's RBP is at or above this, so `[rsp, rsp+MAX_STACK_SPAN)` bounds
/// the walk to identity-mapped stack RAM without needing to know which stack (boot
/// stack or a task stack) we faulted on.
pub inline fn rsp() usize {
    return asm volatile ("mov %%rsp, %[r]"
        : [r] "=r" (-> usize),
    );
}

/// Generous upper bound on how far above the current RSP any valid frame pointer
/// can lie: far larger than any kernel stack (the boot stack or a task stack,
/// sched.STACK_SIZE). Used to derive [lo, hi) bounds from RSP alone — the containment
/// guard in `walk` then keeps every frame read inside this identity-mapped span so
/// a garbage RBP cannot fault the panic/fault handler by reading unmapped memory.
pub const MAX_STACK_SPAN: usize = 2 * 1024 * 1024;

/// Emit an RBP backtrace to klog (→ netdebug via its sink): one
/// `*** BT #<n> <addr>` line per frame, returning the frame count. The trace-
/// bus sink over `walkFrom`, used where the core is alive and the bus is safe
/// (the deadman wedge report); fatal paths use crashlog.emitBacktrace, the
/// same lines into the crash record. The lines are greppable (`BT`) and carry
/// raw addresses only; addr2line maps them to file:line against the built ELF.
pub fn emitKlog(seed_rbp: usize, cur_rsp: usize) usize {
    const Emit = struct {
        fn line(idx: *usize, addr: usize) void {
            klog.puts("*** BT #");
            klog.putHex(idx.*);
            klog.putc(' ');
            klog.putHex(addr);
            klog.putc('\n');
            idx.* += 1;
        }
    };
    var idx: usize = 0;
    return walkFrom(seed_rbp, cur_rsp, &idx, Emit.line);
}

/// Backtrace the stack we are currently on: seed the RBP chain at `start_rbp` and
/// bound the walk to `[cur_rsp, cur_rsp + MAX_STACK_SPAN)`. The convenience the
/// panic (main_root.zig) and fault (isr.zig) handlers use — they pass the fault-site RBP
/// and the current RSP; this derives safe bounds and streams return addresses.
pub fn walkFrom(
    start_rbp: usize,
    cur_rsp: usize,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), usize) void,
) usize {
    // Saturating add so a near-ceiling RSP can't wrap the high bound to a small value.
    const hi = if (cur_rsp > std.math.maxInt(usize) - MAX_STACK_SPAN)
        std.math.maxInt(usize)
    else
        cur_rsp + MAX_STACK_SPAN;
    return walk(start_rbp, cur_rsp, hi, ctx, emit);
}

/// Walk the RBP chain from `start_rbp`, calling `emit(return_address)` for each
/// frame (innermost first), and return the number of frames emitted. Bounded three
/// ways so a corrupt stack cannot fault or spin:
///   - at most MAX_FRAMES frames;
///   - every RBP must lie within [stack_lo, stack_hi) with room for both the saved
///     RBP and the return-address slot, so the two 8-byte reads stay in the stack;
///   - each RBP must be strictly greater than the previous one (frames grow toward
///     higher addresses as we unwind), which rules out a cycle or a downward jump.
/// A zero/garbage seed or a first RBP out of range yields an empty walk (0). The
/// caller passes the stack bounds it knows (the running task's stack, or the kernel
/// boot stack); an unknown-bounds caller may pass the full canonical range.
pub fn walk(
    start_rbp: usize,
    stack_lo: usize,
    stack_hi: usize,
    ctx: anytype,
    comptime emit: fn (@TypeOf(ctx), usize) void,
) usize {
    var rbp = start_rbp;
    var prev: usize = 0;
    var n: usize = 0;
    while (n < MAX_FRAMES) {
        // The frame must hold [rbp] (saved rbp) and [rbp+8] (return addr): require
        // 16 bytes inside the stack and 8-byte alignment (the ABI keeps RBP aligned).
        // Checked as `rbp < stack_lo`, `rbp >= stack_hi`, then `stack_hi - rbp < 16`
        // — all subtraction-free of underflow (the `>= stack_hi` clause guarantees
        // `rbp < stack_hi` before the final `stack_hi - rbp`), so no `- 16`/`+ 16`
        // can wrap for any usize bounds.
        if (rbp == 0 or (rbp & 0x7) != 0) break;
        if (rbp < stack_lo or rbp >= stack_hi or stack_hi - rbp < 16) break;
        if (rbp <= prev) break; // must unwind upward — no cycle / no descent
        const saved_rbp = @as(*const usize, @ptrFromInt(rbp)).*;
        const ret_addr = @as(*const usize, @ptrFromInt(rbp + 8)).*;
        if (ret_addr == 0) break; // outermost frame (bootstrap) — done
        emit(ctx, ret_addr);
        n += 1;
        prev = rbp;
        rbp = saved_rbp;
    }
    return n;
}
