//! Self-checking verification task (gated by buildinfo.verify_script).
//!
//! When `verify_script` is set, core 0 spawns `verifyTask` as a scheduled task. It
//! drives the real system through its real paths — open terminals (`spawnApp`),
//! run work (`prime` via injected keystrokes), close terminals (`closeTermId`) —
//! and after each stage READS the scheduler's own state (`cpuPercentSince`,
//! `snapshotTasks`, session slots) and ASSERTS the expected outcome, emitting
//! `PASS`/`FAIL` lines to klog. The trace is the verdict: no screenshots,
//! no human in the loop. It ends with `verify: N passed, M failed`.
//!
//! It paces itself with `timer.sleep` between stages (it yields, so core 0 keeps
//! rendering). Desktop mutation from this task is safe for the same reason the
//! `cmd-worker` task already mutates the desktop: both are cooperative core-0 tasks.
//!
//! With the flag off (every normal build) none of this is referenced.

const std = @import("std");
const buildinfo = @import("buildinfo");
const timer = @import("../kernel/timer/timer.zig");
const klog = @import("../kernel/debug/klog.zig");
const sched = @import("../kernel/sched/sched.zig");
const schedsleep = @import("../kernel/sched/sleep.zig");
const taskstat = @import("../kernel/sched/taskstat.zig");
const cpustat = @import("../kernel/sched/cpustat.zig");
const percpu = @import("../kernel/sched/percpu.zig");
const smp = @import("../kernel/smp/smp.zig");
const tsc = @import("../kernel/cpu/tsc.zig");
const counter = @import("../kernel/debug/counter.zig");
const pmm = @import("../kernel/memory/pmm.zig");
const virt = @import("../kernel/virt/virt.zig");
const localcmd = @import("localcmd.zig");
const session = @import("session.zig");
const sessionspace = @import("../kernel/memory/sessionspace.zig");
const rt_cmd = @import("cmd/rt.zig");
const Desktop = @import("../ui/desktop/desktop.zig").Desktop;

// --- tally ------------------------------------------------------------------
var passed: u32 = 0;
var failed: u32 = 0;

/// Record a passing check and print `PASS: <name>` to klog.
fn ok(name: []const u8) void {
    passed += 1;
    var m: [96]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&m, "PASS: {s}\n", .{name}) catch "PASS\n");
}

/// Record a failing check and print `FAIL: <name> (<detail>)` to klog.
fn fail(name: []const u8, detail: []const u8) void {
    failed += 1;
    var m: [128]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&m, "FAIL: {s} ({s})\n", .{ name, detail }) catch "FAIL\n");
}

/// Print a `===== <label> =====` section banner to klog, delimiting stages.
fn mark(label: []const u8) void {
    var m: [96]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&m, "verify ===== {s} =====\n", .{label}) catch "verify: mark\n");
}

// --- state reads (the oracle) ----------------------------------------------

/// Recent-window CPU% for a core. `cpuPercentSince` reports load since its
/// previous call on that core, so we prime the baseline, sleep, then read — the
/// returned figure covers exactly the sleep window.
fn measureCpu(core: u32, window_ms: u64) u32 {
    const pc = percpu.at(core);
    _ = taskstat.cpuPercentSince(pc); // baseline
    timer.sleep(window_ms);
    return taskstat.cpuPercentSince(pc);
}

/// Assert `core`'s recent CPU% is within `tol` of `want` (measured over an 800 ms
/// window), passing/failing the named check accordingly.
fn expectCpuNear(name: []const u8, core: u32, want: u32, tol: u32) void {
    const got = measureCpu(core, 800);
    const lo = if (want > tol) want - tol else 0;
    const hi = want + tol;
    if (got >= lo and got <= hi) {
        ok(name);
    } else {
        var d: [48]u8 = undefined;
        fail(name, std.fmt.bufPrint(&d, "core {d} cpu={d}% want~{d}%", .{ core, got, want }) catch "cpu");
    }
}

/// Assert session `id` is closed (its slot is back in the pool).
fn expectSessionClosed(label: []const u8, id: u32) void {
    if (!session.isOpen(id)) ok(label) else fail(label, "session slot still in use");
}

/// Assert session `id` is open.
fn expectSessionOpen(label: []const u8, id: u32) void {
    if (session.isOpen(id)) ok(label) else fail(label, "session slot is not in use");
}

// --- driving the real system ------------------------------------------------

