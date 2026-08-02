//! Keyboard event ring — the process-wide queue of key events the desktop
//! drains. kudos takes keyboard input from USB HID only (drivers/usb/xhci.zig
//! decodes reports and calls `inject`); netdebug's remote key injection uses
//! the same path. This module owns the ring, the injection policy, and the
//! KeyEvent/Key types; the pure USB-usage → ASCII translation lives in keymap.

const cpu = @import("../../kernel/cpu/cpu.zig");
const tsc = @import("../../kernel/cpu/tsc.zig");
const counter = @import("../../kernel/debug/counter.zig");
const Ring = @import("ring").Ring;
const keymap = @import("keymap");

/// Key events dropped because the ring was full (never silent — a dead consumer
/// hides behind dropped input otherwise). Registered on init.
pub var cnt_inject_drops = counter.Counter{ .mod = .usb, .name = "key.inject_drops" };

/// Non-character keys that carry meaning to the desktop. `.none` for ordinary
/// character/edit keys (those are conveyed via `ascii`). F10 opens the AI agent
/// window, F12 opens a terminal.
pub const Key = enum { none, f1, f10, f12 };

/// Control byte carried in `KeyEvent.ascii` for the Up arrow. The line editor
/// treats it like backspace/Enter — a control character it recognizes — so the Up
/// key needs no separate routing path (it flows through the normal ascii ring to
/// the focused terminal, which recalls the last command). DLE (0x10) is otherwise
/// unused by the kernel.
pub const KEY_UP: u8 = keymap.KEY_UP;
/// Control byte for the Down arrow — owned by the pure keymap (single source of
/// truth shared with the USB HID path).
pub const KEY_DOWN: u8 = keymap.KEY_DOWN;

pub const KeyEvent = struct {
    ascii: u8, // 0 if not a printable/edit key
    key: Key, // .none unless this press is a named non-character key (e.g. F12)
    /// TSC at receipt, stamped by `inject` (producers leave it 0). The desktop's
    /// sampling pass feeds it to the PERF-008 input-latency latch
    /// (iaccel.input_latch) so receipt → present is measurable per keystroke.
    t_tsc: u64 = 0,
};

/// Translate a USB HID keyboard usage code to ASCII, given shift. Owned by the
/// pure, host-tested keymap — the single source of truth the USB HID path
/// (src/drivers/usb/xhci.zig) shares.
pub const hidToAscii = keymap.hidToAscii;

// The event queue: the USB HID poll (and remote injection) are the producers,
// the desktop poll loop the sole consumer. The SPSC `Ring` owns the
// buffer/index logic (sync/ring.zig). A full ring drops the newest event
// (push returns false, counted). Depth: comfortably more keystrokes than can
// arrive between two poll passes, so a burst of typing loses nothing.
const KEY_RING_DEPTH = 128;
var ring: Ring(KeyEvent, KEY_RING_DEPTH) = .{};

/// Inject a key event (the USB HID driver, netdebug's remote injection) into
/// the ring. A remote injection can preempt a USB poll mid-push (netdebug
/// injects with interrupts live) — masking IF around the push keeps the ring
/// single-producer, the same pattern sched.wake uses.
pub fn inject(ev: KeyEvent) void {
    // Receipt stamp for the PERF-008 input-latency measurement: the moment the
    // event enters the system, regardless of producer (USB poll, netdebug, agent).
    var stamped = ev;
    stamped.t_tsc = tsc.rdtsc();
    const if_was_on = cpu.irqSave();
    const pushed = ring.push(stamped);
    cpu.irqRestore(if_was_on);
    if (!pushed) cnt_inject_drops.inc();
}

/// Dequeue the next key event for the consumer (the desktop poll loop), or null
/// if none is pending. Sole consumer of the SPSC ring.
pub fn poll() ?KeyEvent {
    return ring.pop();
}

/// Register the drop counter. (There is no IRQ to install: input arrives by
/// USB poll + injection, not a legacy keyboard interrupt.)
pub fn init() void {
    counter.register(&cnt_inject_drops);
}
