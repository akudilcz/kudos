//! Netdebug — the kernel's trace bus (klog) put on the wire as UDP datagrams on
//! :9514. It is the ONLY observation channel kudos has: there is no serial port
//! (klog.zig replaced it), and on a native boot the screen goes dark the moment the
//! GPU is taken over. Readers: the netdebug MCP (scripts/tools/netdebug-mcp/, the
//! one to use), or any `socat -u udp-recv:9514` — the integration harnesses do
//! exactly that.
//!
//! LEASE-FREE BY DEFAULT, UNICAST WHEN IT CAN BE. Frames start as Ethernet broadcast
//! (IPv4 0.0.0.0 → 255.255.255.255, the DHCP DISCOVER shape), so the channel works
//! from the moment the NIC can TX and never depends on DHCP or ARP — a debug channel
//! must not depend on the stack it exists to debug. Once a KMR1 request arrives we
//! know who is listening and switch to unicast to that collector: 802.11 gives a
//! broadcast frame no link-layer ack and no retry, and over wifi that silently ate
//! 8% of the trace (see `collector` below).
//!
//! DESIGN: a line STORE (linestore.zig, pure, host-tested) decouples producing
//! log lines from sending them. `klog.putc` (via the sink) pushes completed
//! lines instantly and never blocks. A drain pump — called from the long-running
//! loops — ships a BOUNDED BATCH per fixed-rate tick (DATAGRAMS_PER_TICK every
//! DRAIN_INTERVAL_MS), so a burst of `dbg.set` calls or the whole-boot replay is
//! metered onto the wire at a steady rate the tiny NIC TX ring (8 descriptors)
//! and a receiver's socket buffer can absorb, instead of a back-to-back flood
//! that overruns both and drops packets.
//!
//! RELIABLE, in three layers, each covering the loss mode above it:
//!   - the drain is TWO-PHASE (DIAG-024): lines are packed without being
//!     consumed and advance past only when the NIC accepted the datagram, so a
//!     full TX ring defers lines instead of eating them;
//!   - every line carries a monotonic `[NNNNNN] ` sequence stamp, so a WIRE loss
//!     is visible to the receiver as a gap in the numbers;
//!   - a sent line is RETAINED (DIAG-023), and the receiver fills its gaps by
//!     asking for the missing numbers back over KMR1 (fileproto OP_RESEND) —
//!     the request channel whose retransmit + dedup already make it reliable.
//! What none of that can serve — a line the full store overwrote unsent, or one
//! that expired from retention before it was asked for — is counted and permanent,
//! never silent.

const std = @import("std");
const klog = @import("../../../kernel/debug/klog.zig");
const flood = @import("../../../kernel/debug/flood.zig");
const counter = @import("../../../kernel/debug/counter.zig");
const deadman = @import("../../../kernel/debug/deadman.zig");
const crashlog = @import("../../../kernel/debug/crashlog.zig");
const spinwait = @import("../../../kernel/debug/spinwait.zig");
const net = @import("../stack/net.zig");

/// Where to send the trace, once we know: the source of the first KMR1 request, set by
/// fileserv. Whoever drives us IS the collector, by definition.
///
/// 802.11 gives a broadcast frame no link-layer ack and no retry; a unicast frame gets
/// both, so over wifi broadcast loses several percent of the trace. Broadcast remains the
/// FALLBACK because it needs neither a lease nor a peer — a boot still narrates itself to
/// anyone listening before anyone has spoken to us.
pub var collector: ?[4]u8 = null;