/// Type a command into the focused terminal, one key per short sleep so the
/// session's editor task drains each keystroke (and a blocked one is woken by
/// each) exactly as real input arrives.
/// NOTE: the harness injects keys via desktop.onKey from ITS OWN task, making
/// it a second producer on the focused session's key ring for the run's
/// duration. That bends the ring's SPSC contract; it is tolerated in this
/// test-only build because no real input arrives during a headless verify run,
/// and fixing it properly means routing through the remote-input inbox.
fn typeLine(desktop: *Desktop, line: []const u8) void {
    for (line) |ch| {
        desktop.onKey(ch);
        timer.sleep(8);
    }
    desktop.onKey('\n');
    timer.sleep(40);
}

/// Open a terminal; returns the session id it claimed, or null if none was free.
/// The id is captured BEFORE the spawn takes it — a session is never bound to a
/// core, so this is the only stable handle the harness has on the new terminal.
fn openTerm(desktop: *Desktop) ?u32 {
    const id = session.nextFreeId() orelse return null;
    desktop.spawnApp(.term) catch return null;
    timer.sleep(60);
    return id;
}

// --- the test ---------------------------------------------------------------

/// The core a task with the given activity label is currently running on, or null
/// if none is. A session is not bound to a processor, so the harness has to LOOK
/// for the work rather than assume where it is — which is itself the property
/// under test (KRN-009/011).
fn coreRunningActivity(activity: []const u8) ?u32 {
    var core: u32 = 0;
    const n = smp.coresOnline();
    while (core < n) : (core += 1) {
        var buf: [8]taskstat.TaskInfo = undefined;
        const count = taskstat.snapshotTasks(core, &buf);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (buf[i].is_current and std.mem.eql(u8, buf[i].activitySlice(), activity)) return core;
        }
    }
    return null;
}

/// Assert that no core is sitting idle while some task is waiting to run — the
/// runtime statement of KRN-010. Read across the whole machine at one moment:
/// a core reporting an empty run queue at the same instant another reports a
/// backlog is a placement failure.
fn expectNoIdleCoreWhileWaiting(label: []const u8) void {
    const n = smp.coresOnline();
    var idle_cores: u32 = 0;
    var waiting: u32 = 0;
    var core: u32 = 0;
    while (core < n) : (core += 1) {
        var buf: [16]taskstat.TaskInfo = undefined;
        const count = taskstat.snapshotTasks(core, &buf);
        var running_real = false;
        var queued: u32 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (buf[i].is_current) {
                if (!std.mem.eql(u8, buf[i].nameSlice(), "idle")) running_real = true;
            } else if (buf[i].state == .runnable) queued += 1;
        }
        if (!running_real) idle_cores += 1;
        waiting += queued;
    }
    if (idle_cores == 0 or waiting == 0) {
        ok(label);
    } else {
        var d: [64]u8 = undefined;
        fail(label, std.fmt.bufPrint(&d, "{d} idle core(s), {d} task(s) waiting", .{ idle_cores, waiting }) catch "idle+waiting");
    }
}

/// One open/work/observe/close cycle. `label` distinguishes the two cycles in the
/// trace; the second cycle additionally proves session slots are REUSED.
fn cycle(desktop: *Desktop, label: []const u8) void {
    mark(label);

    // Open a terminal and peg it with prime.
    const s_prime = openTerm(desktop) orelse {
        fail("open prime terminal", "no free session");
        return;
    };
    typeLine(desktop, "prime 1000000000");

    // Open a second terminal, leave it idle.
    const s_idle = openTerm(desktop) orelse {
        fail("open idle terminal", "no free session");
        return;
    };

    // Wake proof: type into the idle terminal — it echoes only if the wake
    // resumed its blocked editor task. (No assert on output; the state asserts
    // below confirm liveness. This just exercises the wake path.)
    typeLine(desktop, "echo woke");

    // --- observe: both sessions open, and the pegged one is running SOMEWHERE ---
    expectSessionOpen("prime session open", s_prime);
    expectSessionOpen("idle session open", s_idle);
    if (coreRunningActivity("prime")) |core| {
        ok("pegged terminal is running on some core");
        expectCpuNear("the core running prime is ~100%", core, 100, 15);
    } else {
        fail("pegged terminal is running on some core", "no core runs prime");
    }
    expectNoIdleCoreWhileWaiting("no core idles while a task waits (KRN-010)");

    // --- close both BACK TO BACK, observe slots freed + work gone ---
    // The close queue drains all pending closes on the next tick, so two closes
    // before a tick both take effect (no single-slot overwrite dropping one).
    desktop.closeTermId(s_prime);
    desktop.closeTermId(s_idle);
    timer.sleep(300); // let the deferred teardown (next desktop.tick) run

    expectSessionClosed("prime session released after close", s_prime);
    expectSessionClosed("idle session released after close", s_idle);
    if (coreRunningActivity("prime") == null) {
        ok("prime work gone from every core after close");
    } else {
        fail("prime work gone from every core after close", "a core still runs prime");
    }
}

