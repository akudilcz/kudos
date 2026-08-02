//! `prime N` — load THIS core: scan integers for primes until one >= N.
//! Runs inline on the terminal's own core (visible in `ps` CPU%), never
//! proxied to core 0.

const std = @import("std");
const sched = @import("../../kernel/sched/sched.zig");
const klog = @import("../../kernel/debug/klog.zig");
const Out = @import("../out.zig").Out;

// How many prime-search iterations run between cooperative yields. Small
// enough that the render task on a shared core waits only ~this-many trial
// divisions (tens of µs) for the CPU, large enough that the yield overhead is
// negligible against the search. Only the SMP build yields (yieldPeriodic gates
// on a live scheduler); the single-core build ignores it and runs to completion.
const YIELD_INTERVAL: u64 = 4096;

/// Primality test by trial division up to sqrt(n) (only odd divisors after 2).
fn isPrime(n: u64) bool {
    if (n < 2) return false;
    if (n % 2 == 0) return n == 2;
    var d: u64 = 3;
    while (d * d <= n) : (d += 2) {
        if (n % d == 0) return false;
    }
    return true;
}

/// `prime N`: scan integers for primes on THIS core until one >= `N` is found,
/// then stop and report. Pegs this core to ~100% (visible in `ps` CPU%) without
/// touching any other core or the system process — the user picks `N` to control
/// how long it runs.
pub fn run(out: Out, args: []const u8) void {
    const target = std.fmt.parseInt(u64, args, 10) catch {
        out.str("usage: prime N   (run until a prime >= N is found)\n");
        return;
    };
    // Label the current task's activity so `ps` shows the running search.
    sched.setActivity("prime");
    defer sched.clearActivity();

    out.str("prime: searching this core for a prime >= ");
    out.num(target);
    out.str(" ...\n");

    var count: u64 = 0;
    var largest: u64 = 0;
    var n: u64 = 2;
    var since_yield: u64 = 0;
    while (true) : (n += 1) {
        if (isPrime(n)) {
            count += 1;
            largest = n;
            if (n >= target) break;
        }
        // Stop if the terminal was closed while prime ran (cooperative cancel) —
        // one acquire load per iteration.
        if (sched.cancelled()) break;
        // Cooperatively yield often so a CPU-bound search sharing the RENDER core
        // does not hold its whole preemption quantum each round-robin cycle: the
        // system/render task would then run only once per (Ntasks × quantum) and
        // the desktop would stutter. Yielding returns to the back of the FIFO
        // within microseconds, so `prime` slows only by the yield overhead and
        // still pegs the core in `ps`. No-op on the single-core build
        // (yieldPeriodic gates on a live scheduler).
        since_yield += 1;
        if (since_yield >= YIELD_INTERVAL) {
            since_yield = 0;
            sched.yieldPeriodic();
        }
    }

    out.str("prime: found ");
    out.num(largest);
    out.str(" (");
    out.num(count);
    out.str(" primes scanned)\n");
    var sbuf: [64]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&sbuf, "prime: found {d} ({d} scanned)\n", .{ largest, count }) catch "prime: done\n");
}
