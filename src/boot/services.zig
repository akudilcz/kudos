//! THE SERVICE TABLE: every background service the machine steps every
//! iteration, in one ordered list, iterated by both steady loops.
//!
//! Why it exists. kudos has two steady loops — `pump.systemLoop` (no GPU) and
//! the GPU session loop, which on a native boot never returns and IS the
//! machine. Each used to carry its own hand-written list of services to step,
//! and the two had already diverged: the GPU loop never drained guest boot
//! requests, so `vm boot` typed on real hardware queued forever. A list
//! maintained in two places is a list that disagrees; this is the one place,
//! and both loops iterate it.
//!
//! The apex owns it. `boot/` is the group that legitimately knows every other
//! group, so the table can name services directly and each row stays a direct,
//! comptime-resolved call — no vtable, no registry, no runtime indirection for
//! a set that is fixed at build time. The GPU loop reaches it through the
//! compositor seam (`iaccel.Compositor.service`), which boot installs, because
//! `drivers/` must never import the apex.
//!
//! ORDER IS THE CONTRACT: services step in listed order, and `flushAll` runs
//! the reverse — the pre-power-off drain, so the trace channel that reports
//! what everyone else did is the last thing to go.
//!
//! Naming. `step` is the service contract: advance one BOUNDED slice, own your
//! own throttle, never block. Where a module's steady-loop entry has other
//! legitimate callers under an older name (`netdebug.drain` at every GPU
//! bring-up stage boundary, `net.pump` inside the blocking network waits) the
//! row names that function directly rather than forcing a synonym on forty
//! call sites; where the entry is loop-only it is spelled `step`.

const idevices = @import("idevices");
const klog = @import("../kernel/debug/klog.zig");
const net = @import("../drivers/net/stack/net.zig");
const netdebug = @import("../drivers/net/debug/netdebug.zig");
const fileserv = @import("../drivers/net/debug/fileserv.zig");
const bootlog = @import("../drivers/storage/bootlog.zig");
const jobs = @import("../kernel/sched/jobs.zig");
const capabilities = @import("../console/capabilities.zig");
const virt = @import("../kernel/virt/virt.zig");
const virtboot = @import("virtboot.zig");

/// When a service runs relative to the frame. `.service` is the ordinary
/// pre-render pass; `.slice` is bounded work that must run AFTER this pass's
/// input, tick and render, so it can never push a present past its deadline
/// (PERF-003) — a single-core guest's vCPU slice runs in what is left over.
pub const Phase = enum { service, slice };

/// One service: what to call, when, and how it reports itself. `flush` and
/// `status` are optional because most services have neither a buffered tail to
/// empty before power-off nor a state worth naming.
const Service = struct {
    name: []const u8,
    phase: Phase,
    step: *const fn () void,
    flush: ?*const fn () void = null,
    status: ?*const fn () idevices.Status = null,
};

/// THE LIST. Adding a service is one row here and nowhere else.
const SERVICES = [_]Service{
    // The trace channel first: whatever the services below report this
    // iteration ships on the next pass, and it is the last to be flushed.
    .{ .name = "netdebug", .phase = .service, .step = netdebug.drain, .flush = netdebug.flushNow },
    // The network under it — RX demux feeds fileserv and the jobs below.
    .{ .name = "net", .phase = .service, .step = net.pump, .status = net.status },
    .{ .name = "jobs", .phase = .service, .step = jobs.step },
    .{ .name = "kmr1", .phase = .service, .step = fileserv.step },
    .{ .name = "bootlog", .phase = .service, .step = bootlog.step, .flush = bootlog.flushNow, .status = bootlog.status },
    // What a loaded module parked for the system core (an HTTP fetch so far).
    .{ .name = "modcaps", .phase = .service, .step = capabilities.step },
    // Guest boot requests: `vm boot` posts one, and the window it opens is the
    // system task's to create. The row the GPU loop was missing.
    .{ .name = "virtboot", .phase = .service, .step = virtboot.step },
    // Guest vCPU slices last, after the render (see Phase.slice).
    .{ .name = "virtguests", .phase = .slice, .step = virt.pumpAll },
};

// Every row conforms by SHAPE, checked at compile time: a row whose module
// changes signature fails to build instead of failing at 3 a.m. on hardware.
comptime {
    for (SERVICES) |s| {
        if (s.name.len == 0) @compileError("services: a row must name itself");
        if (@TypeOf(s.step) != *const fn () void)
            @compileError("services: " ++ s.name ++ ".step must be fn () void");
    }
}

/// Step every service in `phase`, in listed order. Both steady loops call this
/// — `systemLoop` directly, the GPU session loop through the compositor seam.
pub fn stepAll(comptime phase: Phase) void {
    inline for (SERVICES) |s| {
        if (s.phase == phase) s.step();
    }
}

/// `iaccel.Compositor.service`: the same table, reached by the GPU session
/// loop through the seam (a driver may not import the apex). The bool selects
/// the phase because the contract holds no kudos types.
pub fn serviceHook(after_render: bool) void {
    if (after_render) stepAll(.slice) else stepAll(.service);
}

/// Empty every buffered service before the machine goes (STO-007), in REVERSE
/// listed order so the trace channel — which carries the record of everyone
/// else's last words — ships last. Behind `power.flush_hook`.
///
/// File-system writes are not here and need no hook: every FAT mutation ends
/// in its own durability epilogue (fat.syncMeta), so a volume is already
/// mountable at the instant each operation returns, power cut or not.
pub fn flushAll() void {
    comptime var i = SERVICES.len;
    inline while (i > 0) {
        i -= 1;
        if (SERVICES[i].flush) |f| f();
    }
}

/// Trace one line per service that is NOT ready — the post-mortem question
/// "what state was the machine in when it went down", answered from the one
/// place that knows every service. Called on the way out (flushAll's caller)
/// and cheap enough to be unconditional: a healthy machine prints nothing.
pub fn traceStatus() void {
    inline for (SERVICES) |s| {
        if (s.status) |f| {
            const st = f();
            if (st != .ready) {
                klog.puts("service ");
                klog.puts(s.name);
                klog.puts(": ");
                klog.puts(st.text());
                klog.putc('\n');
            }
        }
    }
}