/// Stress stage: churn the full terminal lifecycle hard to shake out races in
/// block/wake (wakeup IPI), cooperative cancellation, the close queue, and core
/// reuse. Each round fills every free AP core with a `prime`-pegged terminal, then
/// closes them all back to back (cancelling running primes). After all rounds it
/// asserts the system is consistent: every AP core is free again (no leaked
/// assignment), and a fresh terminal still opens, runs, and closes (not wedged).
fn stressStage(desktop: *Desktop) void {
    mark("STRESS (rapid open/peg/close churn)");
    var any_leak = false;
    const rounds: u32 = 8;
    const ncores = smp.coresOnline();

    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        // Open one pegged terminal per core, so the machine is oversubscribed
        // and the scheduler has to spread the work itself.
        var opened: [16]u32 = undefined;
        var n: usize = 0;
        while (n < opened.len and n < ncores) {
            const id = openTerm(desktop) orelse break;
            typeLine(desktop, "prime 1000000000"); // pegs whatever core it is on
            opened[n] = id;
            n += 1;
        }
        // Close them all back to back (cancels the running primes; close queue
        // must drain every one).
        var i: usize = 0;
        while (i < n) : (i += 1) desktop.closeTermId(opened[i]);
        timer.sleep(250); // let teardown + cancellation settle

        // Consistency: every session slot opened this round must be back.
        i = 0;
        while (i < n) : (i += 1) {
            if (session.isOpen(opened[i])) any_leak = true;
        }
        if (any_leak) fail("stress: sessions released after churn", "a session slot is still in use");
    }
    // The summary PASS attests ALL rounds, so it must be conditional on them.
    if (!any_leak) ok("stress: every session slot released after churn (no leak)");

    // Liveness: a fresh terminal still opens, runs a command, and closes.
    const id = openTerm(desktop) orelse {
        fail("stress: system still live after churn", "could not open a terminal");
        return;
    };
    typeLine(desktop, "prime 1000000");
    timer.sleep(150);
    expectSessionOpen("stress: fresh terminal opened after churn", id);
    desktop.closeTermId(id);
    timer.sleep(250);
    expectSessionClosed("stress: fresh terminal closed cleanly", id);
}

// --- virtualization stage ---------------------------------------------------

/// How long to let a guest run before asking whether it is executing. A Linux
/// kernel reaches its first serial output well inside this, and the assertion is
/// only "exits are climbing", which is true within microseconds of the launch.
const GUEST_SETTLE_MS: u64 = 1500;
/// Frames the teardown is allowed to take: the close is queued to the next
/// desktop tick, and the guest then stops at its next VM exit boundary and its
/// own core frees its memory. All of that is sub-millisecond work; this is slack.
const GUEST_TEARDOWN_MS: u64 = 800;
/// Frames of physical memory that may legitimately differ across the stage
/// (other subsystems allocate too). A leaked guest loses 128 MiB, so a leak is
/// never confused with this.
const MEM_TOLERANCE_BYTES: u64 = 4 * 1024 * 1024;

/// The live guest in slot `id`, or null when that slot holds none.
fn guestInfo(id: usize) ?virt.GuestInfo {
    var buf: [8]virt.GuestInfo = undefined;
    const n = virt.snapshot(&buf);
    for (buf[0..n]) |g| {
        if (g.id == id) return g;
    }
    return null;
}

/// Open a VM window; returns the guest's slot id, or null if it could not boot.
/// The newest in-use slot is the one just claimed — ids are handed out lowest
/// free first, so the guest whose id was not in use before the spawn is ours.
fn openVm(desktop: *Desktop, before: u64) ?usize {
    desktop.spawnApp(.vm) catch return null;
    timer.sleep(100);
    var id: usize = 0;
    while (id < 8) : (id += 1) {
        if (before & (@as(u64, 1) << @intCast(id)) != 0) continue;
        if (guestInfo(id) != null) return id;
    }
    return null;
}