/// Send one datagram of trace: unicast to the collector when we have one (reliable over
/// wifi), else broadcast (reaches a listener we have never heard from). Returns whether
/// the NIC ACCEPTED the datagram — the drain keeps the lines and retries on false
/// (DIAG-024); discarding them here is exactly how six consecutive records once
/// vanished from a capture while every check stayed green.
fn emit(datagram: []const u8) bool {
    // ONLY unicast to a peer already in the ARP cache. sendIp would otherwise RESOLVE it —
    // a blocking ARP wait (up to a second, pumping RX) inside the trace drain — and every
    // line emitted during that stall is lost. The trace must never stall the machine, and
    // must never be the thing that triggers ARP: it rides on a peer KMR1's replies have
    // already resolved, and broadcasts until then.
    if (collector) |ip| {
        if (net.isUp() and net.arpKnown(ip)) {
            if (net.sendUdpTo(ip, PORT, PORT, datagram)) return true;
        }
    }
    return net.sendBroadcastUdp(PORT, PORT, datagram);
}
const nic = @import("../nic/nic.zig");
const percpu = @import("../../../kernel/sched/percpu.zig");
const lineasm = @import("lineasm.zig"); // pure line assembly, one instance per writer
const linestore = @import("linestore.zig"); // seq-stamped retained line ring (the reliable drain)
const timer = @import("../../../kernel/timer/timer.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const buildinfo = @import("buildinfo");

/// UDP port the datagrams carry as BOTH source and destination. The reader binds it
/// (the netdebug MCP, or the harnesses' `socat -u udp-recv:9514`). Only ONE process
/// can hold it at a time — a second reader gets EADDRINUSE, which is the usual
/// reason a live capture looks dead. Single owner of the value.
pub const PORT: u16 = 9514;

/// Max line length (bytes) held in a store slot, incl. the `[NNNNNN] ` prefix and
/// trailing newline. Capped at 120 so ~11 lines pack into one DATAGRAM_CAP
/// datagram (high-resolution per-frame tracing) and trace lines stay compact; a
/// longer source line is TRUNCATED to this by the store (the short line is
/// visible). Must stay < DATAGRAM_CAP so any single line fits one datagram.
const LINE_CAP = 120;
/// Store depth in lines: the drain's queue AND the resend window share it
/// (linestore.zig — a sent line is retained until the ring wraps over it,
/// DIAG-023). Holds a full boot's log (GPU bring-up + USB enum + soak) so
/// nothing is lost between enqueue and the metered drain; a pending line
/// overwritten anyway is counted, and its sequence gap shows where.
///
/// A -Dtest-hooks build gets a far deeper store: a dropped line there reads as a
/// failed assertion and sends you hunting a kernel bug that does not exist. The
/// metering below exists to keep the GPU session loop from being perturbed by its
/// own tracing, and a test build has no such duty. Static BSS — 16k lines is
/// ~2 MB, nothing to a kernel.
const FIFO_LINES = if (buildinfo.test_hooks) 16384 else 4096;
/// Coalesced drain: each datagram PACKS as many newline-delimited FIFO lines as
/// fit in DATAGRAM_CAP, so high-rate tracing (per-frame timing at 60Hz+) streams
/// without the FIFO backing up. Packing is ALSO gentler on the NIC than the old
/// one-line-per-datagram scheme: N lines now cost ONE TX descriptor + one wire
/// frame instead of N (the 8-descriptor ring overran on bursts of tiny datagrams).
/// The receiver (tools/netdebug-mcp/server.py) splits each datagram on '\n' back
/// into individual seq-prefixed lines. Cap well under a 1500-byte MTU after the
/// 42-byte ETH+IP+UDP headers so a standard frame carries it un-fragmented.
const DATAGRAM_CAP = 1400;
/// Max datagrams emitted per drain tick — at ~10 lines each, plenty for 60 fps timing.
/// Bounded so one tick never floods the TX ring.
///
/// Raise this only modestly for a test build: each datagram is a SYNCHRONOUS NIC send, so
/// a big burst per tick stalls whatever is running (at 32 it delayed USB enumeration past
/// the harness's boot gate). FIFO_LINES is what stops evidence being lost; this only
/// decides how fast it drains.
const DATAGRAMS_PER_TICK = if (buildinfo.test_hooks) 8 else 4;
const DRAIN_INTERVAL_MS: u64 = 16; // ~one refresh — keep up with per-frame lines

/// What is left of a wire line for the actual text once the store has stamped
/// its `[NNNNNN] ` prefix and newline (linestore owns the format and the
/// sequence numbering).
const BODY_CAP = StoreT.BODY_CAP;
const StoreT = linestore.Store(FIFO_LINES, LINE_CAP);

/// Unsent lines the full store overwrote to make room — a REAL loss (the line
/// never reached the wire); the sequence gap shows WHERE, this counter shows HOW
/// MANY without replaying a capture (R59). Retention expiry — a SENT line wrapped
/// over — is not counted: those lines shipped, and losing the ability to RE-send
/// them is the ring working as sized.
var cnt_fifo_drops = counter.Counter{ .mod = .net, .name = "netdebug.fifo_drops" };
/// Datagrams the NIC refused (TX ring full): the lines were KEPT and retried next
/// tick (DIAG-024), so this counts deferrals, not losses. Climbing steadily means
/// the drain is producing faster than the NIC drains — lower DATAGRAMS_PER_TICK
/// or grow the TX ring, but nothing was lost.
var cnt_tx_defer = counter.Counter{ .mod = .net, .name = "netdebug.tx_defer" };
/// The line store: the drain's queue and the resend window (DIAG-023). One
/// kernel instance; the pure mechanics are host-tested (linestore.zig).
var store: StoreT = .{};
var enabled = false;

// Line-assembly buffer: bytes from the trace bus accumulate here until a newline
// (or BODY_CAP) completes a line. This holds the BODY ONLY — no seq prefix. The
// sequence number is stamped in emitLine(), i.e. only onto lines that actually SHIP.
// Stamping it here instead would burn a number on every suppressed line, and the gap
// in the sequence would read as packet loss — the one thing the numbering exists to
// make unambiguous.
/// One assembler PER CORE. A shared buffer is how two cores tracing at once
/// splice half of one record into the middle of another; per-core state makes
/// that impossible by construction, without a lock across the sink. The
/// assembly rules themselves are pure and host-tested (lineasm.zig).
var asm_per_core: [percpu.MAX_CPUS]lineasm.Assembler(BODY_CAP) = @splat(.{});

/// Collapses a repeating line instead of letting it eat the whole trace budget.
/// The drain is metered, so a subsystem stuck in a retry loop does not merely add
/// noise — it pushes everything else off the wire (flood.zig).
var suppressor: flood.Suppressor = .{};

var last_drain_ms: u64 = 0;

/// When set, drain() ships at most ONE datagram per tick (see drain()). The GPU
/// session loop raises it while a frame-cadence sample records, so the trace drain
/// contributes at most one datagram per tick instead of catching up in a burst that
/// could fill the NIC TX ring mid-frame. Other TX producers are not gated by it.
var gentle: bool = false;

/// Pace the trace drain down to one datagram per tick (true) or full rate (false).
/// Called by the session loop with `present.sampleActive()` so telemetry keeps
/// flowing during a cadence measurement without ever bursting on the render loop.
pub fn setGentle(g: bool) void {
    gentle = g;
}

/// Claim the NIC (idempotent) and start mirroring: install the klog sink so
/// lines enqueue from here on. Queued lines are not sent until drain() runs and
/// the delivery path is proven. Returns false (with a klog note) when no NIC
/// is present — e.g. the GPU passthrough harness, which drops the emulated NIC.
pub fn start() bool {
    if (!nic.init()) {
        klog.puts("netdebug: no NIC — disabled\n");
        return false;
    }
    // Bytes logged BEFORE the sink below exists (boot banner, framebuffer tag,
    // the pmm/pci "boot:" breadcrumbs) live only in klog's diag ring. Note
    // how many there are now; they are replayed after the banner so the LAN
    // capture carries the boot from its FIRST byte — without this the stream
    // starts mid-boot and the earliest (most failure-prone) phase is invisible
    // no matter how long the receiver listens.
    const backlog = klog.diagCount();
    counter.register(&cnt_fifo_drops);
    counter.register(&cnt_tx_defer);
    enabled = true;
    start_ms = timer.millis(); // anchors PATH_FALLBACK_MS — see pathProven
    klog.addSink(&feed);
    // Diagnostics hooks (function pointers, not imports — kernel/ stays below
    // drivers/): compliant spins pump this drain while they wait, and the deadman's
    // wedge report gets a best-effort push onto the wire from the timer interrupt.
    spinwait.pump = &drain;
    // The CPU fault handler's one chance to get a crash record off the box:
    // it must not name this driver (it is K1, this is K2), so the transport
    // announces itself here — the same shape as the boot-log sink.
    klog.setCrashFlush(&flushNow);
    deadman.distress = &distressFlush;
    // Build-identity banner: the first captured netdebug line ties the whole trace
    // to a known image, so a reader (or the netdebug MCP server) never analyses a
    // stale boot. Distinct `NETDEBUG-BUILD` marker for greppability; values come
    // from buildinfo (build.zig ← bump-build.sh), the single source of truth.
    var banner: [128]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&banner, "NETDEBUG-BUILD kudos build #{d} g{s} built {s}\n", .{
        buildinfo.build_number, buildinfo.git_hash, buildinfo.build_time,
    }) catch "NETDEBUG-BUILD kudos build #? g? built ?\n");
    klog.puts("netdebug: streaming the trace to UDP broadcast :9514 (metered; replay follows link settle)\n");
    // Replay the pre-sink backlog through the normal line assembler (wrap-aware:
    // at most two spans; the ring is far from full this early, so `diagStart`
    // is its oldest byte and the first `backlog` bytes are exactly the pre-sink
    // log). Replayed lines carry fresh sequence numbers and queue behind the
    // banner; the metered drain ships them once the link is proven.
    const buf = klog.diagBuf();
    const first = @min(backlog, buf.len - klog.diagStart());
    feed(buf[klog.diagStart()..][0..first]);
    feed(buf[0 .. backlog - first]);
    return true;
}

