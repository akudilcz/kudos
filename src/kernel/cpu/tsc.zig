//! TSC timekeeping: read the Time Stamp Counter, learn its frequency, and arm the
//! one-shot LAPIC TSC-deadline interrupt. Single source of truth for `rdtsc` and
//! the TSC frequency. Grounded in Intel SDM Vol 3B §18.17, cross-checked against
//! Linux arch/x86/kernel/tsc.c.

const klog = @import("../debug/klog.zig");
const timer = @import("../timer/timer.zig");
const cpu = @import("cpu.zig");

const IA32_TSC_DEADLINE: u32 = 0x6E0;

/// TSC ticks per second, set once by init(). 0 until then.
var tsc_hz: u64 = 0;

/// The TSC at the earliest kudos instruction (main_root.zig run() entry) — the anchor
/// for the boot-to-first-present budget (spec PERF-002). Stamped once at boot,
/// before tsc_hz is calibrated (the raw counter always advances on an invariant
/// TSC), and read back only once the frequency is known (by the first present).
pub var boot_entry_tsc: u64 = 0;

/// Milliseconds elapsed from boot entry (boot_entry_tsc) to `target_tsc`.
/// Requires a calibrated tsc_hz — true by the first present, long after init().
pub fn bootElapsedMs(target_tsc: u64) u64 {
    return ticksToMs(target_tsc -% boot_entry_tsc);
}

/// Milliseconds elapsed since `since_tsc` (an earlier rdtsc sample). Requires
/// init() — the single home of the "TSC delta → ms" conversion for deadlines
/// and progress reports.
pub fn elapsedMs(since_tsc: u64) u64 {
    return ticksToMs(rdtsc() -% since_tsc);
}

/// Microseconds elapsed since `since_tsc` (an earlier rdtsc sample). Requires
/// init(). u128-widened like `micros` so the multiply cannot overflow.
pub fn elapsedUs(since_tsc: u64) u64 {
    return ticksToUs(rdtsc() -% since_tsc);
}

/// TSC-tick delta → microseconds — the single home of the "ticks → µs"
/// conversion for latency and profiling reports. Requires init() (tsc_hz != 0);
/// callers that can run before calibration must gate on `hz() != 0`.
/// u128-widened so the multiply cannot overflow.
pub fn ticksToUs(delta_tsc: u64) u64 {
    return @intCast(@as(u128, delta_tsc) * 1_000_000 / tsc_hz);
}

/// TSC-tick delta → milliseconds, u128-widened so the multiply cannot overflow
/// at multi-GHz rates and long uptimes.
fn ticksToMs(delta_tsc: u64) u64 {
    return @intCast(@as(u128, delta_tsc) * 1000 / tsc_hz);
}

/// Read the 64-bit Time Stamp Counter. Invariant TSC on the target ⇒ deltas are
/// elapsed time.
pub inline fn rdtsc() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Highest standard CPUID leaf (CPUID.0:EAX), so we don't read a leaf the CPU
/// does not implement (which would return another leaf's data).
fn maxLeaf() u32 {
    return cpu.cpuid(0, 0).eax;
}

/// Whether the LAPIC supports TSC-deadline mode (CPUID.1:ECX[24]).
pub fn deadlineSupported() bool {
    return (cpu.cpuid(1, 0).ecx & (1 << 24)) != 0;
}

/// Determine `tsc_hz` once. Order (no silent default): CPUID leaf 0x15 (crystal ×
/// num/den) → leaf 0x16 (base MHz) → measure rdtsc against the PIT. Logs which
/// path produced the value. Requires the PIT running (timer.init) for the
/// fallback.
pub fn init() void {
    var msg: [80]u8 = undefined;

    // Idempotent: a single calibration owns tsc_hz. main_root.zig run() calls this once
    // (after interrupts are up, before GSP boot) for BOTH builds; the SMP path's
    // setupTimers may call again — return early so we don't waste ~100 ms
    // re-measuring or install a second owner of the value.
    if (tsc_hz != 0) return;

    if (maxLeaf() >= 0x15) {
        const l = cpu.cpuid(0x15, 0);
        if (l.ebx != 0 and l.ecx != 0) {
            // crystal_hz * num / den
            tsc_hz = @as(u64, l.ecx) * @as(u64, l.ebx) / @as(u64, l.eax);
            klog.puts(fmt(&msg, "tsc: {d} Hz from CPUID.15h (crystal)\n", tsc_hz));
            return;
        }
        if (l.ebx != 0 and maxLeaf() >= 0x16) {
            const base_mhz = cpu.cpuid(0x16, 0).eax;
            if (base_mhz != 0) {
                tsc_hz = @as(u64, base_mhz) * 1_000_000;
                klog.puts(fmt(&msg, "tsc: {d} Hz from CPUID.16h (base MHz)\n", tsc_hz));
                return;
            }
        }
    }

    // Fallback: measure rdtsc over a known PIT interval. Anchor to PIT tick
    // EDGES (wait for the count to advance before sampling) so the window is a
    // whole number of ticks, and measure over many ticks for accuracy. The PIT
    // runs at timer.hz() Hz (one tick = 1/hz s), so tsc_hz = tsc_delta / seconds.
    const pit_hz = timer.frequency();
    const window_ticks: u64 = pit_hz / 10; // ~100 ms regardless of PIT rate
    // Bound the PIT-edge waits with a RAW rdtsc spin cap: tsc_hz is not
    // calibrated yet, but the raw counter always advances, so this caps the
    // wall-clock spin without needing the frequency. ~10^11 cycles is many
    // seconds even at a very high clock — far beyond one ~10 ms PIT tick — so a
    // healthy PIT never trips it, and a masked/dead IRQ0 (which would otherwise
    // hang boot silently with no trace) panics LOUDLY instead.
    const SPIN_CAP: u64 = 100_000_000_000;
    const t0 = timer.now();
    var guard0 = rdtsc();
    while (timer.now() == t0) { // align to the next tick edge
        if (rdtsc() -% guard0 > SPIN_CAP) @panic("tsc: PIT not ticking during calibration (IRQ0 masked/dead?)");
    }
    const start_tick = timer.now();
    const start_tsc = rdtsc();
    guard0 = rdtsc();
    while (timer.now() -% start_tick < window_ticks) {
        if (rdtsc() -% guard0 > SPIN_CAP) @panic("tsc: PIT stalled mid-calibration (IRQ0 masked/dead?)");
    }
    const end_tsc = rdtsc();
    const elapsed_ticks = timer.now() -% start_tick;
    // tsc_hz = tsc_delta * pit_hz / elapsed_ticks  (elapsed_ticks/pit_hz = seconds)
    tsc_hz = (end_tsc - start_tsc) * pit_hz / elapsed_ticks;
    klog.puts(fmt(&msg, "tsc: {d} Hz from PIT calibration\n", tsc_hz));
}