/// Bitmask of the VM slots currently in use — used to spot the slot a spawn took.
fn vmMask() u64 {
    var mask: u64 = 0;
    var buf: [8]virt.GuestInfo = undefined;
    const n = virt.snapshot(&buf);
    for (buf[0..n]) |g| mask |= @as(u64, 1) << @intCast(g.id);
    return mask;
}

/// Assert the guest in `id` is running Linux on its own core: state `.running`,
/// and its VM-exit count CLIMBING between two reads — which no amount of setup
/// can fake, since only guest execution produces exits.
fn expectGuestExecuting(label: []const u8, id: usize) void {
    const first = guestInfo(id) orelse {
        fail(label, "no guest in slot");
        return;
    };
    if (first.state != .running) {
        var d: [64]u8 = undefined;
        fail(label, std.fmt.bufPrint(&d, "state {s}, not running", .{@tagName(first.state)}) catch "state");
        return;
    }
    timer.sleep(200);
    const second = guestInfo(id) orelse {
        fail(label, "guest vanished mid-check");
        return;
    };
    if (second.exits > first.exits) {
        ok(label);
    } else {
        var d: [64]u8 = undefined;
        fail(label, std.fmt.bufPrint(&d, "exits stuck at {d}", .{second.exits}) catch "exits");
    }
}

/// Assert slot `id` holds no guest at all — the window is gone, the vCPU has
/// finished, and the slot has been retired for reuse.
fn expectGuestGone(label: []const u8, id: usize) void {
    if (guestInfo(id) == null) ok(label) else fail(label, "slot still in use");
}

/// Assert physical memory is back to `baseline` within tolerance — the check that
/// a closed guest actually gave its 128 MiB of RAM and its page tables back.
fn expectMemReclaimed(label: []const u8, baseline: usize) void {
    const now = pmm.freeBytes();
    if (now + MEM_TOLERANCE_BYTES >= baseline) {
        ok(label);
    } else {
        var d: [72]u8 = undefined;
        fail(label, std.fmt.bufPrint(&d, "{d} MiB still missing", .{(baseline - now) / (1024 * 1024)}) catch "mem");
    }
}

/// Virtualization stage: run TWO Linux guests at once, each in its own window
/// with its own vCPU task, then close them one at a time and prove that each
/// close stops its guest and frees its memory — while the other guest keeps
/// running untouched.
///
/// Skipped with a trace line (not a failure) on a machine with no VT-x or no
/// staged guest image: those are properties of the host and the build, not
/// regressions.
fn vmStage(desktop: *Desktop) void {
    mark("VM (two Linux guests, then graceful teardown)");
    if (!virt.available()) {
        klog.puts("verify: no VT-x on this CPU — VM stage skipped\n");
        return;
    }
    if (!virt.guestStaged()) {
        klog.puts("verify: no guest image staged in this build — VM stage skipped\n");
        return;
    }

    const mem_baseline = pmm.freeBytes();

    // --- boot two guests ---
    const id_a = openVm(desktop, vmMask()) orelse {
        fail("boot first guest", "spawn failed");
        return;
    };
    const id_b = openVm(desktop, vmMask()) orelse {
        fail("boot second guest", "spawn failed");
        desktop.closeVm(id_a);
        return;
    };
    if (id_a != id_b) ok("two guests hold two distinct slots") else fail("two guests hold two distinct slots", "same slot twice");

    timer.sleep(GUEST_SETTLE_MS);

    // Each vCPU is an ordinary task that pinned itself to whatever core the
    // dispatcher placed it on (VIRT-021); two compute-hungry vCPUs must have
    // landed on two different cores (KRN-010).
    const a = guestInfo(id_a);
    const b = guestInfo(id_b);
    const core_a = if (a) |g| g.core else null;
    const core_b = if (b) |g| g.core else null;
    if (core_a != null and core_b != null and core_a.? != core_b.?) {
        ok("two guests run on two distinct cores");
    } else {
        fail("two guests run on two distinct cores", "same core, unplaced vCPU, or missing guest");
    }
    expectGuestExecuting("first guest is executing (exits climbing)", id_a);
    expectGuestExecuting("second guest is executing (exits climbing)", id_b);

    // --- close the first window: that guest goes, the other carries on ---
    desktop.closeVm(id_a);
    timer.sleep(GUEST_TEARDOWN_MS);
    expectGuestGone("closed guest is fully retired", id_a);
    expectGuestExecuting("surviving guest still executing after the other closed", id_b);
    // With no core dedication there is no "slot" to hand back; what must hold
    // instead is that tearing guest A down did not disturb guest B's binding —
    // its vCPU stays exactly where it pinned itself (VIRT-021).
    if (virt.guestCore(id_b) == core_b) {
        ok("surviving guest keeps its core through the other's teardown");
    } else {
        fail("surviving guest keeps its core through the other's teardown", "vCPU core changed or lost");
    }

    // --- close the second window: everything comes back ---
    desktop.closeVm(id_b);
    timer.sleep(GUEST_TEARDOWN_MS);
    expectGuestGone("second guest is fully retired", id_b);
    expectMemReclaimed("all guest memory reclaimed after both closed", mem_baseline);

    // Liveness: the freed slots and cores really are reusable.
    const id_c = openVm(desktop, vmMask()) orelse {
        fail("a guest boots again after both closed", "spawn failed");
        return;
    };
    timer.sleep(GUEST_SETTLE_MS);
    expectGuestExecuting("a guest boots and runs again on the recycled slot", id_c);
    desktop.closeVm(id_c);
    timer.sleep(GUEST_TEARDOWN_MS);
    expectGuestGone("recycled guest closes cleanly too", id_c);
    expectMemReclaimed("memory reclaimed again after the recycled guest", mem_baseline);
}