// ── producer side: klog sink → line FIFO ──────────────────────────────────

/// The klog slice sink: accumulate spans into the current line, prefixing
/// each line with its `[NNNNNN] ` sequence number, and enqueue on newline —
/// bytes between newlines are memcpy'd as a block, not walked one indirect
/// call at a time. Never blocks and never sends — sending is the drain pump's
/// job.
fn feed(bytes: []const u8) void {
    if (!enabled) return;
    asm_per_core[percpu.indexOrZero()].feed(bytes, {}, struct {
        fn emit(_: void, line: []const u8) void {
            completeLine(line);
        }
    }.emit);
}

/// One assembled body line: run it past the flood suppressor, then ship whatever
/// survives. A repeating line is collapsed to one marker per flood.SUMMARY_EVERY.
fn completeLine(body: []const u8) void {
    // `dbg:` records are EXEMPT, and that is not a detail. They are the
    // machine-readable contract with the integration harness — terminal output
    // (`dbg: term.N`), window state (`dbg: wm.*`), and counters the suites assert on
    // EXACTLY. Two identical records in a row are perfectly legal (a repeated command,
    // a blank line, an unchanged counter), and silently collapsing one would change an
    // assertion's count and make the suite lie. Flood suppression exists for free-text
    // log spam — which is what actually floods — so that is all it touches.
    if (std.mem.startsWith(u8, body, "dbg: ")) {
        const owed = suppressor.takeOutstanding();
        if (owed > 0) emitSummary(owed); // don't lose a flood that was in progress
        emitLine(body);
        return;
    }

    const v = suppressor.feed(body);
    switch (v.action) {
        .emit => emitLine(body),
        .suppress => {},
        .summary => emitSummary(v.count),
        .summary_then_emit => {
            emitSummary(v.count);
            emitLine(body);
        },
    }
}

