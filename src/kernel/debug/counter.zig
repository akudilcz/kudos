//! Named event counters — permanent, near-free instrumentation.
//!
//! The problem this solves: without it, every "how many times did X happen" question
//! means a hand-rolled `var dbg_x: u64` in the owning driver plus a bufPrint into
//! some heartbeat line — a rebuild per hypothesis, and a pattern that drifts.
//! Here a subsystem declares a named counter once, bumps it for free on the hot
//! path, and the trace bus does all the formatting and shipping:
//!
//!     var hid_queued = counter.Counter{ .mod = .usb, .name = "hid.queued" };
//!     // in the subsystem's init:
//!     counter.register(&hid_queued);
//!     // on the hot path (IRQ-safe — one add, no gate check, no formatting):
//!     hid_queued.inc();
//!
//! Emission is pull-based: `emitChanged()` rides the trace heartbeat and emits one
//! `dbg: <mod>.<name> = <value>` line per counter that moved since the last flush;
//! `emitAll(force_wire)` dumps everything on demand (the KMR1 OP_STATS op and the
//! shell `stats` command), bypassing the module gate when forced — an explicitly
//! requested dump must never come back empty because a gate was off.
//!
//! RAIL (CLAUDE.md): a code path that silently discards work — an event, a packet,
//! a report — MUST bump a counter, and hot paths (per-frame/per-IRQ/per-report)
//! bump counters instead of calling `dbg.set`.

const std = @import("std");
pub const gate = @import("gate.zig");
const debug = @import("debug.zig");
pub const klog = @import("klog.zig");

pub const Counter = struct {
    /// The owning subsystem — the emitted key is `<mod>.<name>` and the line is
    /// wire-gated on this module like any other dbg record.
    mod: gate.Mod,
    /// Short dotted suffix ("hid.queued"); the mod tag is prefixed at emission.
    name: []const u8,
    v: u64 = 0,
    /// Value at the last emission — `emitChanged` emits only movers.
    last_emitted: u64 = 0,

    pub fn add(self: *Counter, n: u64) void {
        self.v +%= n;
    }
    pub fn inc(self: *Counter) void {
        self.add(1);
    }
    /// Raise the value to `n` if larger — a high-water-mark gauge (worst
    /// latency, deepest queue) that rides the same registry and emission as an
    /// accumulating counter. As cheap as `add`: one compare, hot-path safe.
    pub fn peak(self: *Counter, n: u64) void {
        if (n > self.v) self.v = n;
    }
};

/// Fixed-capacity registry (no allocator at this layer; the count is small and
/// known). A full table is a loud panic, never a silently unregistered counter —
/// same contract as klog.addSink.
const MAX_COUNTERS = 128;
var table: [MAX_COUNTERS]*Counter = undefined;
var ntable: usize = 0;

/// Register a counter for emission. Idempotent — re-running a subsystem's init
/// (a retried bring-up) must not duplicate its counters' lines.
pub fn register(c: *Counter) void {
    for (table[0..ntable]) |e| {
        if (e == c) return;
    }
    if (ntable == MAX_COUNTERS) @panic("counter.register: table full (raise MAX_COUNTERS)");
    table[ntable] = c;
    ntable += 1;
}

/// Registered counters, oldest first — the shell `stats` command walks this.
pub fn all() []const *Counter {
    return table[0..ntable];
}

/// Emit every counter that changed since its last emission. Called on the trace
/// heartbeat cadence; an idle counter costs one compare, nothing on the wire.
pub fn emitChanged() void {
    for (table[0..ntable]) |c| {
        if (c.v == c.last_emitted) continue;
        c.last_emitted = c.v;
        emitOne(c, false);
    }
}

/// Emit every registered counter now. `force_wire` bypasses the module gate —
/// an on-demand dump (OP_STATS) was explicitly asked for, so it must reach the
/// wire even for modules nobody enabled.
pub fn emitAll(force_wire: bool) void {
    for (table[0..ntable]) |c| {
        c.last_emitted = c.v;
        emitOne(c, force_wire);
    }
}

fn emitOne(c: *Counter, force_wire: bool) void {
    var key: [debug.KEY_CAP]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "{s}.{s}", .{ @tagName(c.mod), c.name }) catch return;
    if (force_wire and !gate.on(c.mod)) {
        // Forced dump of a gated-off module: bypass debug.set's wire gate by
        // emitting the record directly onto the bus (ring + every sink). One
        // assembled line, one klog call — each bus call is atomic, so the
        // record cannot be torn by a concurrent emitter.
        var line: [debug.LINE_CAP]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "dbg: {s} = {d}\n", .{ k, c.v }) catch return;
        klog.puts(text);
        return;
    }
    debug.setNum(c.mod, k, c.v);
}