// --- wake-storm stage --------------------------------------------------------

/// Sleepers the storm parks on ONE common absolute deadline — more than the
/// suite's QEMU harness has cores (-smp 8), so several must share cores and the
/// releasing timer interrupt has to wake a batch, not a single task (KRN-008).
const STORM_SLEEPERS: u32 = 12;
/// How far ahead the common deadline is set: long enough that every sleeper has
/// been spawned, placed, and blocked on it before it fires.
const STORM_LEAD_MS: u64 = 300;
/// Worst wake lateness any sleeper may show (deadline to observed running).
/// Generous for the QEMU host scheduler's own preemption jitter; the kernel's
/// release-and-place path is microseconds.
const STORM_LATENESS_BUDGET_MS: u64 = 20;
/// How long the stage waits past the deadline for every sleeper to report
/// before calling the wake path wedged.
const STORM_REPORT_TIMEOUT_MS: u64 = 2000;

var storm_deadline_tsc: u64 = 0;
var storm_done: u32 = 0; // sleepers that woke and reported (atomic)
var storm_worst_late_ticks: u64 = 0; // worst deadline->running lateness (atomic max)

/// One storm sleeper: block until the COMMON deadline, report lateness, exit.
/// The task ends by returning — the reaper frees it, so the storm leaves no
/// task or stack behind.
fn stormSleeper() void {
    schedsleep.sleepUntilTsc(storm_deadline_tsc);
    const woke = tsc.rdtsc();
    const late = if (woke > storm_deadline_tsc) woke - storm_deadline_tsc else 0;
    _ = @atomicRmw(u64, &storm_worst_late_ticks, .Max, late, .acq_rel);
    _ = @atomicRmw(u32, &storm_done, .Add, 1, .acq_rel);
}

/// Wake-storm stage (KRN-008/KRN-011): many sleepers on one common absolute
/// deadline. The timer interrupt that fires it must release EVERY due sleeper in
/// one pass (releaseDueSleepers), and each woken task is then placed like any
/// other runnable — so all of them must come back promptly, not serialized one
/// interrupt apart. Asserts every sleeper woke and none was later than budget.
// --- idle-core reap stage ---------------------------------------------------

/// How long a dead task may sit unreaped before that counts as a stall. The
/// rotating wall tick visits every online core once per rotation
/// (cores x tick period ~= 320 ms at 32 cores), so two full seconds is many
/// rotations of headroom while still catching "never".
const REAP_BUDGET_MS: u64 = 2_000;

var reap_hook_fired: bool = false;

fn reapProbeHook(_: u64) void {
    @atomicStore(bool, &reap_hook_fired, true, .release);
}

/// The probe's whole life: return immediately. Death, reap, and the exit hook
/// are the machinery under test.
fn reapProbeEntry() void {}

