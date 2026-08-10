//! VM mailboxes — the cross-core contract between the hypervisor's guest machine
//! models (each running a vCPU on some core) and the VM console desktop apps
//! (core 0). The two peer groups — kernel/virt and the apps — must not import
//! each other, so they share ONLY this leaf: per-VM lifecycle state, a stop
//! mailbox, the serial-console byte streams, and the guest scanout publish.
//!
//! LEAF under src/iface/ — imports only the SPSC `ring` primitive, so the
//! kernel and the host tests both compile it.
//!
//! MANY VMs: the mailbox is an array of `MAX_VMS` independent slots addressed by
//! `Id`. Slots share no state, so two guests never see each other's console,
//! scanout or lifecycle. This module holds no allocation policy — which slot is
//! live, and when a retired slot may be reused, is the hypervisor's registry
//! (kernel/virt/vmslots.zig); here an `Id` is simply an index.
//!
//! LOCK-FREE by construction, like `iwindow`: within one slot every shared item
//! has exactly one producer and one consumer, ordered by release/acquire, never
//! a spinlock (which would stall the compositor behind a vCPU exit). The serial
//! streams are two SPSC rings; the stop flag and the dirty flag are one-shot
//! release/acquire handshakes. `fb_gen` orders the scanout publish (the
//! hypervisor writes fb_* then releases the generation; the app acquires the
//! generation then reads the fields). An `fb` read racing a re-publish may pair
//! a fresh pointer with stale dimensions for one frame — cosmetic, like screen
//! tearing — and out of bounds only if a publisher violates the publishFb
//! contract: dimensions are clamped to FB_MAX_W x FB_MAX_H, and a published
//! scanout buffer must hold at least that many pixels.

const Ring = @import("ring").Ring;

/// How many guests can exist at once. Each live VM owns its
/// own guest RAM, so this is a cap on concurrent guests, not on how many can be
/// started over a session. The hypervisor's registry (kernel/virt/vmslots.zig)
/// sizes its slot table from this, so raising it here raises it everywhere.
pub const MAX_VMS: usize = 4;

/// A mailbox slot index, `0..MAX_VMS-1`. Handed out by the hypervisor at VM
/// creation and carried by the VM's console window for as long as it is open.
pub const Id = usize;

/// VM lifecycle, stored by the hypervisor, polled by the app for its status
/// line. A single u8 store/load pair — release/acquire so the app also sees
/// whatever the hypervisor wrote before the transition (e.g. final console
/// output before `.halted`).
pub const State = enum(u8) { absent, fetching, booting, running, halted, failed };

/// Which half of a netboot pair a `.fetching` slot is downloading — a catalog
/// guest arrives as a kernel then an initramfs (VIRT-019).
pub const FetchHalf = enum(u8) { kernel, initramfs };

/// A `.fetching` slot's download standing, as `fetchProgress` reports it.
/// `total` is 0 until the server states the half's size.
pub const FetchProgress = struct { half: FetchHalf, done: u64, total: u64 };

/// Serial-console ring capacities. TX (guest -> screen) is deep because a
/// booting kernel bursts whole screenfuls between app frames; RX (keystroke ->
/// guest) only ever holds what a human types between vCPU polls.
pub const TX_CAP = 8192;
pub const RX_CAP = 256;

/// Input events (window -> guest) buffered between vCPU polls. A human cannot
/// produce many pointer samples in one frame and a keystroke is two events, so
/// this only ever holds one frame's worth; it exists so the window never has to
/// touch a device the guest's own core owns.
pub const INPUT_CAP = 64;

/// The absolute range a pointer position is expressed in, 0..ABS_RANGE on both
/// axes. The window scales into it and the device model declares it, so neither
/// has to know the other's pixel dimensions: a window resize changes the
/// scaling, never the guest's idea of how big its own screen is.
pub const ABS_RANGE: u32 = 0x7FFF;