/// Report suppressed repeats. This is a real wire line and takes a seq number, so a
/// flood is never invisible — you can see it happening, and how fast.
fn emitSummary(n: u32) void {
    var buf: [BODY_CAP]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "... last line repeated {d} more time{s}\n", .{
        n, if (n == 1) "" else "s",
    }) catch return;
    emitLine(msg);
}

/// Queue one body line for the wire. The store stamps the `[NNNNNN] ` prefix as
/// it pushes — so the numbering counts lines that will SHIP, and a gap in it
/// means a dropped datagram, never a suppressed line. A push that had to
/// overwrite an UNSENT line to make room is the one real loss on this side, and
/// it is counted.
fn emitLine(body: []const u8) void {
    if (store.push(body) == .dropped_pending) cnt_fifo_drops.inc();
}

/// Serve a resend request (DIAG-023): copy retained lines with wire sequence
/// numbers in `[from, from+count)` into `out`, returning the bytes used. Lines
/// already expired from the retention ring are simply absent from the answer —
/// which tells the collector the loss is permanent. Called by fileserv on the
/// KMR1 path, whose own retransmit+dedup makes the request/reply reliable.
pub fn resendInto(from: u32, n: u32, out: []u8) usize {
    if (!enabled) return 0;
    return store.resendInto(from, n, out);
}