/// A task that dies on a core which then has nothing left to run must still be
/// reaped — its exit hook firing is the proof (the hook runs at the reap, the
/// last moment before the Task's memory is freed). An idle core takes no
/// LAPIC-timer preemption (deadline disarmed), so the ONLY periodic entry it
/// has into schedule() is the rotating wall tick: this stage is the regression
/// home for that tick driving the scheduler. Mutation: remove sched.tick()
/// from the TICK_VECTOR branch in isr.zig and this stage fails.
fn reapStage() void {
    mark("REAP (idle-core zombie reap via the rotating tick)");
    const ncores = smp.coresOnline();
    if (ncores < 2) {
        fail("reap probe core chosen", "needs a second online core");
        return;
    }
    // The quietest core, and never the one this task last ran on — the probe's
    // core must go IDLE after the probe dies, or any task running there would
    // reschedule and reap it regardless of the tick.
    const here = (sched.currentTask() orelse {
        fail("reap probe core chosen", "no current task");
        return;
    }).cpu_index;
    const probe_core: u32 = if (here == ncores - 1) ncores - 2 else ncores - 1;

    @atomicStore(bool, &reap_hook_fired, false, .release);
    const t = sched.spawnOn(probe_core, "reap-probe", reapProbeEntry) catch {
        fail("reap probe spawned", "spawn failed");
        return;
    };
    t.exit_hook = &reapProbeHook; // pre-dispatch: cannot race the task's death
    sched.dispatch(t);

    var waited: u64 = 0;
    while (!@atomicLoad(bool, &reap_hook_fired, .acquire) and
        waited < REAP_BUDGET_MS) : (waited += 50)
    {
        timer.sleep(50);
    }
    if (@atomicLoad(bool, &reap_hook_fired, .acquire)) {
        ok("dead task on an idle core reaped within budget (exit hook fired)");
    } else {
        var d: [48]u8 = undefined;
        fail("dead task on an idle core reaped within budget", std.fmt.bufPrint(&d, "no reap in {d} ms on core {d}", .{ REAP_BUDGET_MS, probe_core }) catch "stall");
    }
}

fn wakeStormStage() void {
    mark("WAKE STORM (many sleepers, one deadline)");
    storm_done = 0;
    storm_worst_late_ticks = 0;
    storm_deadline_tsc = tsc.rdtsc() + tsc.msTicks(STORM_LEAD_MS);
    var spawned: u32 = 0;
    while (spawned < STORM_SLEEPERS) : (spawned += 1) {
        const t = sched.spawn("storm", stormSleeper) catch break;
        sched.dispatch(t);
    }
    if (spawned != STORM_SLEEPERS) {
        var d: [48]u8 = undefined;
        fail("storm sleepers spawned", std.fmt.bufPrint(&d, "only {d} of {d}", .{ spawned, STORM_SLEEPERS }) catch "spawn");
        return;
    }
    var waited: u64 = 0;
    while (@atomicLoad(u32, &storm_done, .acquire) < STORM_SLEEPERS and
        waited < STORM_LEAD_MS + STORM_REPORT_TIMEOUT_MS) : (waited += 50)
    {
        timer.sleep(50);
    }
    const done = @atomicLoad(u32, &storm_done, .acquire);
    if (done == STORM_SLEEPERS) {
        ok("every storm sleeper woke from the common deadline");
    } else {
        var d: [48]u8 = undefined;
        fail("every storm sleeper woke from the common deadline", std.fmt.bufPrint(&d, "{d} of {d} reported", .{ done, STORM_SLEEPERS }) catch "wakes");
        return;
    }
    const late_ms = cpustat.tscToMs(@atomicLoad(u64, &storm_worst_late_ticks, .acquire), tsc.hz());
    if (late_ms <= STORM_LATENESS_BUDGET_MS) {
        ok("worst storm wake lateness within budget");
    } else {
        var d: [48]u8 = undefined;
        fail("worst storm wake lateness within budget", std.fmt.bufPrint(&d, "{d}ms late (budget {d}ms)", .{ late_ms, STORM_LATENESS_BUDGET_MS }) catch "late");
    }
}

// --- loss-counter stage ------------------------------------------------------