/// One input event on its way to a guest, in the terms the window means them —
/// not the evdev wire format, which belongs to the device model. `code` is the
/// Linux key or button code; motion is absolute, in 0..ABS_RANGE.
pub const InputEvent = union(enum) {
    key: struct { code: u16, down: bool },
    button: struct { code: u16, down: bool },
    motion: struct { x: u32, y: u32 },
};

/// Scanout dimension ceiling: the virtio-gpu device model refuses larger
/// modes, so every published buffer holds at least FB_MAX_W * FB_MAX_H pixels.
/// Sized for a browser-kiosk guest: comfortable page width while keeping the
/// per-frame guest→host pixel copy well under a full-HD one.
pub const FB_MAX_W = 1600;
pub const FB_MAX_H = 900;

/// The mode the device ADVERTISES as its display, which is the one a guest
/// takes unless it asks for something else — the size every guest therefore
/// renders at, and so the size a VM window has to show.
///
/// It is smaller than the ceiling above on purpose. The window draws a scanout
/// at its own size, one guest pixel per screen pixel (apps/vm.zig): scaling it
/// would resample the guest's picture, and what a fractional resample destroys
/// first is console text — an 8x16 font loses a row per glyph and the lines run
/// together. So the advertised mode must FIT the window, or the part that does
/// not fit is cropped away.
///
/// This is what fits a maximised VM window on a 1280x800 display once the
/// title bar and the window's status strip are taken out, and it is a standard
/// mode rather than an invented one. A guest that wants the full ceiling still
/// gets it by setting its own mode; nothing here limits the device.
pub const FB_MODE_W = 1280;
pub const FB_MODE_H = 720;

/// Largest Ethernet frame the NIC bridge carries — the network contract's
/// frame ceiling, re-exported so the bridge's producers and consumers size
/// their buffers from the mailbox they talk through.
pub const NET_FRAME_BYTES = @import("inet").ETHER_FRAME_MAX;

/// Bridged frames buffered per guest per direction between the system loop and
/// the guest's core. Sixteen frames each way per scheduling slice (~2 ms) keeps
/// a browser's TCP window moving at tens of Mbit/s, far above what the page
/// loads here need; a burst beyond it drops and is counted, never silent.
pub const NET_RING_FRAMES = 16;

/// One Ethernet frame in flight across the bridge, length-prefixed because the
/// ring copies fixed-size slots.
pub const NetFrame = struct {
    len: u16 = 0,
    data: [NET_FRAME_BYTES]u8 = undefined,
};

