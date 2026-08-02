//! `rt N` — a drift-free 10 Hz real-time task on THIS core, reporting wake
//! jitter and cumulative drift. Runs inline on the terminal's own core, never
//! proxied to core 0.

const std = @import("std");
const sched = @import("../../kernel/sched/sched.zig");
const schedsleep = @import("../../kernel/sched/sleep.zig");
const tsc = @import("../../kernel/cpu/tsc.zig");
const klog = @import("../../kernel/debug/klog.zig");
const Out = @import("../out.zig").Out;

const RT_HZ: u64 = 10; // real-time period frequency (10 Hz = 100 ms period)

var rt_sink: u64 = 0; // keeps doRtWork from being optimized away

/// Result of the most recent `rt` run, for the verification harness to assert on.
pub const RtResult = struct {
    valid: bool = false,
    periods: u64 = 0,
    jit_min_ns: u64 = 0,
    jit_mean_ns: u64 = 0,
    jit_max_ns: u64 = 0,
    drift_us: u64 = 0,
};
var last_rt: RtResult = .{};

/// The most recent `rt` result (verification only).
pub fn lastRt() RtResult {
    return last_rt;
}

/// `rt N`: run a drift-free 10 Hz real-time task for `N` periods on THIS core.
/// Each period sleeps until an ABSOLUTE deadline (`base + n*period`, never
/// `now + period`) so per-period latency cannot accumulate into drift; the LAPIC
/// TSC-deadline timer wakes it within microseconds. Reports per-period wake jitter
/// (min/mean/max ns — sub-µs wakes are common, so ns is the useful scale) and
/// cumulative drift (µs) vs the ideal N × period.
pub fn run(out: Out, args: []const u8) void {
    const periods = std.fmt.parseInt(u64, args, 10) catch {
        out.str("usage: rt N   (run N periods of a 10 Hz real-time task)\n");
        return;
    };
    sched.setActivity("rt");
    defer sched.clearActivity();

    const hz = tsc.hz();
    if (hz == 0) {
        out.str("rt: TSC frequency unknown\n");
        return;
    }
    const period = tsc.periodTicks(RT_HZ); // TSC ticks per 10 Hz period
    const US: u64 = 1_000_000; // ticks → µs: ticks * US / hz
    const NS: u64 = 1_000_000_000; // ticks → ns: ticks * NS / hz (u128 intermediate)

    out.str("rt: 10 Hz, ");
    out.num(periods);
    out.str(" periods ...\n");

    var max_jit: u64 = 0;
    var min_jit: u64 = ~@as(u64, 0);
    var sum_jit: u64 = 0;
    var samples: u64 = 0;

    const base = tsc.rdtsc();
    var n: u64 = 1;
    while (n <= periods) : (n += 1) {
        const target = base + n * period; // ABSOLUTE — no drift
        schedsleep.sleepUntilTsc(target);
        const woke = tsc.rdtsc();
        const jit_ticks = if (woke > target) woke - target else 0;
        if (jit_ticks > max_jit) max_jit = jit_ticks;
        if (jit_ticks < min_jit) min_jit = jit_ticks;
        sum_jit += jit_ticks;
        samples += 1;

        doRtWork(); // small per-period unit of work

        if (sched.cancelled()) break;
        if (!out.alive()) break;
    }

    if (samples == 0) {
        out.str("rt: no periods run\n");
        return;
    }

    // Cumulative drift: actual total elapsed vs the ideal `samples × period`.
    const elapsed = tsc.rdtsc() - base;
    const ideal = samples * period;
    const drift_ticks = if (elapsed > ideal) elapsed - ideal else ideal - elapsed;
    const drift_us = drift_ticks * US / hz;
    // ns needs a u128 intermediate: max_jit * 1e9 overflows u64 above ~3.7s of jitter.
    const ticksToNs = struct {
        fn f(ticks: u64, hz_: u64, ns: u64) u64 {
            return @intCast(@as(u128, ticks) * ns / hz_);
        }
    }.f;
    const max_ns = ticksToNs(max_jit, hz, NS);
    const min_ns = ticksToNs(min_jit, hz, NS);
    const mean_ns = ticksToNs(sum_jit / samples, hz, NS);

    last_rt = .{
        .valid = true,
        .periods = samples,
        .jit_min_ns = min_ns,
        .jit_mean_ns = mean_ns,
        .jit_max_ns = max_ns,
        .drift_us = drift_us,
    };

    out.str("rt: jitter min/mean/max = ");
    out.num(min_ns);
    out.str("/");
    out.num(mean_ns);
    out.str("/");
    out.num(max_ns);
    out.str(" ns; drift = ");
    out.num(drift_us);
    out.str(" us over ");
    out.num(samples);
    out.str(" periods\n");
    var sbuf: [120]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&sbuf, "rt: done: jitter min/mean/max={d}/{d}/{d}ns drift={d}us over {d} periods\n", .{ min_ns, mean_ns, max_ns, drift_us, samples }) catch "rt: done\n");
}

/// One period's worth of real-time work — a small fixed compute unit. Kept short
/// so the core spends most of each period asleep (a modest `ps` CPU%).
fn doRtWork() void {
    var acc: u64 = 0;
    var i: u64 = 0;
    while (i < 2000) : (i += 1) acc +%= i *% 2654435761;
    rt_sink +%= acc;
}