// ── consumer side: metered drain onto the wire ──────────────────────────────

var link_ready = false;
var link_up_since: u64 = 0;

/// Whether the delivery path is proven enough to start sending: a DHCP lease
/// committed (bidirectional traffic works) or the link continuously up for
/// LINK_SETTLE_MS (PHY autoneg + switch-port forwarding delay). Frames sent
/// before this are silently lost on real hardware.
const LINK_SETTLE_MS: u64 = 10_000;

/// Hard fallback: start sending anyway once this long has passed since the NIC was
/// claimed, EVEN IF the link never reports up and DHCP never landed.
///
/// The gates above avoid shouting into a link that will swallow it (the I226 really does
/// eat frames for ~10 s after link-up). But they gate OBSERVABILITY, and an observability
/// gate that can latch shut forever is a bug: if linkUp() misreports or the switch port
/// never forwards, the machine goes silent with no way to learn why. Broadcast needs
/// neither a lease nor ARP, so the only cost of trying is dropped packets. Try anyway.
const PATH_FALLBACK_MS: u64 = 20_000;
var start_ms: u64 = 0;
var fallback_announced = false;

/// When the path was first proven — anchors COLLECTOR_WAIT_MS.
var path_proven_ms: u64 = 0;

fn pathProven() bool {
    if (link_ready) return true;
    if (net.isUp()) {
        link_ready = true;
        path_proven_ms = timer.millis();
        return true;
    }
    const now = timer.millis();
    if (!nic.linkUp()) {
        link_up_since = 0;
    } else if (link_up_since == 0) {
        link_up_since = now;
    } else if (now - link_up_since >= LINK_SETTLE_MS) {
        link_ready = true;
        return true;
    }
    // Neither a lease nor a settled link — but we have waited long enough that
    // staying silent is the worse failure. Send best-effort from here on.
    if (start_ms != 0 and now - start_ms >= PATH_FALLBACK_MS) {
        if (!fallback_announced) {
            fallback_announced = true;
            klog.puts("netdebug: no lease and no link-up after 20 s — broadcasting anyway (best effort)\n");
        }
        return true;
    }
    return false;
}

/// Scratch datagram buffer: packs multiple FIFO lines (each already newline-
/// terminated) back-to-back. Sized to DATAGRAM_CAP; a single line is ≤ LINE_CAP
/// < DATAGRAM_CAP so it always fits, and we flush before a line would spill.
var pkt: [DATAGRAM_CAP]u8 = undefined;