/// One guest's mailbox. Every field's producer/consumer pairing is documented on
/// the accessor below; nothing here is shared between slots.
const Slot = struct {
    state: State = .absent,
    /// One-shot stop request (app -> hypervisor), the same handshake shape as
    /// `iwindow`'s close_pending.
    stop_pending: bool = false,
    /// guest -> screen: producer hypervisor (conWrite), consumer app (conRead).
    con_tx: Ring(u8, TX_CAP) = .{},
    /// keystroke -> guest: producer app (conInput), consumer hypervisor (conFetch).
    con_rx: Ring(u8, RX_CAP) = .{},
    /// key/pointer -> guest: producer app (inputPost), consumer hypervisor
    /// (inputFetch), drained onto the guest's own core. Serial input and this
    /// ring are two different guests' worth of interface — a shell reads the
    /// serial port, a compositor reads evdev — so a window feeds both and lets
    /// the guest use the one it has a driver for.
    input_rx: Ring(InputEvent, INPUT_CAP) = .{},
    /// guest -> wire: producer hypervisor (netPost, on the guest's core),
    /// consumer the system loop's bridge (netFetch), which puts each frame on
    /// the real NIC.
    net_tx: Ring(NetFrame, NET_RING_FRAMES) = .{},
    /// wire -> guest: producer the system loop's bridge (netDeliver), consumer
    /// hypervisor (netPeek/netCommit), landed in the guest's receive queue on
    /// its core.
    net_rx: Ring(NetFrame, NET_RING_FRAMES) = .{},
    /// Bytes each discarding path dropped on a full ring — counted, never
    /// silent. Each has a single writer (its ring's producer); readers load
    /// monotonic, so a status line can report the loss from either core.
    dropped_tx: u64 = 0,
    dropped_rx: u64 = 0,
    /// Input events dropped on a full ring. A guest whose driver is not reading
    /// cannot be typed at, and that shows here rather than as silence.
    dropped_input: u64 = 0,
    /// Bridged frames dropped on a full ring, per direction. A guest whose
    /// downloads stall shows the loss here rather than as silence.
    dropped_net_tx: u64 = 0,
    dropped_net_rx: u64 = 0,
    /// Guest console bytes written since reset, dropped or not. Zero after a
    /// guest has supposedly booted is the tell that separates a dead guest
    /// from a quiet one — a Linux boot always writes serial.
    written_tx: u64 = 0,
    /// Download standing while `state == .fetching`: which half is in flight
    /// and how far it has come (fetch_total 0 = size not yet known). Producer
    /// hypervisor (the system loop's netboot pump), consumer app. Monotonic
    /// per-field stores: a read tearing across an update misdraws one frame of
    /// a progress bar, nothing more.
    fetch_half: FetchHalf = .kernel,
    fetch_done: u64 = 0,
    fetch_total: u64 = 0,
    /// The published scanout. `fb_gen` (0 = never published) is the publish
    /// barrier for the other three fields, bumped by every publish AND retract.
    fb_ptr: ?[*]const u32 = null,
    fb_w: u32 = 0,
    fb_h: u32 = 0,
    fb_gen: u32 = 0,
    /// A flushed frame awaits compositing.
    fb_dirty: bool = false,
};

var slots: [MAX_VMS]Slot = [_]Slot{.{}} ** MAX_VMS;

/// HYPERVISOR: publish a lifecycle transition for VM `id`.
pub fn setState(id: Id, s: State) void {
    @atomicStore(State, &slots[id].state, s, .release);
}

/// APP: the current lifecycle state of VM `id`.
pub fn state(id: Id) State {
    return @atomicLoad(State, &slots[id].state, .acquire);
}

/// HYPERVISOR (system loop, while VM `id` is `.fetching`): publish how far the
/// download has come.
pub fn setFetchProgress(id: Id, half: FetchHalf, done: u64, total: u64) void {
    const s = &slots[id];
    @atomicStore(FetchHalf, &s.fetch_half, half, .monotonic);
    @atomicStore(u64, &s.fetch_done, done, .monotonic);
    @atomicStore(u64, &s.fetch_total, total, .monotonic);
}

/// APP: VM `id`'s download standing, meaningful while `state` is `.fetching`.
pub fn fetchProgress(id: Id) FetchProgress {
    const s = &slots[id];
    return .{
        .half = @atomicLoad(FetchHalf, &s.fetch_half, .monotonic),
        .done = @atomicLoad(u64, &s.fetch_done, .monotonic),
        .total = @atomicLoad(u64, &s.fetch_total, .monotonic),
    };
}

/// APP (or the console): ask VM `id` to stop. Idempotent — a second request
/// before the hypervisor takes the first changes nothing.
pub fn requestStop(id: Id) void {
    @atomicStore(bool, &slots[id].stop_pending, true, .release);
}

/// HYPERVISOR: take VM `id`'s pending stop request, if any. One-shot: true once
/// per request, so the run loop can act on it exactly once.
pub fn takeStop(id: Id) bool {
    if (!@atomicLoad(bool, &slots[id].stop_pending, .acquire)) return false;
    @atomicStore(bool, &slots[id].stop_pending, false, .release);
    return true;
}

/// No boot request pending — the mailbox's empty value (an image number can
/// never reach it).
const NO_BOOT_REQUEST: u32 = 0xFFFF_FFFF;