/// Format a single u64 into `buf` for a calibration log line. Local one-value
/// helper so init() can log without pulling std.fmt into every call site; a
/// formatting failure degrades to a fixed marker string (log-only, non-fatal).
fn fmt(buf: []u8, comptime f: []const u8, v: u64) []const u8 {
    const std = @import("std");
    return std.fmt.bufPrint(buf, f, .{v}) catch "tsc: (fmt)\n";
}

/// TSC ticks per second (0 before init()).
pub fn hz() u64 {
    return tsc_hz;
}

/// Milliseconds since boot entry, from the free-running TSC — the
/// interrupt-free leg of the wall clock (timer.millis via uptime.ms) and the
/// deadman fuse's clock: the TSC advances whatever happens to interrupt
/// delivery. Returns 0 before calibration — callers treat 0 as "no clock yet"
/// (uptime falls back to the tick; the deadman stays disarmed rather than
/// arming a window against garbage).
pub fn millis() u64 {
    if (tsc_hz == 0) return 0;
    return ticksToMs(rdtsc() -% boot_entry_tsc);
}

/// Microseconds since boot entry (boot_entry_tsc) — the high-resolution clock
/// for per-frame animation, where the PIT tick (10 ms at 100 Hz) is far too
/// coarse: sampled on a 60 Hz frame cadence it yields visibly uneven steps.
/// The multiply runs in u128 because tsc_delta * 1e6 overflows u64 in under
/// two hours at multi-GHz rates. Requires init(); panics if tsc_hz is 0 so a
/// missing calibration is loud rather than a frozen clock.
pub fn micros() u64 {
    if (tsc_hz == 0) @panic("tsc.micros before tsc.init (tsc_hz==0)");
    const delta = rdtsc() -% boot_entry_tsc;
    return @intCast(@as(u128, delta) * 1_000_000 / tsc_hz);
}

/// TSC ticks in one period of `frequency_hz` (e.g. periodTicks(100) for 100 Hz).
pub fn periodTicks(frequency_hz: u64) u64 {
    return tsc_hz / frequency_hz;
}

/// TSC ticks in `ms` milliseconds — e.g. a scheduling quantum.
pub fn msTicks(ms: u64) u64 {
    return tsc_hz * ms / 1000;
}

/// TSC ticks in `us` microseconds. Requires init() (tsc_hz != 0).
pub fn usTicks(us: u64) u64 {
    return tsc_hz * us / 1_000_000;
}

/// Busy-wait `us` microseconds against the TSC (like Linux udelay). No MMIO, no
/// scheduler yield — a tight rdtsc spin, for sub-millisecond device delays where
/// the PIT (10 ms tick) is far too coarse. Requires init(); panics if tsc_hz is 0
/// so a missing calibration is loud rather than a silent zero-length delay.
pub fn udelay(us: u64) void {
    if (tsc_hz == 0) @panic("tsc.udelay before tsc.init (tsc_hz==0)");
    const deadline = rdtsc() + usTicks(us);
    while (rdtsc() < deadline) {
        asm volatile ("pause");
    }
}

/// Arm the one-shot TSC-deadline interrupt at absolute `deadline_tsc`. The LVT
/// timer must already be in TSC-deadline mode (lapic.useTscDeadline). Writing 0
/// disarms.
pub fn armDeadline(deadline_tsc: u64) void {
    // Fence before the arm (SDM Vol 3B §18.17.4).
    // The rdtsc that produced `deadline_tsc` (deadline = rdtsc() + delta at the call
    // site) is NOT ordered w.r.t. this wrmsr: the CPU may retire that rdtsc well
    // ahead of the arm, stamping the deadline from a stale (earlier) TSC value. On a
    // short delta that can leave the deadline already in the past at the moment the
    // MSR is written, firing immediately (spurious early event) or being missed.
    // mfence;lfence retires the deadline-computing rdtsc and prevents it (and the
    // wrmsr) from reordering, so the value is stamped as close as possible to the
    // arm. Mirrors Linux lapic_next_deadline()'s weak_wrmsr_fence().
    asm volatile ("mfence; lfence" ::: .{ .memory = true });
    cpu.wrmsr(IA32_TSC_DEADLINE, deadline_tsc);
}

/// Disarm the TSC-deadline timer by writing 0 to IA32_TSC_DEADLINE, so no further
/// timer interrupt fires until the next armDeadline.
pub fn disarmDeadline() void {
    cpu.wrmsr(IA32_TSC_DEADLINE, 0);
}