/// Blast EVERY queued line onto the wire right now, bypassing the metering gates
/// (interval + per-tick cap) AND the path-proven gate. Terminal-path callers
/// only — panic / CPU-fault handlers, the native-boot failure reboots
/// (gpu.bootAtInit / resetForNativeBoot), and the entry root's FATAL halts: the
/// kernel is about to halt or reset, so `drain()`'s normal pacing never runs —
/// this is the one chance to get the record off the box.
/// Best-effort and unmetered: a receiver may be missing and the NIC ring may drop
/// under the burst, but a lost packet is no worse than the silent hang it replaces.
/// Packs multiple lines per datagram exactly like drain().
pub fn flushNow() void {
    if (!enabled) return;
    @atomicStore(bool, &tx_busy, true, .release);
    defer @atomicStore(bool, &tx_busy, false, .release);
    // Sealed crash records first: on the terminal reboot path this call IS the
    // crash record's one chance to leave the box.
    shipCrashRecords();
    while (store.pending() > 0) {
        const f = store.fill(&pkt);
        if (f.lines == 0) break;
        // Advance REGARDLESS of the send result — the opposite of drain()'s rule,
        // deliberately: the machine is halting, so "keep the line and retry next
        // tick" is a tick that will never come, and looping on a refusing NIC
        // here would hang the reset path. Best effort is the contract.
        _ = emit(pkt[0..f.bytes]);
        store.advance(f.lines);
    }
}

/// Normal-context transmit in progress — the flag the IRQ-context distress path
/// checks so it never re-enters the NIC TX path mid-send. Set by drain()/flushNow()
/// around their emit loops. drain() runs from the steady loop OR the net
/// wait-hook on a fetching task (one at a time via drain_busy), and the deadman
/// fires on whatever core wedged — so this crosses cores and is read/written
/// atomically.
var tx_busy: bool = false;

/// A drain pass in progress. drain() is called from the steady session loop AND
/// from the net wait-hook inside a fetching task's blocking loops — different
/// cores — and everything it touches (the heartbeat clock, the `pkt` staging,
/// the two-phase fill/advance) is single-driver state. The loser of this
/// try-lock skips: the winner is draining the same store for both of them.
var drain_busy: bool = false;

/// The deadman's best-effort wire push, called FROM THE TIMER INTERRUPT when a core
/// has wedged (kernel/debug/deadman.zig). This is the one deliberate exception to
/// "no I/O from an interrupt": the loops that normally pump drain() are exactly
/// what is stuck, so an enqueued report would otherwise sit in the FIFO forever.
/// Guarded: skipped entirely if a normal-context send was interrupted mid-flight
/// (tx_busy), bounded by the FIFO content, at most once per deadman report pace.
fn distressFlush() void {
    if (@atomicLoad(bool, &tx_busy, .acquire)) return;
    flushNow();
}

/// Ship every sealed crash record (kernel/debug/crashlog.zig) straight onto
/// the wire in datagram-sized chunks, bypassing the line FIFO and the trace
/// bus entirely: the record may exist precisely because its core died inside
/// the bus's critical section, so the crash channel must share no failure
/// domain with the trace path. No sequence numbers — this is not the metered
/// stream; the record's own '***'-marked lines identify it. Callers hold
/// tx_busy around this.
fn shipCrashRecords() void {
    while (crashlog.takeSealed()) |rec| {
        var off: usize = 0;
        while (off < rec.bytes.len) {
            const n = @min(DATAGRAM_CAP, rec.bytes.len - off);
            // Best-effort: the record's core is already dead, and a refusing NIC
            // here has nowhere to defer to — the crash channel keeps no queue on
            // purpose (no shared failure domain with the trace path).
            _ = emit(rec.bytes[off .. off + n]);
            off += n;
        }
        crashlog.release(rec.core);
    }
}

/// Re-queue the newest `max_bytes` of the diag ring onto the wire (fresh sequence
/// numbers; the metered drain ships it). The on-demand flight-recorder dump behind
/// the KMR1 ring-tail op: dbg records land in the ring even when their module's
/// gate is off, and this is how that history gets off the box.
pub fn replayRing(max_bytes: usize) void {
    if (!enabled) return;
    const cnt = klog.diagCount();
    const take = @min(cnt, max_bytes);
    if (take == 0) return;
    const buf = klog.diagBuf();
    const tail_at = (klog.diagStart() + (cnt - take)) % buf.len;
    const first = @min(take, buf.len - tail_at);
    feed(buf[tail_at..][0..first]);
    feed(buf[0 .. take - first]);
}

