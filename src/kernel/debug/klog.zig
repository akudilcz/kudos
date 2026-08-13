//! klog — the kernel's trace bus. Every `dbg.*`, panic line and CPU-fault dump
//! reaches the outside world through here.
//!
//! THERE IS NO SERIAL PORT. The trace channel is the NETWORK (netdebug, UDP
//! broadcast :9514) plus the in-memory diag ring netdebug replays as its backlog.
//! There is deliberately no UART sink, and there will not be one. A serial port is the
//! only sink that can BLOCK — a busy-wait at 38400 baud costs ~0.3 ms per byte, enough
//! to hold the GPU session loop down to ~30 FPS on its own. A trace channel that slows
//! the thing it is watching reports on a machine that no longer exists.
//!
//! klog is a pure fan-out to registered sinks. It knows nothing about how any of them
//! get the bytes out, which is what keeps "the log" and "the transport" separate
//! questions — you can debug one without first understanding the other.

const ilog = @import("ilog");
const SpinLock = @import("../sync/spinlock.zig").SpinLock;

/// Kernel build (any variant) vs host test: the bus lock exists only on the
/// kernel — host tests are single-threaded and must not pull in the CPU
/// intrinsics the lock needs. (buildinfo is not wired into every host module,
/// so the target triple is the discriminator here.)
const is_kernel = @import("builtin").os.tag == .freestanding;

// The bus is reached from every core and from IRQ context (the deadman, the
// unexpected-vector arm, wake's ring-full report). One IRQ-save lock makes each
// putc/puts/putsRecord atomic: without it two cores interleave the diag-ring
// indices and double-drive the sinks, garbling the trace exactly when it is
// needed most. Comptime-gated to kernel builds (see is_kernel); safe to
// hold across the sinks because every sink is a pure RAM memcpy (their own
// contract — see bootlog.feed / netdebug.feed).
var bus_lock: SpinLock = .{};
inline fn lockBus() bool {
    return if (is_kernel) bus_lock.acquireIrqSave() else false;
}
inline fn unlockBus(if_was: bool) void {
    if (is_kernel) bus_lock.releaseIrqRestore(if_was);
}

// In-memory ring of everything put on the trace bus, and the single source of
// truth for the bring-up log: netdebug replays it as its backlog once the LAN
// path is proven, and the KMR1 ring-tail dump serves its recent tail on demand
// — neither keeps a copy of its own. When full, the oldest bytes
// are overwritten (the recent tail is what matters during bring-up).
// Sized so one FULL boot survives until the netdebug replay fires: anything
// smaller evicts the early facts (USB enumeration) behind the GPU bring-up trace
// and replays only the tail. 1 MiB of static BSS is nothing to the kernel and
// holds the whole boot (GPU bring-up + USB enumeration + soak) with headroom.
const DIAG_CAP = 1024 * 1024;
var diag_buf: [DIAG_CAP]u8 = undefined;
var diag_start: usize = 0; // index of the oldest captured byte
var diag_count: usize = 0; // number of valid bytes, capped at DIAG_CAP

/// Append one byte to the diag ring, overwriting the oldest byte when full so the
/// most recent DIAG_CAP bytes of the bring-up log are always retained.
fn diagPush(c: u8) void {
    const end = (diag_start + diag_count) % DIAG_CAP;
    diag_buf[end] = c;
    if (diag_count == DIAG_CAP) {
        diag_start = (diag_start + 1) % DIAG_CAP; // overwrite oldest
    } else {
        diag_count += 1;
    }
}

/// Slice variant: wrap-aware memcpy (at most two spans), not a per-byte loop —
/// rings accept arrays kudos-wide; single chars are slow. A slice longer than
/// the ring keeps only its newest DIAG_CAP bytes (same overwrite-oldest rule).
fn diagPushSlice(s: []const u8) void {
    var src = s;
    if (src.len >= DIAG_CAP) {
        src = src[src.len - DIAG_CAP ..];
        diag_start = 0;
        diag_count = DIAG_CAP;
        @memcpy(diag_buf[0..DIAG_CAP], src);
        return;
    }
    const end = (diag_start + diag_count) % DIAG_CAP;
    const first = @min(src.len, DIAG_CAP - end);
    @memcpy(diag_buf[end..][0..first], src[0..first]);
    @memcpy(diag_buf[0 .. src.len - first], src[first..]);
    const overflow = (diag_count + src.len) -| DIAG_CAP;
    diag_start = (diag_start + overflow) % DIAG_CAP;
    diag_count = @min(diag_count + src.len, DIAG_CAP);
}

/// The diag ring's backing storage. Read with `diagStart`/`diagCount`: the
/// chronological byte `i` (0 = oldest) is `diagBuf()[(diagStart() + i) % len]`.
pub fn diagBuf() []const u8 {
    return &diag_buf;
}
/// Ring index of the oldest captured byte (the `i = 0` origin for `diagBuf`).
pub fn diagStart() usize {
    return diag_start;
}
/// Number of valid bytes currently in the diag ring (≤ DIAG_CAP).
pub fn diagCount() usize {
    return diag_count;
}

