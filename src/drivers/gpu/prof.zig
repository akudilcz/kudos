//! Section profiler for the GPU session loop — attributes wall-clock time to named
//! phases so a frame-pacing stall (session profiling) can be
//! blamed on a specific function instead of the opaque `gap` bucket in the FLIP
//! record. Each `section()` call closes the previous span and opens a new one, timed
//! by rdtsc; per-section min/avg/max accumulate and dump to netdebug once per second.
//!
//! Gated by `ENABLED` (comptime) like present.zig's FLIP_TIMING: when off, every call
//! is an empty inline fn the optimiser deletes, so it is free in a production image.
//! Enable it for a watched pacing run, read the `PROF` records over netdebug, disable.
//!
//! Usage in the session loop (gpu.zig) / pump (main_root.zig via a hook):
//!   prof.frameBegin();
//!   prof.section(.xhci);   xhci.poll();
//!   prof.section(.input);  drainInput();
//!   prof.section(.tick);   _ = d.tick();
//!   prof.section(.render); d.render();
//!   prof.section(.netdebug); netdebug.drain();
//!   prof.frameEnd();       // closes the last span, bumps frame count, maybe dumps

const tsc = @import("../../kernel/cpu/tsc.zig");
const log = @import("rm/log.zig").gpu;

/// Master switch. OFF in a shipped image (zero cost). Flip on for a watched pacing
/// run, exactly like present.zig FLIP_TIMING — the two are independent so you can run
/// either or both.
pub const ENABLED = false;

/// The session-loop phases we attribute time to. Keep this list SHORT and aligned
/// with the actual call sites — one enum tag per span. Adding a phase = add a tag
/// here and a `section(.tag)` call at its boundary.
pub const Section = enum {
    xhci, // xhci.poll: USB HID host controller drain
    input, // keyboard/mouse ring drain + onMouse/onKey apply (cursor plane move)
    tick, // desktop.tick: time-driven state (blink, clock, bouncing square)
    cmd, // runPendingCommands: typed in-session commands
    render, // desktop.render: rasterize dirty windows + compositor composite + CE flip
    netdebug, // netdebug.drain: ship the queued debug FIFO onto the wire
    yield, // scheduler yield / inter-iteration spin
    other, // anything not inside an explicit span (loop bookkeeping)

    const COUNT = @typeInfo(Section).@"enum".fields.len;
};

/// Per-section span accumulator — pure math, host-tested below (the ENABLED gate
/// makes the instrumented paths untestable, so the arithmetic is testable on its
/// own; `close`/`addSpan` are thin tsc-anchored wrappers over `add`).
pub const Acc = struct {
    sum: u64 = 0, // total ticks this window
    max: u64 = 0, // worst single span this window
    n: u64 = 0, // span count this window

    /// Fold one span of `dt` ticks into the window.
    pub fn add(self: *Acc, dt: u64) void {
        self.sum += dt;
        self.n += 1;
        if (dt > self.max) self.max = dt;
    }

    /// Mean span this window; 0 when no span landed (n==0 → no divide).
    pub fn avg(self: Acc) u64 {
        return if (self.n != 0) self.sum / self.n else 0;
    }
};

/// Elapsed ticks between a span's open and `now` — wrapping (-%) so an rdtsc
/// wraparound cannot trap the profiler.
pub fn spanTicks(start: u64, now: u64) u64 {
    return now -% start;
}

var accs: [Section.COUNT]Acc = undefined;
var cur: Section = .other; // section currently being timed
var span_start: u64 = 0; // rdtsc at the current span's open
var frames: u32 = 0; // frames since the last dump
var last_dump_tsc: u64 = 0; // rdtsc at the last dump (1 s cadence)
var inited: bool = false;

/// Dump cadence: one `PROF` block per this many rendered frames. At ~60 fps that is
/// ~once/second; bounded by frame count (not wall-clock) so an idle desktop that
/// stops flipping does not spam an all-zero block.
const DUMP_EVERY_FRAMES: u32 = 60;

/// Close the running span, adding its elapsed ticks to `cur`'s accumulator, and
/// (re)anchor at `now`. Internal — `section`/`frameBegin`/`frameEnd` call it.
inline fn close(now: u64) void {
    accs[@intFromEnum(cur)].add(spanTicks(span_start, now));
    span_start = now;
}

/// Charge `ticks` directly to `s`, OUT of band from the chained frame spans. For work
/// that happens in the session loop AROUND the pump (netdebug.drain, trace drain) — it
/// must not disturb `span_start`/`cur`, so it cannot use `section`. Caller times it
/// with its own rdtsc pair. No-op when disabled.
pub inline fn addSpan(s: Section, ticks: u64) void {
    if (!ENABLED) return;
    ensureInit();
    accs[@intFromEnum(s)].add(ticks);
}

/// Begin a frame's timing. Resets the "other" span anchor. Call at the very top of
/// the loop iteration, before the first `section`.
inline fn ensureInit() void {
    if (inited) return;
    for (&accs) |*a| a.* = .{};
    last_dump_tsc = tsc.rdtsc();
    inited = true;
}

pub inline fn frameBegin() void {
    if (!ENABLED) return;
    ensureInit();
    span_start = tsc.rdtsc();
    cur = .other;
}

/// Close the current span and open `s`. The time between this call and the NEXT
/// `section`/`frameEnd` is charged to `s`.
pub inline fn section(s: Section) void {
    if (!ENABLED) return;
    close(tsc.rdtsc());
    cur = s;
}

/// Close the last span and end the frame. Once per DUMP_EVERY_FRAMES, emit the
/// per-section avg/max (µs) to netdebug and reset the window.
pub inline fn frameEnd() void {
    if (!ENABLED) return;
    close(tsc.rdtsc());
    frames += 1;
    if (frames < DUMP_EVERY_FRAMES) return;
    dump();
}

fn dump() void {
    if (tsc.hz() == 0) return; // pre-calibration: no honest µs to report yet
    const now = tsc.rdtsc();
    const window_us = tsc.ticksToUs(now -% last_dump_tsc);
    // One compact line: total window + per-section avg/max in µs. Kept well under the
    // netdebug datagram cap. Sections with n==0 print 0/0.
    inline for (@typeInfo(Section).@"enum".fields, 0..) |field, idx| {
        const a = accs[idx];
        const avg = tsc.ticksToUs(a.avg());
        const mx = tsc.ticksToUs(a.max);
        log("PROF {s} avg={} max={} n={}\n", .{ field.name, avg, mx, a.n });
    }
    log("PROF _window_us={} frames={}\n", .{ window_us, frames });
    for (&accs) |*a| a.* = .{};
    frames = 0;
    last_dump_tsc = now;
}