/// TSC-paced liveness heartbeat, reporting the IRQ0 TICK COUNTER (spec DIAG-007).
///
/// The cadence is TSC-based deliberately: the tick is exactly what is under suspicion,
/// so the heartbeat must ride a clock that cannot stop along with it.
///
/// It exists to separate two failures that are otherwise indistinguishable from outside
/// the machine — both look like "kudos went quiet" — and that call for opposite
/// responses:
///
///   heartbeats flowing, `ticks=` FROZEN  → interrupts are dead, CPU is alive.
///       Every timer-driven timeout in the kernel (timer.sleep, xhci's enum
///       budget, awaitXfer's wall clock, deadman's fuse) is dead too — that is
///       one root cause, not four bugs.
///   heartbeats simply STOP                → the core itself is wedged (a stuck
///       MMIO read / fault with IF=0). No software watchdog can ever help.
///
/// Emitted through klog.puts like any other line, so it queues in the normal
/// FIFO and ships on the normal metered drain — no I/O from an interrupt
/// context, nothing reentrant.
const HEARTBEAT_US: u64 = 2_000_000;
var hb_t0: u64 = 0;
var hb_next: u64 = 0;
var hb_n: u64 = 0;

fn heartbeat() void {
    if (tsc.hz() == 0) return; // pre-TSC-calibration: no trustworthy clock yet
    const now = tsc.rdtsc();
    if (hb_t0 == 0) {
        hb_t0 = now;
        hb_next = now + tsc.usTicks(HEARTBEAT_US);
        return;
    }
    if (now < hb_next) return;
    hb_next = now + tsc.usTicks(HEARTBEAT_US);
    hb_n += 1;
    // Counter flush rides the heartbeat cadence: every registered counter that
    // moved since the last beat emits one dbg line (kernel/debug/counter.zig).
    counter.emitChanged();
    var buf: [LINE_CAP]u8 = undefined;
    // `ticks` (IRQ0) vs `tsc_s` (free-running): if the first stalls while the
    // second climbs, interrupts died — that comparison IS the diagnosis.
    klog.puts(std.fmt.bufPrint(&buf, "hb {d}: ticks={d} tick_ms={d} tsc_s={d}{s}\n", .{
        hb_n, timer.now(), timer.millis(), (now - hb_t0) / tsc.hz(),
        if (timer.tickStalled())
            " TICK-STALLED (IRQ0 IS DEAD)"
        else if (timer.sleptIrqsOff())
            " SLEPT-IRQS-OFF (a caller slept with interrupts masked)"
        else
            "",
    }) catch "hb: format failed\n");
    // Re-emit the build banner on the heartbeat cadence so a suite's boot-banner
    // check survives a dropped early datagram. The ONE-SHOT banner is queued before
    // the async DHCP lease is up and its backlog replay goes out by broadcast, which
    // over wifi loses ~8% of datagrams — a live kernel then reads as bannerless. A
    // steady re-emit is recovered by the next beat (the wm-state / usb.hid_present
    // pattern). Same "kudos build #<n>" token the one-shot banner carries.
    klog.puts(std.fmt.bufPrint(&buf, "kudos build #{d} g{s} (heartbeat)\n", .{
        buildinfo.build_number, buildinfo.git_hash,
    }) catch "kudos build #? (heartbeat)\n");
}

/// How long the queued boot log waits, once the path is proven, for a collector to make
/// itself known before we give up and broadcast it.
///
/// The backlog is the MOST valuable part of the trace — it is the whole boot, and it is
/// what the integration suite asserts on (the build banner, the terminal greeting, USB
/// enumeration). Replaying it the instant a lease arrives sends it by broadcast, which
/// over wifi loses ~8% of datagrams and takes those records with it: a run failed for a
/// missing `kudos build #` line on a kernel that had printed it perfectly.
///
/// A host that intends to read the trace is already pinging (KMR1) and will be known
/// within a second. Waiting a moment for it costs an idle boot nothing and buys the
/// backlog a reliable, acknowledged path. If nobody speaks up, we broadcast as before —
/// an unattended boot still narrates itself.
const COLLECTOR_WAIT_MS: u64 = 4_000;