// ── byte-sink fan-out ─────────────────────────────────────────────────────
// klog is the kernel's ONE trace chokepoint: every `debug.*`, `log(...)`,
// panic line, and CPU-fault dump reaches the outside world through `putc`. A
// consumer that wants a copy of that byte stream — the netdebug UDP mirror, the
// USB /usbdisk/bootlog.txt recorder, any future sink — registers ONE function
// pointer here with `addSink`, and `putc` fans out to all of them in a single
// loop. This is the single place a log destination is added: no per-sink field,
// no per-sink `if` in `putc`. Function pointers (not module imports) keep klog
// the lowest layer — it never imports the network or storage stacks; each sink
// installs itself from its own bring-up (netdebug.start, bootlog.init).
//
// Fixed array (no allocator at this layer, and the count is tiny + known):
// netdebug + bootlog today, with headroom. Registration is boot-time and
// single-threaded; a full table is a loud panic, never a silent drop.
const MAX_SINKS = 4;
var sinks: [MAX_SINKS]*const fn ([]const u8) void = undefined;
var nsinks: usize = 0;

/// Register a SLICE sink: `fn(bytes) void` is handed spans of the trace stream
/// ('\r'-free), in registration order — a whole `puts` string arrives as ONE
/// call, so sinks memcpy arrays instead of paying an indirect call per byte
/// (single chars are slow; this is the kudos-wide ring/sink convention). The
/// ONE way to add a log destination. Call once, from the sink's own bring-up.
pub fn addSink(sink: *const fn ([]const u8) void) void {
    if (nsinks == MAX_SINKS) @panic("klog.addSink: sink table full (raise MAX_SINKS)");
    sinks[nsinks] = sink;
    nsinks += 1;
}

/// Push every queued byte out of whichever sink can still carry it, RIGHT NOW,
/// bypassing that sink's normal pacing. The one caller that matters is the CPU
/// fault handler: the machine is about to reset, so the metered drain that
/// would normally ship the crash record will never run again, and this is the
/// record's only chance to leave the box.
///
/// A HOOK, not an import, and that is the whole point. The fault handler is K1
/// — the bottom of the machine — and the transport that carries the record out
/// is a network driver sitting two layers above it. A K1 file naming a K2
/// driver is the dependency arrow pointing backwards; the transport installs
/// itself here at bring-up instead, exactly as the boot-log sink does above.
/// Null on a machine with no such transport, which is simply a machine whose
/// crash record stays in RAM.
var crash_flush: ?*const fn () void = null;

/// Install the crash-path flush (the transport, at its own bring-up).
pub fn setCrashFlush(f: *const fn () void) void {
    crash_flush = f;
}

/// Run the crash-path flush if a transport installed one. Best-effort by
/// contract: the caller is on its way to a reset either way.
pub fn flushCrash() void {
    if (crash_flush) |f| f();
}

/// Emit one byte onto the trace bus: into the in-memory diag ring, then to every
/// registered sink (netdebug, the boot-log recorder).
/// There is no UART — this is the whole output path.
pub fn putc(c: u8) void {
    if (c == '\r') return; // serial line-ending artifact; sinks here take bare LF
    const if_was = lockBus();
    defer unlockBus(if_was);
    diagPush(c);
    for (sinks[0..nsinks]) |sink| sink(&.{c});
}

/// Write a string: the diag ring and every sink get the WHOLE slice in one
/// call each (arrays, not chars — per-byte sink calls are slow).
pub fn puts(s: []const u8) void {
    if (s.len == 0) return;
    const if_was = lockBus();
    defer unlockBus(if_was);
    diagPushSlice(s);
    for (sinks[0..nsinks]) |sink| sink(s);
}

/// Write a string into the diag ring ONLY — no sinks, nothing on the wire. The
/// flight-recorder leg: `debug.set*` records every dbg line here regardless of
/// the module gate, so history is recoverable on demand (the KMR1 ring-tail
/// dump) even for subsystems nobody enabled; the gate decides only what streams
/// live. Free-text logging keeps using `puts`.
pub fn putsRecord(s: []const u8) void {
    if (s.len == 0) return;
    const if_was = lockBus();
    defer unlockBus(if_was);
    diagPushSlice(s);
}

/// No-op: klog has no device to initialise. Kept so boot order reads the same.

// ── iface/ilog.zig sink ──────────────────────────────────────────────────────
// Leaf UI modules (e.g. src/ui/wm/window.zig) log through iface/ilog.zig, not this
// driver directly, so they stay host-compilable. The kernel entry root installs
// this real sink early in boot; until then their log calls are silent.
fn logPuts(_: *anyopaque, s: []const u8) void {
    puts(s);
}
fn logPutHex(_: *anyopaque, v: u64) void {
    putHex(v);
}
var log_ctx: u8 = 0;
/// Install klog as the process-wide iface/log sink.
pub fn installLogSink() void {
    ilog.sink = .{ .puts = logPuts, .putHex = logPutHex, .ctx = @ptrCast(&log_ctx) };
}

/// Minimal hex print for pointers/values during bring-up. Assembled first,
/// then ONE `puts`: each bus call is atomic, so the value can never be torn
/// mid-digits by a concurrent emitter.
pub fn putHex(value: u64) void {
    const digits = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: u6 = 60;
    var n: usize = 2;
    while (true) : (i -= 4) {
        const nibble: usize = @intCast((value >> i) & 0xf);
        buf[n] = digits[nibble];
        n += 1;
        if (i == 0) break;
    }
    puts(buf[0..n]);
}