/// The boot-request mailbox: which guest image to boot (its `vm boot` list
/// number). One cell — a second request while one is in flight is refused,
/// never queued (the caller reports it). No core is named: a guest's vCPU is
/// an ordinary task placed by the scheduler (VIRT-021).
var boot_request: u32 = NO_BOOT_REQUEST;

/// A taken boot request: the image's `vm boot` list number (1 = the staged
/// built-in).
pub const BootRequest = struct { image: u8 };

/// A session or the shell: ask the system task to create a guest of catalog
/// image `image`. False when a request is already in flight.
pub fn postBootRequest(image: u8) bool {
    return @cmpxchgStrong(u32, &boot_request, NO_BOOT_REQUEST, image, .acq_rel, .acquire) == null;
}

/// The system task: take the pending boot request, if any.
pub fn takeBootRequest() ?BootRequest {
    const v = @atomicLoad(u32, &boot_request, .acquire);
    if (v == NO_BOOT_REQUEST) return null;
    @atomicStore(u32, &boot_request, NO_BOOT_REQUEST, .release);
    return .{ .image = @intCast(v & 0xFF) };
}

/// Whether a stop has been requested for VM `id` and not yet taken. A
/// non-destructive peek for status display; `takeStop` is the consuming read.
pub fn stopRequested(id: Id) bool {
    return @atomicLoad(bool, &slots[id].stop_pending, .acquire);
}

/// HYPERVISOR: queue one guest console byte for the screen. Returns false and
/// counts the drop when the app is not draining fast enough — the vCPU never
/// blocks on the display.
pub fn conWrite(id: Id, b: u8) bool {
    const s = &slots[id];
    @atomicStore(u64, &s.written_tx, s.written_tx + 1, .monotonic);
    if (s.con_tx.push(b)) return true;
    @atomicStore(u64, &s.dropped_tx, s.dropped_tx + 1, .monotonic);
    return false;
}

/// APP: pop one guest console byte for the screen, or null when caught up.
pub fn conRead(id: Id) ?u8 {
    return slots[id].con_tx.pop();
}

/// APP: queue one keystroke for the guest. Returns false and counts the drop
/// when the guest is not reading its serial input.
pub fn conInput(id: Id, b: u8) bool {
    const s = &slots[id];
    if (s.con_rx.push(b)) return true;
    @atomicStore(u64, &s.dropped_rx, s.dropped_rx + 1, .monotonic);
    return false;
}

/// APP: count one keystroke that never reached the guest because the window's
/// own queue was full too (VIRT-036). The mailbox owns the "keystrokes this
/// guest never got" tally, and a loss one hop upstream of the ring is still
/// that loss — counting it anywhere else would split the count in two.
pub fn countInputDrop(id: Id) void {
    const s = &slots[id];
    @atomicStore(u64, &s.dropped_rx, s.dropped_rx + 1, .monotonic);
}

/// APP: queue one input event for the guest's keyboard or pointer. Returns
/// false and counts the drop when the guest is not draining them.
pub fn inputPost(id: Id, ev: InputEvent) bool {
    const s = &slots[id];
    if (s.input_rx.push(ev)) return true;
    @atomicStore(u64, &s.dropped_input, s.dropped_input + 1, .monotonic);
    return false;
}

/// HYPERVISOR: pop one input event, or null when none waits.
pub fn inputFetch(id: Id) ?InputEvent {
    return slots[id].input_rx.pop();
}

/// Input events dropped on a full ring since this slot was last reset.
pub fn droppedInput(id: Id) u64 {
    return @atomicLoad(u64, &slots[id].dropped_input, .monotonic);
}