/// Metered drain: called regularly from boot/pump.zig's systemLoop, the GPU
/// session loop, and the bring-up pump points (shim.delayUs + gpu.bringUp stage
/// boundaries). Once the path is proven, sends up to DATAGRAMS_PER_TICK queued
/// datagrams no more often than every DRAIN_INTERVAL_MS — pacing the whole-boot
/// backlog and any live burst uniformly onto the wire. Non-blocking (no sleeps):
/// the rate comes from the caller's own loop cadence via the interval gate.
pub fn drain() void {
    if (!enabled) return;
    // Liveness proof for the deadman: every steady loop pumps this drain by design,
    // so "the drain was pumped" IS "the loop is alive" — a loop that cannot reach
    // here is exactly a wedged loop (kernel/debug/deadman.zig). This is the
    // drain-pump SERVICE's own liveness (the task floats across cores — its
    // location is recorded only so the report can say where it last ran);
    // per-CORE liveness is fed by the scheduler itself. Deliberately OUTSIDE
    // the try-lock: a caller that lost the race is still a live loop.
    deadman.alivePump(percpu.indexOrZero());
    if (@cmpxchgStrong(bool, &drain_busy, false, true, .acq_rel, .acquire) != null) return;
    defer @atomicStore(bool, &drain_busy, false, .release);
    heartbeat(); // BEFORE the empty early-out: an idle kernel must still prove it lives
    if (store.pending() == 0 and !crashlog.pending()) return;
    if (collector == null and pathProven() and timer.millis() -% path_proven_ms < COLLECTOR_WAIT_MS) return;
    if (!pathProven()) return;
    // Sealed crash records jump the drain meter: rare, small, and the most
    // valuable bytes this module ever carries — a contained core's record must
    // not idle behind the interval gate.
    if (crashlog.pending()) {
        @atomicStore(bool, &tx_busy, true, .release);
        shipCrashRecords();
        @atomicStore(bool, &tx_busy, false, .release);
    }
    if (store.pending() == 0) return;
    const now = timer.millis();
    if (now - last_drain_ms < DRAIN_INTERVAL_MS) return;
    last_drain_ms = now;
    @atomicStore(bool, &tx_busy, true, .release); // the distress path must not re-enter the NIC mid-send
    defer @atomicStore(bool, &tx_busy, false, .release);
    // GENTLE while a frame-cadence sample is recording: one datagram per tick, never
    // a burst. A big one-shot catch-up (e.g. the whole boot backlog shipping the
    // instant an async DHCP lease binds — which lands right at the first present) can
    // fill the NIC's 8-descriptor TX ring and BLOCK the render loop for milliseconds
    // mid-send, dropping frames (measured: steady=0, a 29 ms outlier and a double
    // present). One datagram per tick can never fill the ring, so the drain costs a
    // frame nothing; the backlog simply takes a few more ticks to clear. Liveness and
    // the heartbeat above are unaffected. Same yield GLSTAT/bootlog already make.
    const per_tick: usize = if (gentle) 1 else DATAGRAMS_PER_TICK;
    var datagrams: usize = 0;
    while (datagrams < per_tick and store.pending() > 0) : (datagrams += 1) {
        // TWO-PHASE (DIAG-024): fill packs pending lines into the datagram
        // without consuming them; only a send the NIC accepted advances the
        // store. A refused send keeps every line for the next tick — the old
        // dequeue-first drain silently lost whole datagrams to a full TX ring,
        // and the capture showed a sequence gap with every counter green.
        const f = store.fill(&pkt);
        if (f.lines == 0) break;
        if (!emit(pkt[0..f.bytes])) {
            cnt_tx_defer.inc();
            break; // ring full — the same lines pack again next tick
        }
        store.advance(f.lines);
    }
}