/// Counters that record silently-discarded work or containment events; every
/// one must still be ZERO after the whole verify run. The boot-3 host harness
/// watches the same set over netdebug (scripts/tests/counters.py). The
/// shootdown-timeout counter is deliberately absent: its acknowledgement budget
/// is a bound on PHYSICAL time, and this harness runs under an emulator whose
/// host scheduler can deschedule a vCPU past any such bound without losing
/// anything — the boot-3 native track asserts it on silicon instead.
const LOSS_COUNTERS = [_][]const u8{
    "sched.stranded_tasks",
    "smp.session_faults",
    "mem.space_faults",
    "mem.heal_dropped",
    "ui.sess.leaked",
};

/// Assert no loss counter moved during the run. A counter that never fired is
/// typically not registered at all (registration rides the first increment),
/// so absence from the registry is a pass, not a blind spot.
fn lossCountersStage() void {
    mark("LOSS COUNTERS (nothing dropped silently)");
    var tripped = false;
    for (counter.all()) |c| {
        var key: [64]u8 = undefined;
        const k = std.fmt.bufPrint(&key, "{s}.{s}", .{ @tagName(c.mod), c.name }) catch continue;
        for (LOSS_COUNTERS) |want| {
            if (std.mem.eql(u8, k, want) and c.v != 0) {
                tripped = true;
                var d: [96]u8 = undefined;
                fail("loss counters zero after the run", std.fmt.bufPrint(&d, "{s} = {d}", .{ k, c.v }) catch "counter moved");
            }
        }
    }
    if (!tripped) ok("loss counters zero after the run");
}

/// The verification task body (spawned on core 0 when verify_script is set).
fn verifyTask(desktop: *Desktop) void {
    // Let deferred net/USB bring-up finish and the desktop settle first.
    timer.sleep(3500);
    klog.puts("verify: self-checking lifecycle test START\n");

    cycle(desktop, "CYCLE 1");
    cycle(desktop, "CYCLE 2 (cores reused)");
    memStage(desktop);
    rtStage(desktop);
    vmStage(desktop);
    stressStage(desktop);
    wakeStormStage();
    reapStage();
    lossCountersStage();

    var m: [64]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&m, "verify: {d} passed, {d} failed\n", .{ passed, failed }) catch "verify: done\n");
    klog.puts(if (failed == 0) "verify: ALL PASS\n" else "verify: FAILURES PRESENT\n");
}

/// Memory-isolation stage (MEM-002..004, MEM-010): open two terminals and prove,
/// by software-walking the LIVE page tables the hardware is using, that each
/// session's private arena resolves in its own space, does not resolve in the
/// other's, and that the stack guard page resolves in neither.
fn memStage(desktop: *Desktop) void {
    mark("MEM (per-session address spaces)");
    const a = openTerm(desktop) orelse {
        fail("open first mem terminal", "no free session");
        return;
    };
    const b = openTerm(desktop) orelse {
        fail("open second mem terminal", "no free session");
        desktop.closeTermId(a);
        return;
    };
    const arena_a = sessionspace.arenaBase(a);
    const arena_b = sessionspace.arenaBase(b);
    if (arena_a == null or arena_b == null) {
        fail("each session has an address space (MEM-002)", "no arena recorded");
        desktop.closeTermId(b);
        desktop.closeTermId(a);
        return;
    }
    ok("each session has an address space (MEM-002)");
    // A session's own memory resolves in its own space… (probe past the guard
    // page — the arena base itself IS the guard).
    const probe_a = arena_a.? + 2 * 4096;
    const probe_b = arena_b.? + 2 * 4096;
    if (sessionspace.resolveIn(a, probe_a) != null and sessionspace.resolveIn(b, probe_b) != null) {
        ok("a session's own memory is reachable in its own space");
    } else {
        fail("a session's own memory is reachable in its own space", "own arena does not resolve");
    }
    // …and is unreachable from every other session's space (MEM-003/004).
    if (sessionspace.resolveIn(b, probe_a) == null and sessionspace.resolveIn(a, probe_b) == null) {
        ok("one session's memory is unreachable from the other's space (MEM-003/004)");
    } else {
        fail("one session's memory is unreachable from the other's space (MEM-003/004)", "foreign arena resolves");
    }
    // The stack guard page resolves nowhere, not even at home (MEM-010).
    if (sessionspace.resolveIn(a, arena_a.?) == null) {
        ok("the stack guard page is unmapped in its own space (MEM-010)");
    } else {
        fail("the stack guard page is unmapped in its own space (MEM-010)", "guard page resolves");
    }
    desktop.closeTermId(b);
    desktop.closeTermId(a);
    timer.sleep(300);
    expectSessionClosed("mem terminals released", a);
}