/// Copy one frame into a NetFrame slot, or count a drop against `counter` —
/// the one body behind both bridge directions. An oversized frame is dropped
/// here too: the ring's slot is the size contract, and truncating an Ethernet
/// frame would forward a corrupt packet instead of a counted loss.
fn framePush(ring: anytype, counter: *u64, frame: []const u8) bool {
    if (frame.len <= NET_FRAME_BYTES) {
        var slot = NetFrame{ .len = @intCast(frame.len) };
        @memcpy(slot.data[0..frame.len], frame);
        if (ring.push(slot)) return true;
    }
    @atomicStore(u64, counter, counter.* + 1, .monotonic);
    return false;
}

/// Copy the next queued frame into `buf` and return its length, or null when
/// none waits. `buf` must hold NET_FRAME_BYTES.
fn framePop(ring: anytype, buf: []u8) ?usize {
    const slot = ring.pop() orelse return null;
    @memcpy(buf[0..slot.len], slot.data[0..slot.len]);
    return slot.len;
}

/// HYPERVISOR (guest core): queue one guest-transmitted Ethernet frame for the
/// bridge to put on the wire. False (and a counted drop) when the bridge is
/// not draining — a guest flooding faster than the system loop forwards.
pub fn netPost(id: Id, frame: []const u8) bool {
    const s = &slots[id];
    return framePush(&s.net_tx, &s.dropped_net_tx, frame);
}

/// BRIDGE (system loop): copy the next guest-transmitted frame into `buf`
/// (NET_FRAME_BYTES long) and return its length, or null when none waits.
pub fn netFetch(id: Id, buf: []u8) ?usize {
    return framePop(&slots[id].net_tx, buf);
}

/// BRIDGE (system loop): queue one wire frame for guest `id`. False (and a
/// counted drop) when the guest is not draining its receive ring.
pub fn netDeliver(id: Id, frame: []const u8) bool {
    const s = &slots[id];
    return framePush(&s.net_rx, &s.dropped_net_rx, frame);
}

/// HYPERVISOR (guest core): copy the next wire frame for guest `id` into `buf`
/// (NET_FRAME_BYTES long) and return its length, WITHOUT consuming it;
/// `netCommit` retires it once it has landed in the guest's receive queue.
/// Two calls rather than one because the guest's NIC can refuse a frame — its
/// driver is not up yet, or it has published no free receive buffer — and a
/// frame taken for a refusal would be destroyed instead of waiting in the ring
/// for a poll when the driver has caught up.
pub fn netPeek(id: Id, buf: []u8) ?usize {
    const slot = slots[id].net_rx.peek() orelse return null;
    @memcpy(buf[0..slot.len], slot.data[0..slot.len]);
    return slot.len;
}

/// HYPERVISOR (guest core): retire the frame `netPeek` just returned.
pub fn netCommit(id: Id) void {
    slots[id].net_rx.drop();
}

/// Bridged frames dropped per direction since this slot was last reset.
pub fn droppedNetTx(id: Id) u64 {
    return @atomicLoad(u64, &slots[id].dropped_net_tx, .monotonic);
}
pub fn droppedNetRx(id: Id) u64 {
    return @atomicLoad(u64, &slots[id].dropped_net_rx, .monotonic);
}

/// HYPERVISOR: pop one keystroke for the guest UART, or null when none waits.
pub fn conFetch(id: Id) ?u8 {
    return slots[id].con_rx.pop();
}

/// HYPERVISOR: whether a keystroke is waiting (drives the UART's data-ready
/// status without consuming the byte).
pub fn conPending(id: Id) bool {
    return !slots[id].con_rx.isEmpty();
}

/// Guest console bytes written since this slot was last reset, dropped or not.
pub fn writtenTx(id: Id) u64 {
    return @atomicLoad(u64, &slots[id].written_tx, .monotonic);
}

/// Guest bytes dropped on a full TX ring since this slot was last reset.
pub fn droppedTx(id: Id) u64 {
    return @atomicLoad(u64, &slots[id].dropped_tx, .monotonic);
}

