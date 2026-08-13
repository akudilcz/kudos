//! Mouse — the cross-layer pointer-event contract between the input drivers
//! (producers) and the desktop/WM (consumer). Owns the `MouseEvent` data type
//! and a process-wide coalescing event queue.
//!
//! LEAF under src/iface/ — no HW import, so the kernel and the host tests both
//! compile it. Producers (USB HID and netdebug's remote injection, both via
//! `inject`) fill the queue; the desktop poll loop drains it via `poll`.
//! Keeping the merge + overflow policy here means it lives in exactly one place
//! and is device-independently testable ("Event ring").
//!
//! ONE PRODUCER AT A TIME, ENFORCED. This was once single-producer by
//! construction — pointer input is USB-only and every producer ran inside core
//! 0's session loop. That stopped being true when the agent grew a pointer
//! tool: its injections run on the agent's own task, on whatever core the
//! scheduler placed it, while xhci.poll pushes HID reports on core 0. Two
//! producers on the SPSC ring can write the same slot and publish the same
//! head, which loses a button edge — a click with no release is a stuck drag,
//! and it happens precisely during agent-driven UI work.
//!
//! Coalescing is why this is a LOCK and not a lock-free multi-producer push:
//! `aggregate` merges into the newest queued slot (`lastMut`), which is a
//! read-modify-write of a slot the producer no longer exclusively owns. The
//! critical section is a few stores on a path that carries at most a few
//! hundred events a second, so the contention this costs is nil against the
//! class of bug it removes.
//!
//! Unlike the vtable ifaces (idisplay/ipresent), this is pure data + logic with
//! no substitutable backend, so it is a plain module tested directly — like
//! `ilog`'s process-wide sink rather than a runtime vtable (CLAUDE.md: "a module
//! with only pure logic is tested directly; do not wrap it in an interface").

const Ring = @import("ring").Ring;
const log = @import("ilog");

pub const MouseEvent = struct {
    dx: i32,
    dy: i32, // already converted to screen-down-positive
    buttons: u8, // bit0 left, bit1 right, bit2 middle
    // Absolute position in pixels (e.g. from a USB tablet). When non-null the
    // desktop sets the cursor here directly instead of integrating dx/dy — this
    // keeps an absolute pointer in 1:1 sync with no drift, wrap, or scaling loss.
    abs: ?struct { x: i32, y: i32 } = null,
    // TSC reading at the producer when this sample arrived — the receipt stamp.
    // Relative events feed it to the acceleration curve as the velocity clock
    // ("Pointer acceleration"); every consumed event feeds it to the PERF-008
    // input→present latency latch (iaccel.input_latch). `abs` events bypass
    // acceleration but still carry the stamp for the latency measurement.
    t_tsc: u64 = 0,
};

/// Screen extents in pixels, published by whoever owns the screen (the desktop, once it
/// knows its logical size) and read by producers of ABSOLUTE events — a USB tablet reports
/// a 0..0xFFFF logical position that must be scaled into pixels.
///
/// This lives on the pointer contract because it is the pointer's coordinate space. Without
/// it a USB driver has to import the compositor's framebuffer to learn two integers, which
/// is not a seam — it is an argument it failed to take (CLAUDE.md "Before you add an
/// interface"). Zero until the screen is up; producers must treat 0 as "not yet known".
pub var screen_w: usize = 0;
pub var screen_h: usize = 0;

/// Publish the pointer's coordinate space. Called by the screen owner on init and on any
/// mode change — an absolute pointer scaled against a stale size lands in the wrong place.
pub fn setScreen(w: usize, h: usize) void {
    screen_w = w;
    screen_h = h;
}

// SPSC event queue (sync/ring.zig): the session loop's producers fill it (see
// the module doc for why they cannot race); the desktop poll loop drains it.
// Depth holds more distinct button edges than can accumulate between two poll
// passes. Pure motion never fills it because `aggregate` coalesces same-button
// relative deltas into the last-queued event.
pub const MOUSE_RING_DEPTH = 128;
var ring: Ring(MouseEvent, MOUSE_RING_DEPTH) = .{};

/// Count of events dropped on true overflow (ring full of non-mergeable distinct
/// button edges). Coalescing makes this essentially unreachable for one relative
/// pointer; a non-zero value is surfaced over the log seam, never silently masked.
pub var dropped_events: u64 = 0;

/// The single producer path for both sources (USB HID `inject` and netdebug
/// handler), so the merge + overflow policy live in exactly one place.
///
/// Coalesces an incoming **relative** delta into the newest queued event when
/// both carry the **same buttons** and neither is absolute — position is the
/// integral of the deltas, so summing is exact and loses no motion even if the
/// consumer stalls. A button change or an absolute event never merges (the
/// compositor is edge-triggered on button transitions, and an absolute position
/// is authoritative, not additive). Safe to
/// read-modify the newest slot because producer and consumer are serialized on
/// one core (USB is polled on that core).
/// Guards the producer side (see the header). A plain test-and-set rather than
/// the kernel's SpinLock: this contract is a LEAF that host tests compile, and
/// the section it protects is a handful of stores that never blocks, faults or
/// re-enters — so there is nothing here for a richer lock to do.
var produce_lock: bool = false;

fn acquireProduce() void {
    while (@cmpxchgWeak(bool, &produce_lock, false, true, .acq_rel, .acquire) != null) {
        // The holder is a few stores from done; spin rather than sleep.
        asm volatile ("pause");
    }
}

fn releaseProduce() void {
    @atomicStore(bool, &produce_lock, false, .release);
}

pub fn aggregate(ev: MouseEvent) void {
    acquireProduce();
    defer releaseProduce();
    if (ev.abs == null) {
        if (ring.lastMut()) |last| {
            if (last.abs == null and last.buttons == ev.buttons) {
                last.dx += ev.dx;
                last.dy += ev.dy;
                last.t_tsc = ev.t_tsc; // velocity uses the coalesced window's true span
                return;
            }
        }
    }
    if (!ring.push(ev)) {
        // True overflow: distinct button edges filled the ring. Keep the oldest
        // (the pending edges), reject the newest, and fail loud.
        dropped_events +%= 1;
        log.puts("imouse.ring_overflow ");
        log.putHex(dropped_events);
        log.puts("\n");
    }
}

/// Inject a mouse event from a producer (e.g. the USB HID driver).
pub fn inject(ev: MouseEvent) void {
    aggregate(ev);
}

/// Dequeue the next mouse event for the consumer (the desktop poll loop), or
/// null if none is pending. Sole consumer of the SPSC ring.
pub fn poll() ?MouseEvent {
    return ring.pop();
}
