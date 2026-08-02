//! Bounded hardware waits. The primitive driver spin-until-condition loops are
//! written against: each call carries a spin budget, so a wait that uses it
//! cannot spin forever; on exhaustion it traces and takes the caller-supplied
//! path forward. Scheduler and spinlock spins elsewhere in the tree do not
//! route through here.

const klog = @import("../../kernel/debug/klog.zig");

/// One CPU pause hint between polls.
fn pause() void {
    asm volatile ("pause");
}

/// Spin until `poll(ctx)` is true or `max_spins` is reached. Returns true if the
/// condition was met. On timeout: log `trace`, invoke `on_timeout(ctx)`, return
/// false. `ctx` carries the state the condition/continuation need (`{}` for
/// module-global state).
pub fn until(
    ctx: anytype,
    comptime cond: anytype,
    comptime on_timeout: anytype,
    max_spins: u32,
    trace: []const u8,
) bool {
    var spins: u32 = 0;
    while (spins < max_spins) : (spins += 1) {
        if (cond(ctx)) return true;
        pause();
    }
    klog.puts("wait timeout: ");
    klog.puts(trace);
    klog.putc('\n');
    on_timeout(ctx);
    return false;
}

/// Spin until `poll(ctx)` is true or `max_spins` is reached — SILENTLY. Returns true
/// if the condition was met.
///
/// USE THIS WHEN AN EMPTY WINDOW IS NOT AN ERROR. `until()` treats an exhausted spin
/// budget as a failure and TRACES it, which is right for a one-shot hardware wait ("the
/// controller never came ready") and wrong for a POLL — a caller that asks "has an event
/// arrived yet?" in a loop, under its own wall-clock deadline, and treats `false` as "not
/// yet". Tracing those calls a healthy wait a failure, and on a metered trace bus a few
/// hundred of them push everything else off the wire.
///
/// The REAL timeout is still traced once, by the caller that owns the deadline (awaitXfer's
/// XFER_WALL_MS, awaitBulk's BULK_WALL_MS, submitCommand's CMD_WALL_MS) — which is the only
/// place "this transfer is never completing" is actually known.
pub fn poll(ctx: anytype, comptime cond: anytype, max_spins: u32) bool {
    var spins: u32 = 0;
    while (spins < max_spins) : (spins += 1) {
        if (cond(ctx)) return true;
        pause();
    }
    return false;
}

/// Shared no-op continuation for callers that simply give up on timeout and let
/// the `false` return drive their own error path. Generic over the context type.
pub fn noop(ctx: anytype) void {
    _ = ctx;
}