/// Keystrokes dropped on a full RX ring since this slot was last reset.
pub fn droppedRx(id: Id) u64 {
    return @atomicLoad(u64, &slots[id].dropped_rx, .monotonic);
}

/// HYPERVISOR (at SET_SCANOUT): publish VM `id`'s guest framebuffer. `ptr` must
/// stay valid, and hold at least FB_MAX_W * FB_MAX_H tightly-packed BGRA
/// pixels, until `retractFb` — that headroom is what makes a torn `fb` read
/// in-bounds. Dimensions are clamped to the ceiling.
pub fn publishFb(id: Id, ptr: [*]const u32, w: u32, h: u32) void {
    const s = &slots[id];
    s.fb_ptr = ptr;
    s.fb_w = @min(w, FB_MAX_W);
    s.fb_h = @min(h, FB_MAX_H);
    const gen = @atomicLoad(u32, &s.fb_gen, .monotonic);
    @atomicStore(u32, &s.fb_gen, gen +% 1, .release); // barrier: publishes fb_*
}

/// HYPERVISOR (scanout disabled, or VM stop): withdraw the framebuffer; `fb`
/// returns null from the next generation on.
pub fn retractFb(id: Id) void {
    const s = &slots[id];
    s.fb_ptr = null;
    s.fb_w = 0;
    s.fb_h = 0;
    s.fb_dirty = false;
    const gen = @atomicLoad(u32, &s.fb_gen, .monotonic);
    @atomicStore(u32, &s.fb_gen, gen +% 1, .release); // barrier: publishes the retract
}

pub const Fb = struct { ptr: [*]const u32, w: u32, h: u32, gen: u32 };

/// APP: VM `id`'s current scanout, or null while none is published. The acquire
/// on the generation pairs with `publishFb`/`retractFb`'s release; a read racing
/// a re-publish may mix generations for one frame (cosmetic, in-bounds — see
/// the module header).
pub fn fb(id: Id) ?Fb {
    const s = &slots[id];
    const gen = @atomicLoad(u32, &s.fb_gen, .acquire); // barrier: orders the field reads
    const p = s.fb_ptr orelse return null;
    return .{ .ptr = p, .w = s.fb_w, .h = s.fb_h, .gen = gen };
}

/// HYPERVISOR (at RESOURCE_FLUSH): the guest finished drawing a frame.
pub fn markFbDirty(id: Id) void {
    @atomicStore(bool, &slots[id].fb_dirty, true, .release);
}

/// APP (damage pass): whether VM `id` has an unconsumed flush waiting, WITHOUT
/// consuming it.
///
/// The desktop asks two separate questions a frame, in this order: "did anything
/// change?" — which decides whether to render at all — and then, inside the
/// render, "is there a new scanout to upload?". Only the second may consume the
/// flag. A graphical guest emits no serial output at all, so this peek is the
/// ONLY evidence that its window changed; without it the window holds whatever
/// it last drew until some unrelated damage forces a frame, and the guest's
/// painting appears on screen only when a neighbouring window is dragged.
pub fn fbDirty(id: Id) bool {
    return @atomicLoad(bool, &slots[id].fb_dirty, .acquire);
}

/// APP (once per frame): whether VM `id`'s scanout changed since the last take.
/// One-shot: true once per flush, so the app re-uploads only fresh frames.
pub fn takeFbDirty(id: Id) bool {
    const s = &slots[id];
    if (!@atomicLoad(bool, &s.fb_dirty, .acquire)) return false;
    @atomicStore(bool, &s.fb_dirty, false, .monotonic);
    return true;
}

/// Clear slot `id` entirely — state, stop flag, both serial rings, drop
/// counters, and the scanout — so the next VM to take this slot starts fresh.
/// Called by the hypervisor's registry when it hands the slot out, at which
/// point the previous guest's vCPU has finished and its window is gone, so
/// there is no concurrent user to race (kernel/virt/vmslots.zig).
pub fn reset(id: Id) void {
    slots[id] = .{};
}