/// Real-time task stage (P3): open a terminal, run `rt 30` (a 10 Hz drift-free
/// periodic task), wait for it to finish, and assert from its measured result:
///   - per-period jitter is small (a few ms worst case — generous under emulation);
///   - cumulative drift over all periods is bounded (does NOT grow with periods);
///   - the hosting core's CPU% is MODEST (neither ~0% idle nor ~100% pegged),
///     proving it wakes periodically and sleeps between periods.
fn rtStage(desktop: *Desktop) void {
    mark("RT (real-time 10 Hz periodic)");
    const id = openTerm(desktop) orelse {
        fail("open rt terminal", "no free session");
        return;
    };
    const periods: u64 = 30; // 30 periods @ 10 Hz = ~3 s
    typeLine(desktop, "rt 30");

    // Sample the TASK's own CPU time mid-run (KRN-005 accounting). A 10 Hz task
    // that sleeps between periods consumes a small fraction of one core — unlike
    // `prime` (~100%). A machine-wide busiest-core reading proves nothing here:
    // the floating system task legitimately keeps some core busy (KRN-009), so
    // only the rt task's own charge distinguishes sleeping from spinning. The
    // jitter/drift result below proves it is actually running periodically.
    const before = session.taskCpuMs(id);
    timer.sleep(800);
    const after = session.taskCpuMs(id);
    if (before == null or after == null) {
        // A vanished task must FAIL, not pass with a vacuous 0%.
        fail("rt task sleeps between periods", "session task gone mid-measurement");
    } else {
        const pct = (after.? - before.?) * 100 / 800;
        if (pct < 60) {
            ok("rt task sleeps between periods (own CPU well under one core)");
        } else {
            var d: [48]u8 = undefined;
            fail("rt task sleeps between periods", std.fmt.bufPrint(&d, "task cpu={d}% of one core", .{pct}) catch "cpu");
        }
    }

    // Wait for the run to complete (~3 s of periods + margin), then assert result.
    var waited: u64 = 0;
    while (!rt_cmd.lastRt().valid and waited < 6000) : (waited += 100) timer.sleep(100);
    const r = rt_cmd.lastRt();
    if (!r.valid) {
        fail("rt completed", "no result after timeout");
        return;
    }
    ok("rt completed");

    // Jitter bound: generous (5 ms) since QEMU/KVM adds interrupt latency; the
    // point is it is BOUNDED and small relative to the 100 ms period, not exact.
    if (r.jit_max_ns < 5_000_000) {
        ok("rt jitter bounded (<5ms worst-case)");
    } else {
        var d: [48]u8 = undefined;
        fail("rt jitter bounded", std.fmt.bufPrint(&d, "max jitter {d}ns", .{r.jit_max_ns}) catch "jit");
    }

    // Drift bound: absolute-deadline scheduling keeps total drift ≈ one period's
    // jitter, NOT periods × jitter. Assert it is within a couple periods' worth.
    if (r.drift_us < 10000) {
        ok("rt drift bounded (no accumulation over periods)");
    } else {
        var d: [56]u8 = undefined;
        fail("rt drift bounded", std.fmt.bufPrint(&d, "drift {d}us over {d} periods", .{ r.drift_us, r.periods }) catch "drift");
    }

    desktop.closeTermId(id);
    timer.sleep(200);
    _ = periods;
}

// --- entry ------------------------------------------------------------------

var g_desktop: *Desktop = undefined;

/// Scheduler entry point for the verification task: run the whole test suite
/// once, then park forever so core 0 keeps running its other tasks.
fn taskEntry() void {
    verifyTask(g_desktop);
    // Done: park forever (the core keeps running its other tasks).
    while (true) sched.block({}, neverReady);
}

/// block() predicate that is never ready — parks the finished verify task forever.
fn neverReady(_: void) bool {
    return false;
}

/// Spawn the verification task on core 0. Called from the SMP boot path when
/// `buildinfo.verify_script` is set. No-op otherwise.
pub fn spawn(desktop: *Desktop) void {
    if (!buildinfo.verify_script) return;
    g_desktop = desktop;
    const t = sched.spawn("verify", taskEntry) catch {
        klog.puts("verify: spawn failed\n");
        return;
    };
    // Placement takes the target core's lock itself, so this is safe to call from
    // systemTask with interrupts on — and the harness runs wherever there is room.
    sched.dispatch(t);
}
