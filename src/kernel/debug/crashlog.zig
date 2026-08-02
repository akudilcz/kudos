//! Per-core crash records — the fatal path's ONLY output channel.
//!
//! WHY THE FATAL PATH DOES NOT USE THE TRACE BUS: a CPU exception or panic may interrupt the
//! very core that holds klog's trace-bus lock mid-`puts` (a stack overflow
//! faults on whatever call is deepest). A fatal path that
//! wrote its dump through the bus would then spin on its own lock forever with
//! interrupts masked — a triple-faulting machine with ZERO diagnostics. So the
//! fatal paths (isr.zig's exception dump, main_root.zig's panic, smp.containIfAp's
//! containment note) write HERE and never touch the bus: each core owns one
//! fixed record, appended with plain stores and published with one atomic —
//! there is no lock to contend on and no shared state with the bus.
//!
//! SHIPPING: a sealed record is passive state ANY live core can drain —
//! netdebug ships it straight onto the wire (bypassing the line FIFO and the
//! bus, so the crash channel shares no failure domain with the trace path),
//! from the metered drain on a surviving core and from flushNow on the
//! terminal reboot path. A crash record therefore never depends on its own —
//! possibly parked — core, on the system task's placement (KRN-011), or on
//! the trace bus being healthy.
//!
//! CONCURRENCY: one writer per record — the owning core, with interrupts
//! masked on every fatal path — and readers claim a sealed record with a
//! single compare-and-swap. A new fault on a core whose previous record was
//! not yet shipped supersedes it (the newest crash explains the machine's
//! current state); the loss is counted, never silent.

const std = @import("std");
const counter = @import("counter.zig");
const backtrace = @import("backtrace.zig");

// Per-core record slots, sized to the topology cap (acpi.MAX_CPUS is the
// owner) so a high core index is never silently ignored.
const MAX_CORES = @import("../acpi/acpi.zig").MAX_CPUS;

/// Bytes one record can hold: a full exception header, the MAX_FRAMES-line
/// backtrace and the containment notes fit in a fraction of this. A longer
/// dump truncates, counted.
pub const RECORD_CAP = 4096;

/// Bytes a record could not hold (`crash.truncated`) and records superseded
/// before they shipped (`crash.overwritten`). Registered by init() — a fatal
/// path must never touch the counter registry, only bump values.
var cnt_truncated = counter.Counter{ .mod = .smp, .name = "crash.truncated" };
var cnt_overwritten = counter.Counter{ .mod = .smp, .name = "crash.overwritten" };

const State = enum(u32) {
    idle,
    /// The owning core is appending its dump.
    writing,
    /// Complete and visible to readers (takeSealed).
    sealed,
    /// A reader is putting it on the wire.
    shipping,
};

const Record = struct {
    state: State = .idle,
    len: usize = 0,
    buf: [RECORD_CAP]u8 = undefined,
};

var records: [MAX_CORES]Record = .{Record{}} ** MAX_CORES;

/// Register this module's counters. Called once at boot (single-threaded);
/// the fatal paths that bump them never touch the registry.
pub fn init() void {
    counter.register(&cnt_truncated);
    counter.register(&cnt_overwritten);
}

/// Open `core`'s record for a (new) dump if it is not already being written.
/// A record still sealed or shipping is superseded — newest crash wins,
/// counted; a concurrent reader may emit a garbled tail, on a machine that is
/// already dying.
fn openForWrite(r: *Record) void {
    const st = @atomicLoad(State, &r.state, .acquire);
    if (st == .writing) return;
    if (st != .idle) cnt_overwritten.inc();
    r.len = 0;
    @atomicStore(State, &r.state, .writing, .release);
}

/// Append `s` to `core`'s record, opening it if needed (the record is open
/// from its first byte; only `seal` closes it). Truncates at RECORD_CAP,
/// counted. Plain stores — no lock, callable from any context.
pub fn puts(core: usize, s: []const u8) void {
    if (core >= records.len) return;
    const r = &records[core];
    openForWrite(r);
    const n = @min(RECORD_CAP - r.len, s.len);
    @memcpy(r.buf[r.len..][0..n], s[0..n]);
    r.len += n;
    if (n < s.len) cnt_truncated.add(s.len - n);
}

/// Append a 16-digit `0x…` hex value — the klog.putHex format, so crash lines
/// grep and symbolize exactly like trace lines.
pub fn putHex(core: usize, v: u64) void {
    var b: [18]u8 = undefined;
    puts(core, std.fmt.bufPrint(&b, "0x{x:0>16}", .{v}) catch return);
}

/// Append the numbered RBP backtrace to `core`'s record — the crash-record
/// twin of backtrace.emitKlog (one walker, two sinks). Returns the frame count.
pub fn emitBacktrace(core: usize, seed_rbp: usize, cur_rsp: usize) usize {
    const Ctx = struct { core: usize, idx: usize };
    const Emit = struct {
        fn line(c: *Ctx, addr: usize) void {
            puts(c.core, "*** BT #");
            putHex(c.core, c.idx);
            puts(c.core, " ");
            putHex(c.core, addr);
            puts(c.core, "\n");
            c.idx += 1;
        }
    };
    var c = Ctx{ .core = core, .idx = 0 };
    return backtrace.walkFrom(seed_rbp, cur_rsp, &c, Emit.line);
}

/// Publish `core`'s record: from here any reader may claim and ship it. The
/// length is written before the release store, so a claiming reader sees the
/// whole record. No-op unless the record is open.
pub fn seal(core: usize) void {
    if (core >= records.len) return;
    const r = &records[core];
    if (@atomicLoad(State, &r.state, .acquire) != .writing) return;
    @atomicStore(State, &r.state, .sealed, .release);
}

/// Whether any sealed record awaits shipping — the drain's cheap gate before
/// it walks takeSealed (a scan of the state words, no claim, no copy).
pub fn pending() bool {
    for (&records) |*r| {
        if (@atomicLoad(State, &r.state, .monotonic) == .sealed) return true;
    }
    return false;
}

/// A sealed record claimed for shipping: the core it belongs to (pass back to
/// `release` when shipped) and its bytes.
pub const Sealed = struct { core: usize, bytes: []const u8 };

/// Claim one sealed record (compare-and-swap, so exactly one reader ships
/// it), or null when none is pending. The claim survives until `release`.
pub fn takeSealed() ?Sealed {
    for (&records, 0..) |*r, i| {
        if (@cmpxchgStrong(State, &r.state, .sealed, .shipping, .acq_rel, .monotonic) == null)
            return .{ .core = i, .bytes = r.buf[0..r.len] };
    }
    return null;
}

/// Return a shipped record's slot to the pool. If the owning core faulted
/// again mid-ship, the record is already reopened — leave it to its owner.
pub fn release(core: usize) void {
    if (core >= records.len) return;
    _ = @cmpxchgStrong(State, &records[core].state, .shipping, .idle, .acq_rel, .monotonic);
}
