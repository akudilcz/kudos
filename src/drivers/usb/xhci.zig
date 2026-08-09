//! xHCI USB host controller driver — the subset kudos needs: controller bring-up,
//! slot/endpoint contexts, control and bulk/interrupt transfers, hubs, HID and mass
//! storage. Register and TRB layouts follow the xHCI specification, so the same
//! code drives QEMU's emulated controller and the real Intel PCH. Polled (no
//! interrupts): the event ring is drained from the main path.

const std = @import("std");
const pci = @import("../pci/pci.zig");
const pmm = @import("../../kernel/memory/pmm.zig");
const klog = @import("../../kernel/debug/klog.zig");
const wait = @import("../io/wait.zig");
const timer = @import("../../kernel/timer/timer.zig");
const tsc = @import("../../kernel/cpu/tsc.zig");
const mmioz = @import("../io/mmio.zig");
const dbg = @import("../../kernel/debug/debug.zig");
const gate = @import("../../kernel/debug/gate.zig");
const counter = @import("../../kernel/debug/counter.zig");
const debounce = @import("debounce.zig");
const port_fsm = @import("port_fsm.zig");
const trb = @import("trb.zig");
const xhci_cc = @import("xhci_cc.zig");
const xhci_ctx = @import("xhci_ctx.zig");
const devmask = @import("devmask.zig");
const msc = @import("msc.zig");
const hub = @import("hub.zig");
const spinlock = @import("../../kernel/sync/spinlock.zig");
const hid_report = @import("hid_report.zig");

/// Emit a diag string, but only when `.usb` logging is enabled — the driver is
/// silent on a normal boot and verbose only when tracing on-HW enumeration.
fn log(s: []const u8) void {
    if (gate.on(.usb)) klog.puts(s);
}
/// Emit a diag string followed by a hex value (gated on `.usb`), for tracing a
/// register/handle without a full formatter.
fn logx(s: []const u8, v: u64) void {
    if (gate.on(.usb)) {
        klog.puts(s);
        klog.putHex(v);
        klog.putc('\n');
    }
}
/// Two labelled hex values on one line: `s1<v1>s2<v2>`. For tracing a port number
/// alongside its status word without a full formatter.
fn logx2(s1: []const u8, v1: u64, s2: []const u8, v2: u64) void {
    if (gate.on(.usb)) {
        klog.puts(s1);
        klog.putHex(v1);
        klog.puts(s2);
        klog.putHex(v2);
        klog.putc('\n');
    }
}
/// Hex-dump `n` bytes at `addr` to the diag log, prefixed by `s`. For on-HW
/// descriptor diagnosis where a logic analyzer isn't available.
fn logBytes(s: []const u8, addr: usize, n: usize) void {
    if (!gate.on(.usb)) return;
    klog.puts(s);
    // Volatile: addr is usually a DMA buffer (descbuf) — a plain read folds to
    // the pre-transfer memset.
    const p: [*]const volatile u8 = @ptrFromInt(addr);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        klog.putHex(p[i]);
        klog.putc(' ');
    }
    klog.putc('\n');
}
/// Trace one root port's PORTSC, decoded. Emitted for EVERY port during the scan
/// so a device that never enumerates (e.g. a USB2 companion hub that fails to
/// show CCS) is visible in the netdebug trace instead of silently skipped.
fn logPort(port: u32, portsc: u32) void {
    if (!gate.on(.usb)) return;
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "xhci: rootport {d} portsc=0x{x} ccs={d} pp={d} pls={d} spd={d}\n", .{
        port,
        portsc,
        portsc & 1, // CCS
        (portsc >> 9) & 1, // PP
        (portsc >> 5) & 0xF, // PLS
        (portsc >> 10) & 0xF, // speed
    }) catch return;
    log(s);
}

/// Build a root-port record key: `usb.rootport.<port>`. Kept short-lived in a
/// static buffer, used immediately by the caller (single-threaded enumeration).
fn rpKey(port: u32) []const u8 {
    const S = struct {
        var buf: [24]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "usb.rootport.{d}", .{port}) catch "usb.rootport.N";
}
/// Structured netdebug record of one root port's decoded PORTSC — emitted for EVERY
/// port whether or not a device is found, so a USB2 companion port that reads
/// CCS=0 (the missing boot keyboard/mouse) leaves a greppable key=value trace
/// (`usb.rootport.<n>.*`) rather than only an unstructured log line. `result`
/// is the scan verdict resetPort reached for the port (connected / the specific
/// reason it was dropped).
fn recordRootPort(port: u32, portsc: u32, result: []const u8) void {
    const k = rpKey(port);
    dvSetHex(k, "portsc", portsc);
    dvSet(k, "ccs", portsc & 1);
    dvSet(k, "pp", (portsc >> 9) & 1);
    dvSet(k, "pls", (portsc >> 5) & 0xF);
    dvSet(k, "spd", (portsc >> 10) & 0xF);
    dvSetStr(k, "result", result);
}

// Capability registers (offsets from BAR0).
const CAP_CAPLENGTH = 0x00;
const CAP_HCSPARAMS1 = 0x04;
const CAP_HCSPARAMS2 = 0x08;
const CAP_HCCPARAMS1 = 0x10;
const CAP_DBOFF = 0x14;
const CAP_RTSOFF = 0x18;

// Operational registers (offsets from op_base = BAR0 + CAPLENGTH).
const OP_USBCMD = 0x00;
const OP_USBSTS = 0x04;
const OP_CRCR = 0x18;
const OP_DCBAAP = 0x30;
const OP_CONFIG = 0x38;
const OP_PORTSC = 0x400; // port 1; port N at 0x400 + (N-1)*0x10

const USBCMD_RS = 1 << 0;
const USBCMD_HCRST = 1 << 1;
const USBCMD_INTE = 1 << 2; // interrupter enable (must be set for events on real HW)
const USBSTS_HCH = 1 << 0;
const USBSTS_CNR = 1 << 11;

// Interrupter 0 registers (offsets from rt_base). The interrupter register set
// starts at rt_base + 0x20; ERSTSZ/ERSTBA/ERDP follow IMAN/IMOD (xHCI §5.5.2).
const IMAN = 0x20; // Interrupter Management
const IMOD = 0x24; // Interrupter Moderation
const RT_ERSTSZ = 0x28; // Event Ring Segment Table Size
const RT_ERSTBA = 0x30; // Event Ring Segment Table Base Address
const RT_ERDP = 0x38; // Event Ring Dequeue Pointer
const IMAN_IP = 1 << 0; // interrupt pending (RW1C)
const IMAN_IE = 1 << 1; // interrupt enable
const ERDP_EHB: u64 = 1 << 3; // Event Handler Busy (RW1C; written back on each advance)

// Intel PCH xHCI USB2/USB3 port-routing registers (PCI config space). On real
// Intel hardware the USB2 ports default to the shared EHCI path; until handed
// over, PORTSC.CCS reads 0 and enumeration finds nothing.
const PCI_VENDOR_INTEL = 0x8086;
const INTEL_XUSB2PR = 0xD0; // USB2 port routing
const INTEL_USB2PRM = 0xD4; // USB2 ports that may be routed
const INTEL_USB3_PSSEN = 0xD8; // USB3 SuperSpeed enable
const INTEL_USB3PRM = 0xDC; // USB3 ports that may be routed

// The 16-byte TRB layout is trb.Trb — one home (trb.zig), shared with the
// class glue behind the controller seam (hub.zig).

const CMD_RING_TRBS = 64;
const EVENT_RING_TRBS = 64;
// Per-device transfer-ring depth (TRBs), for EP0 and each interrupt-IN endpoint.
// A single control transfer uses at most 3 TRBs (setup/data/status); 64 leaves
// generous headroom before the link-TRB wrap so an in-flight interrupt report
// never collides with a control transfer on the same ring.
const DEVICE_RING_TRBS = 64;
// HID interrupt-IN report DMA buffer size (bytes). Boot reports are <= 8 bytes
// and the largest HID report we drive fits well under this; one cache-line-ish
// buffer is ample and keeps the endpoint's Normal TRB length bounded.
const HID_REPORT_BUF = 64;

var mmio: usize = 0;
// Set once the controller is reset, rung up, and Running — the gate for poll()
// (which must not touch the event ring of an absent/failed controller).
var controller_up: bool = false;
var op_base: usize = 0;
var rt_base: usize = 0;
var db_base: usize = 0;
var max_slots: u32 = 0;
var max_ports: u32 = 0;
var context_size: usize = 32; // 32 or 64 bytes (HCCPARAMS1.CSZ)

var dcbaa: [*]volatile u64 = undefined;
// The command ring (driver -> controller) is an ordinary producer ring; the event
// ring (controller -> driver) is consumed via EventRing. Both reuse the shared
// cycle/wrap machinery instead of open-coding it (see Ring / EventRing below).
var cmd: Ring = undefined;
var events: EventRing = undefined;

// xHCI register access goes through the shared MMIO primitives (io/mmio.zig);
// `off` here is an absolute address (callers fold in the base/capability offset).
const r32 = mmioz.read32;
const w32 = mmioz.write32;
const w64 = mmioz.write64;

// Low-memory DMA invariant: every controller-visible physical address must stay
// below 4 GiB. The 64-bit MMIO pointer registers (CRCR/DCBAAP/ERSTBA/ERDP) are
// programmed with mmioz.write64, a non-atomic lo-then-hi pair that is only safe
// while the high dword is constant (zero) — a >4 GiB frame would let the split
// write present a torn pointer to the controller. pmm.allocContiguousDma owns
// the assert (one home for the DMA rail — see pmm.DMA_LIMIT).

/// Allocate `bytes` of zeroed, physically-contiguous, controller-visible DMA
/// memory (rounded up to whole frames). Returns the physical address, or 0 on
/// allocation failure; the DMA <4 GiB rail is enforced inside the allocator.
fn dmaAlloc(bytes: usize) usize {
    const frames = (bytes + pmm.FRAME_SIZE - 1) / pmm.FRAME_SIZE;
    const p = pmm.allocContiguousDma(frames) orelse {
        log("xhci: DMA alloc failed\n");
        return 0;
    };
    @memset(@as([*]u8, @ptrFromInt(p))[0 .. frames * pmm.FRAME_SIZE], 0);
    return p;
}

// Bound for register-status waits (wait.until polls once per pause iteration). A
// few million pause-iterations is a generous timeout for a register bit to settle.
// Real wall-clock delays (enumeration timing) use timer.sleep, not this.
const REG_WAIT_SPINS: u32 = 5_000_000;

// Bound for a single event-ring poll (wait.until spins). Much shorter than
// REG_WAIT_SPINS: an expected event should post within this window on both QEMU
// and real HW, and callers (submitCommand/awaitXfer) retry this window several
// times, so it is a per-attempt budget, not a total timeout.
const EVENT_POLL_SPINS: u32 = 200_000;

// How many EVENT_POLL_SPINS windows submitCommand waits for its Command
// Completion Event before giving up. Foreign events (other slots' completions)
// don't consume the budget; only empty windows do.
const CMD_COMPLETION_TRIES: u32 = 50;

// Hard ceiling on ONE command's completion wait. Bounds the cost of a device the
// driver cannot address (see submitCommand): without it, a handful of undriveable
// devices retried for the whole boot and enumeration never finished.
const CMD_WALL_MS: u64 = 500;

// How many empty EVENT_POLL_SPINS windows awaitXfer tolerates before declaring a
// control/interrupt transfer timed out. Foreign-slot events are drained without
// spending budget, so this only trips when nothing is posted at all.
const XFER_TIMEOUT_TRIES: u32 = 64;
// Wall-clock ceiling on ONE transfer wait, independent of the timeout counter.
// The counter only advances on EMPTY event windows — foreign events (live HID
// reports, port changes) are dispatched without counting. So once HID polling has
// started, a transfer that will never complete keeps awaitXfer spinning FOREVER on
// the stream of mouse/keyboard reports: the counter sits at 0 while the machine is
// mute and deaf, out of reach of even OP_REBOOT. A healthy transfer completes in
// single-digit ms; 2 s is generous to real devices and still bounds the wait.
const XFER_WALL_MS: u64 = 2_000;

// The same ceiling for a BULK transfer (awaitBulk). Longer than XFER_WALL_MS
// because flash is allowed to be slow: a 32 KiB write can land behind the stick's
// own garbage collection. 5 s is far beyond any healthy transfer and still bounds
// the class — a stalled pipe must not be able to hold usb_lock forever.
const BULK_WALL_MS: u64 = 5_000;

// USB enumeration timing (milliseconds), via the real PIT timebase (timer.sleep).
// These are spec MINIMUMS (USB 2.0 §7.1.7 / §9.2.6, mirrored from Linux); on real
// hardware they must actually elapse. An unanchored CPU spin finishes in
// microseconds on fast silicon and leaves the device not yet ready — the dominant
// "works in QEMU, dead on real HW" cause.
const T_PORT_POWER_GOOD_MS: u64 = 20; // VBUS on -> port can report connect
// Controller-run -> CCS-valid settle before the root-port scan (real silicon;
// Linux's hub bring-up absorbs this in khubd latency). 100 ms and TSC-timed —
// see the call site.
const CONNECT_SETTLE_US: u64 = 100_000;
const T_SET_ADDRESS_MS: u64 = 10; // SET_ADDRESS recovery (≥2) before descriptors

// ---- Enumeration robustness: Linux hub.c retry tiers ----
// Constants keep Linux's names so the two diff.
// Connect debounce is the stability window in debounce.zig (hub_port_debounce).
//
// The port-reset policy (hub.PORT_RESET_TRIES / hub.HUB_*_RESET_TIME_MS /
// hub.T_RESET_RECOVERY_MS) lives in hub.zig — one policy for root ports
// (resetPortOnly below) and hub downstream ports (hub.Hub.portReset).
//
// Whole-device init (hub_port_connect): PORT_INIT_TRIES full enumeration
// attempts, each from a fresh port reset; the failed attempt's slot is Disabled
// and its DMA buffers are REUSED (there is no DMA free). At the halfway attempt
// the port is VBUS power-cycled — Linux's remedy for a device wedged deeper
// than a reset reaches.
const PORT_INIT_TRIES: u32 = 4;
//
// In-attempt retries (hub_port_init): descriptor reads and Address Device.
// Address Device subsumes SET_ADDRESS (xHCI issues it for us); Linux uses
// SET_ADDRESS_TRIES=2 with 200ms between — we keep 3 tries (observed flake on
// the target board needed >1) at Linux's 200ms spacing.
const GET_DESCRIPTOR_TRIES: u32 = 2;
const T_DESC_RETRY_MS: u64 = 100; // between descriptor-read attempts
const ADDRESS_DEVICE_TRIES: u32 = 3;
const T_ADDRESS_RETRY_MS: u64 = 200; // settle before re-issuing Address Device

// Status predicates for wait.until (ctx = {} — they read module-global op_base).
/// True once the controller has left the Halted state (USBSTS.HCH clear) — the
/// completion condition for "controller started running".
fn notHalted(_: void) bool {
    return (r32(op_base + OP_USBSTS) & USBSTS_HCH) == 0;
}
/// True once the controller has Halted (USBSTS.HCH set) — the completion
/// condition for "controller stopped before reset".
fn isHalted(_: void) bool {
    return (r32(op_base + OP_USBSTS) & USBSTS_HCH) != 0;
}
/// True once Controller-Not-Ready (USBSTS.CNR) clears — the controller is safe
/// to touch. Reads as busy immediately after power-on/reset on real HW.
fn cnrClear(_: void) bool {
    return (r32(op_base + OP_USBSTS) & USBSTS_CNR) == 0;
}
/// True once a host-controller reset has finished: HCRST self-cleared AND CNR
/// dropped, i.e. the controller is reset and ready for re-init.
fn resetDone(_: void) bool {
    return (r32(op_base + OP_USBCMD) & USBCMD_HCRST) == 0 and
        (r32(op_base + OP_USBSTS) & USBSTS_CNR) == 0;
}

/// Find and bring up the xHCI controller. Returns false if none present.
pub fn init() bool {
    counter.register(&cnt_kbd_reports);
    counter.register(&cnt_mouse_drops);
    counter.register(&cnt_mouse_reports);
    counter.register(&cnt_hid_queued);
    counter.register(&cnt_hid_orphan);
    counter.register(&cnt_hid_badcc);
    counter.register(&cnt_hid_stopped_echo);
    counter.register(&cnt_hid_rekick);
    counter.register(&cnt_hid_resurrect);
    counter.register(&cnt_hid_resurrect_fail);
    counter.register(&cnt_ev_consumed);
    counter.register(&cnt_ev_xfer);
    counter.register(&cnt_ev_psc);
    counter.register(&cnt_ev_cmd);
    counter.register(&cnt_ev_other);
    const dev = pci.findClass(0x0C, 0x03, 0x30) orelse {
        log("xhci: no controller\n");
        dbg.set(.usb, "usb.stopped_at", "no xHCI controller on PCI");
        return false;
    };
    dbg.setBool(.usb, "usb.controller", true);
    dev.enableBusMaster();
    dbg.setBool(.usb, "usb.intel_handover", dev.vendor == PCI_VENDOR_INTEL);
    if (dev.vendor == PCI_VENDOR_INTEL) intelPortHandover(dev);
    mmio = @intCast(pci.bar64(dev, 0));
    logx("xhci: found, BAR0=", mmio);
    dbg.setHex(.usb, "usb.bar0", mmio);
    if (mmio == 0) {
        dbg.set(.usb, "usb.stopped_at", "BAR0 is 0");
        return false;
    }

    const caplength = r32(mmio + CAP_CAPLENGTH) & 0xFF;
    op_base = mmio + caplength;
    rt_base = mmio + (r32(mmio + CAP_RTSOFF) & ~@as(u32, 0x1F));
    db_base = mmio + (r32(mmio + CAP_DBOFF) & ~@as(u32, 0x3));

    const hcs1 = r32(mmio + CAP_HCSPARAMS1);
    max_slots = hcs1 & 0xFF;
    max_ports = (hcs1 >> 24) & 0xFF;
    const hcc1 = r32(mmio + CAP_HCCPARAMS1);
    context_size = if ((hcc1 & (1 << 2)) != 0) 64 else 32;
    logx("xhci: max_slots=", max_slots);
    logx("xhci: max_ports=", max_ports);
    dbg.setNum(.usb, "usb.max_slots", max_slots);
    dbg.setNum(.usb, "usb.max_ports", max_ports);

    if (!reset()) {
        dbg.set(.usb, "usb.stopped_at", "controller reset failed");
        return false;
    }
    if (!setupRings()) {
        dbg.set(.usb, "usb.stopped_at", "setupRings failed");
        return false;
    }
    dbg.setBool(.usb, "usb.rings_setup", true);
    dbg.setBool(.usb, "usb.interrupter_en", true); // IMAN.IE set in setupRings

    // Run the controller. INTE (host interrupt enable) is deliberately NOT set:
    // we poll the event ring and have no xHCI interrupt handler, so letting the
    // controller assert its level-triggered INTx would storm the CPU forever
    // (IMAN.IP never cleared) and wedge boot on real HW. IMAN.IE alone (set in
    // setupRings) is enough for event-ring writeback.
    w32(op_base + OP_USBCMD, USBCMD_RS);
    if (!wait.until({}, notHalted, wait.noop, REG_WAIT_SPINS, "xhci: controller start (HCH clear)")) {
        log("xhci: failed to start (still halted)\n");
        dbg.set(.usb, "usb.stopped_at", "controller still halted after RS");
        return false;
    }
    log("xhci: running\n");
    dbg.setBool(.usb, "usb.running", true);
    controller_up = true; // poll() may now touch the event ring / ports

    // Connect-detect settle before the port scan. On real silicon CCS takes tens
    // of ms to assert after the controller starts; scanning immediately reads
    // every port as ccs=0 — devices present but all invisible. QEMU asserts CCS
    // instantly, so only real hardware shows this. TSC-based on purpose: the PIT
    // is not yet proven at this point in boot.
    tsc.udelay(CONNECT_SETTLE_US);
    enumerate();
    dbg.setNum(.usb, "usb.devices_enum", ndev);
    if (ndev == 0) dbg.set(.usb, "usb.stopped_at", "0 HID devices enumerated");
    // Only now, with every device enumerated, start interrupt-IN polling for all
    // of them. Doing this during enumeration would let an already-streaming device
    // starve a later device's control transfers on the shared event ring.
    startPolling();
    return true;
}

/// Route an Intel PCH's shared USB2/USB3 ports from the legacy EHCI path over to
/// xHCI. Mirrors Linux `usb_enable_intel_xhci_ports`: enable SuperSpeed on every
/// routable USB3 port, then switch every routable USB2 port's data lines. Without
/// this, a USB keyboard/mouse on a shared port is invisible to xHCI (CCS=0).
fn intelPortHandover(dev: pci.Device) void {
    const usb3_routable = dev.read32(INTEL_USB3PRM);
    dev.write32(INTEL_USB3_PSSEN, usb3_routable);
    logx("xhci: intel USB3 ports enabled=", dev.read32(INTEL_USB3_PSSEN));

    const usb2_routable = dev.read32(INTEL_USB2PRM);
    dev.write32(INTEL_XUSB2PR, usb2_routable);
    logx("xhci: intel USB2 ports switched=", dev.read32(INTEL_XUSB2PR));
}

/// Reset the host controller to a known state: wait ready, stop + halt, assert
/// HCRST, then wait for reset to complete. Returns false if any step times out
/// (xHCI §4.2). Every register touch after this assumes a freshly reset xHC.
fn reset() bool {
    // Wait for controller ready (CNR clear) before touching it.
    if (!wait.until({}, cnrClear, wait.noop, REG_WAIT_SPINS, "xhci: controller ready (CNR clear)")) {
        log("xhci: not ready before reset\n");
        return false;
    }

    // Stop, then wait until halted.
    w32(op_base + OP_USBCMD, 0);
    if (!wait.until({}, isHalted, wait.noop, REG_WAIT_SPINS, "xhci: halt before reset (HCH set)")) {
        log("xhci: failed to halt before reset\n");
        return false;
    }

    // Reset, then wait for HCRST to clear and the controller to be ready again.
    w32(op_base + OP_USBCMD, USBCMD_HCRST);
    if (!wait.until({}, resetDone, wait.noop, REG_WAIT_SPINS, "xhci: reset complete (HCRST + CNR clear)")) {
        log("xhci: reset timeout\n");
        return false;
    }
    log("xhci: reset done\n");
    return true;
}

/// Build every controller-visible data structure and arm the interrupter:
/// DCBAA + scratchpad, command ring (CRCR), event ring + single-segment ERST,
/// and interrupter 0 (ERDP before ERSTBA — see below). Returns false if any DMA
/// allocation fails. Must run on a reset controller before it is set running.
fn setupRings() bool {
    // Device Context Base Address Array.
    const dcbaa_phys = dmaAlloc((max_slots + 1) * 8);
    if (dcbaa_phys == 0) return false;
    dcbaa = @ptrFromInt(dcbaa_phys);

    // Scratchpad buffers, if the controller needs any.
    const hcs2 = r32(mmio + CAP_HCSPARAMS2);
    const max_sp = ((hcs2 >> 27) & 0x1F) | (((hcs2 >> 21) & 0x1F) << 5);
    if (max_sp > 0) {
        const sp_array = dmaAlloc(max_sp * 8);
        if (sp_array == 0) return false;
        const arr: [*]volatile u64 = @ptrFromInt(sp_array);
        var i: u32 = 0;
        while (i < max_sp) : (i += 1) {
            const buf = dmaAlloc(pmm.FRAME_SIZE);
            if (buf == 0) return false;
            arr[i] = buf;
        }
        dcbaa[0] = sp_array;
        logx("xhci: scratchpad buffers=", max_sp);
    }
    w32(op_base + OP_CONFIG, max_slots);
    w64(op_base + OP_DCBAAP, dcbaa_phys);

    // Command ring (producer ring with the standard link-TRB wrap).
    cmd = Ring.create(CMD_RING_TRBS);
    if (cmd.phys == 0) return false;
    w64(op_base + OP_CRCR, cmd.phys | 1); // RCS = 1

    // Event ring + ERST (single segment).
    events = EventRing.create(EVENT_RING_TRBS);
    if (events.phys == 0) return false;
    const erst_phys = dmaAlloc(16);
    if (erst_phys == 0) return false;
    const erst: [*]volatile u32 = @ptrFromInt(erst_phys);
    erst[0] = @truncate(events.phys);
    erst[1] = @truncate(events.phys >> 32);
    erst[2] = EVENT_RING_TRBS;
    erst[3] = 0;
    // Interrupter 0 runtime registers (rt_base + 0x20). ORDER MATTERS: ERDP must be
    // initialized BEFORE ERSTBA. Writing ERSTBA is what arms the interrupter — once
    // it lands the controller may begin posting events relative to ERDP, so ERDP has
    // to already point at the ring (xHCI §5.5.2.3.2; Linux xhci_add_interrupter
    // programs ERDP then ERSTBA last). Writing ERSTBA first could latch a stale ERDP.
    w32(rt_base + RT_ERSTSZ, 1); // ERSTSZ = 1 segment
    w64(rt_base + RT_ERDP, events.phys); // ERDP first
    w64(rt_base + RT_ERSTBA, erst_phys); // ERSTBA last — arms the interrupter

    // Enable interrupter 0 (IMAN.IE). Although the event ring is polled (no IRQ
    // handler), real Intel xHCI only posts events to the ring when the
    // interrupter is enabled — leaving it disabled means every command and HID
    // transfer times out and nothing enumerates. QEMU posts events regardless.
    // IMOD=0: no moderation.
    w32(rt_base + IMAN, (r32(rt_base + IMAN) & ~@as(u32, IMAN_IP)) | IMAN_IE); // set IE, don't clear a pending IP
    w32(rt_base + IMOD, 0);
    log("xhci: rings set up\n");
    return true;
}

// ---- event ring + commands ----
/// Ring a doorbell to tell the controller a ring has new work. `slot` selects
/// the doorbell (0 = command ring; N = device slot N); `target` is the DB
/// target (0 for the command ring, the endpoint DCI for a device). xHCI §5.6.
fn ringDoorbell(slot: u32, target: u32) void {
    w32(db_base + slot * 4, target);
}

// Result cell for the bounded event-ring wait: poll fills `trb` when an event is
// dequeued so wait.until's bool return can carry it back out (Zig has no
// closures).
const EventWait = struct { trb: trb.Trb = .{}, got: bool = false };

/// wait.until predicate: dequeue one event if the ring has one, stashing it in
/// `w` so the bool return can carry the TRB back out. True once an event arrives.
fn pollEvent(w: *EventWait) bool {
    if (nextEventReady()) |ev| {
        w.trb = ev;
        w.got = true;
        return true;
    }
    return false;
}

/// Poll the event ring for the next event TRB (any type), up to `timeout` spins.
/// Returns a copy (dequeue pointer + ERDP advanced by nextEventReady) or null.
fn nextEvent(timeout: u32) ?trb.Trb {
    var w = EventWait{};
    // wait.poll, NOT wait.until: an empty window here is not an error, it is what
    // waiting looks like. Every caller loops on this under its OWN wall-clock deadline
    // and treats null as "not yet". wait.until logged each one as `wait timeout: xhci:
    // event ring` — 208 of them for one slow device's config-descriptor read that
    // SUCCEEDED, 1044 across a boot, drowning the metered trace. The real timeout is
    // traced once, by the caller that owns the deadline (see wait.poll).
    if (wait.poll(&w, pollEvent, timeout)) return w.trb;
    // No event this window. Service the host on the way out so a device that is slow —
    // or never completing — leaves the machine observable and, above all, interruptible
    // by OP_REBOOT.
    serviceHost();
    return null;
}

/// True while a command is on the command ring awaiting its Command Completion Event.
///
/// A command's completion is matched by the TRB address in the event, so a SECOND
/// command submitted while the first is in flight will happily consume events looking
/// for its own — discarding the outer command's completion on the way past. The path
/// that does this is dispatchForeign -> handleHidEvent -> recoverEndpoint (two commands
/// of its own), reached from inside the outer command's own wait loop. The outer command
/// then waits forever for an event that has already been thrown away, and reports
/// "Address Device timeout, three attempts, no completion ever" — which is what a
/// device enumerating alongside a mouse that is already streaming reports hits.
///
/// So: while a command is in flight, endpoint recovery is DEFERRED. The endpoint stays
/// halted for a few milliseconds longer; the alternative is losing a completion, and a
/// lost completion loses the device.
var cmd_in_flight: bool = false;

/// Enqueue a command TRB on the command ring, ring the doorbell, and wait for its
/// Command Completion Event. Returns the event (completion code in status>>24, slot id
/// in control>>24), or null if no completion arrived within the budget.
///
/// SEAM (pub with cmdOk): command submission for the class glue split out of
/// this driver — hub.zig today, via hub_vtable — so widening it is a visible
/// contract change, not an incidental pub.
pub fn submitCommand(param: u64, control: u32) ?trb.Trb {
    // The Command Completion Event carries, in its `param`, a pointer to the command
    // TRB that completed. Capture this command's TRB address (the current enqueue
    // slot, before push advances it) so we accept only the completion for THIS
    // command — a stale or aborted completion left in the ring would otherwise bind
    // the wrong completion code / slot id (e.g. a bogus slot from Enable Slot),
    // corrupting device state. Matches Linux handle_cmd_completion. xHCI §4.6.1.
    last_cc = CC_TIMEOUT; // overwritten by cmdOk once a completion arrives; a null
    // return (no event within the budget) therefore leaves the timeout marker.
    const cmd_trb_phys: u64 = cmd.phys + cmd.enqueue * @sizeOf(trb.Trb);
    cmd.push(param, 0, control);
    ringDoorbell(0, 0);
    // This command now owns the event stream until its completion arrives: no nested
    // command may run and consume it (see cmd_in_flight).
    cmd_in_flight = true;
    defer cmd_in_flight = false;
    // WALL CLOCK, not just a spin budget. Spending the full CMD_COMPLETION_TRIES on
    // silence is correct (a slow device must not be abandoned a moment before its
    // completion lands), but 50 windows x EVENT_POLL_SPINS is a very long time to burn
    // per failure — and real machines carry devices kudos cannot drive (an
    // 8-interface ASUS audio card) whose Address Device NEVER completes. With no
    // ceiling those failures eat the whole boot: enumeration keeps retrying, so
    // xhci.init() never returns and /usbdisk is never mounted. A command that has
    // not completed in half a second is not going to.
    //
    // TSC, not timer.millis(): this can be reached with interrupts masked, and a
    // deadline measured on a tick that cannot advance never expires.
    const cmd_deadline = tsc.rdtsc() +% tsc.msTicks(CMD_WALL_MS);
    var tries: u32 = 0;
    while (tries < CMD_COMPLETION_TRIES) : (tries += 1) {
        // KEEP THE MACHINE REACHABLE WHILE WE WAIT. awaitXfer and awaitBulk both do
        // this; submitCommand was the last wait loop that did not, and that gap is
        // what makes an undriveable device look like a wedge from the outside: the
        // ASUS audio card's Address Device never completes, so each attempt burns the
        // full CMD_WALL_MS with the network UNSERVICED — and with PORT_INIT_TRIES
        // attempts per bring-up, plus the port-change retries, kudos goes deaf for
        // seconds at a stretch. The trace bus stops draining, remote-control requests go
        // unanswered inside their retry budget, and a perfectly healthy machine reads as
        // hung — because the ONLY window we have onto it is the network, and USB is
        // holding the CPU. Service the host while we wait.
        serviceHost();
        // AN EMPTY POLL WINDOW IS NOT A FAILED COMMAND. It spends budget; we go round
        // again. Returning on the first empty window instead would mean the retry budget
        // is never actually spent on SILENCE — only on foreign events — and silence is
        // the normal case: a real device's Address Device can take longer to complete
        // than one poll window is wide.
        //
        // Walk away a moment early and the device never enumerates, while the controller
        // insists it is healthy and correct — running, no errors, event posted, command
        // ring live. Every register says the completion is there. Nobody is listening.
        if (tsc.rdtsc() >= cmd_deadline) {
            log("xhci: command wall-clock ceiling — no completion\n");
            return null;
        }
        const ev = nextEvent(EVENT_POLL_SPINS) orelse continue;
        if (trbType(ev) == TRB_COMMAND_COMPLETION and ev.param == cmd_trb_phys) return ev;
        // A live HID report / port change arriving mid-command (post-boot
        // re-enumeration): dispatch it — dropping a report without a re-queue
        // silently stops that device's polling forever. Its nested recovery
        // may stamp last_cc for ANOTHER device — restore ours (review M-U6).
        const saved_cc = last_cc;
        dispatchForeign(ev);
        last_cc = saved_cc;
    }
    return null;
}

// The completion codes and the verdicts drawn from them live in xhci_cc.zig — pure
// and host-tested, because "Short Packet is a success" is the single biggest
// QEMU-vs-real-hardware divergence in this driver and a regression in it is
// invisible under emulation. These are the thin trb.Trb-shaped wrappers over it; the
// `last_cc` stamp is the one piece of driver state and stays here.
const CC_SUCCESS = xhci_cc.CC_SUCCESS;
const CC_SHORT_PACKET = xhci_cc.CC_SHORT_PACKET;
const CC_STALL = xhci_cc.CC_STALL;

/// Completion code of an event TRB (status bits 31:24).
fn completionCode(ev: trb.Trb) u32 {
    return xhci_cc.completionCode(ev.status);
}

/// A command completion that returned exactly Success.
///
/// SEAM (pub with submitCommand): the completion verdict for the split-out
/// class glue (hub.zig via hub_vtable); stamps last_cc for the diag record
/// either way.
pub fn cmdOk(ev: trb.Trb) bool {
    const cc = completionCode(ev);
    last_cc = cc; // stamp for the drop record even when the command failed
    return xhci_cc.cmdOk(cc);
}

/// A transfer completion that delivered valid data (Success or Short Packet).
fn xferOk(ev: trb.Trb) bool {
    return xhci_cc.xferOk(completionCode(ev));
}

/// The event is a benign "Stopped" echo of a Stop Endpoint / dequeue move — no
/// data, no fault, no recovery (recovering on it re-stops the endpoint forever).
fn xferStopped(ev: trb.Trb) bool {
    return xhci_cc.xferStopped(completionCode(ev));
}

/// The Endpoint State (xHCI §6.2.3 endpoint context DW0 bits 2:0) from the OUTPUT
/// device context — the controller's live verdict for this endpoint. A DMA read,
/// so volatile. 0 disabled, 1 running, 2 halted, 3 stopped, 4 error.
fn epState(d: *const Device, dci: u32) u32 {
    if (d.dctx == 0) return 0xF;
    const dw0: *volatile u32 = @ptrFromInt(d.dctx + xhci_ctx.ctxOffset(context_size, dci, 0));
    return dw0.* & 0x7;
}
fn epStateName(s: u32) []const u8 {
    return switch (s) {
        0 => "disabled",
        1 => "running",
        2 => "halted",
        3 => "stopped",
        4 => "error",
        else => "?",
    };
}

/// Recover a HALTED endpoint (slot `slot`, device-context index `dci`, transfer
/// ring `ring`) so it runs TRBs again. Mirrors Linux
/// `xhci_handle_halted_endpoint`: (1) Reset Endpoint command clears the Halted
/// state and data toggle; (2) Set TR Dequeue Pointer command re-anchors the
/// endpoint's ring dequeue at its current enqueue position, carrying that
/// ring's current cycle as the Dequeue Cycle State (DCS) so the controller
/// resumes on the right cycle.
/// Both go on the command ring via submitCommand and complete via Command
/// Completion Events. `dci` sits in control bits 20:16 (the DCI is EP index + 1,
/// EP0 = 1); `slot` in bits 31:24. Returns false if either command fails or times
/// out — the caller then leaves the endpoint un-re-queued rather than ringing a
/// doorbell that would do nothing on a still-halted endpoint.
fn recoverEndpoint(slot: u32, dci: u32, ring: *Ring) bool {
    return recoverEndpointFrom(.halted, slot, dci, ring);
}

/// Which state the endpoint is being recovered FROM — it decides the first
/// command, because the controller rejects the wrong one with a Context State
/// Error: Reset Endpoint is only legal on a HALTED endpoint (a transfer error
/// halted it); a RUNNING endpoint that has gone silent (the resurrect path —
/// doorbells ignored, no events) must be Stopped first instead.
const EpRecoverFrom = enum { halted, running };

fn recoverEndpointFrom(from: EpRecoverFrom, slot: u32, dci: u32, ring: *Ring) bool {
    // (1) Reset (Halted; no TRB_TSP => hard reset, Linux EP_HARD_RESET) or
    // Stop (Running) — see EpRecoverFrom.
    const first_type: u32 = switch (from) {
        .halted => TRB_RESET_ENDPOINT,
        .running => TRB_STOP_ENDPOINT,
    };
    const reset_ev = submitCommand(0, (first_type << 10) | (dci << 16) | (slot << 24)) orelse return false;
    if (!cmdOk(reset_ev)) return false;

    // (2) Set TR Dequeue Pointer (TRB type 16). param = dequeue phys | DCS (bit 0);
    // point it at the ring's current enqueue slot with the ring's current cycle as
    // DCS, so the controller resumes exactly where the caller's re-queue will push.
    const deq: u64 = ring.phys + ring.enqueue * @sizeOf(trb.Trb);
    const dcs: u64 = if (ring.cycle != 0) EP_DCS else 0;
    const set_deq_ev = submitCommand(deq | dcs, (TRB_SET_TR_DEQUEUE << 10) | (dci << 16) | (slot << 24)) orelse return false;
    return cmdOk(set_deq_ev);
}

// TRB type field (control bits 15:10). Command/transfer types built into rings
// and event types delivered by the controller — one named value each so no type
// is open-coded as a bare literal.
const TRB_ENABLE_SLOT = 9;
const TRB_ADDRESS_DEVICE = 11;
const TRB_EVALUATE_CONTEXT = 13;
const TRB_RESET_ENDPOINT = 14; // clear a Halted endpoint (xHCI §4.6.8)
const TRB_STOP_ENDPOINT = 15; // stop a Running endpoint's transfers (xHCI §4.6.9)
const TRB_SET_TR_DEQUEUE = 16; // move an endpoint ring's dequeue ptr + DCS (xHCI §4.6.10)
const TRB_LINK = 6;
const TRB_DISABLE_SLOT = 10; // release a slot after a failed init attempt (xHCI §4.6.4)
const TRB_TRANSFER_EVENT = 32;
const TRB_COMMAND_COMPLETION = 33;
const TRB_PORT_STATUS_CHANGE = 34; // PSCE: root-port change bit asserted (xHCI §6.4.2.3)
const TRB_TOGGLE_CYCLE: u32 = 1 << 1; // Link TRB: toggle the ring's cycle state

// Control-transfer TRB stage types (xHCI §6.4.1) and the control-word flag bits
// shared across transfer TRBs. Named once so the control-transfer stages read
// declaratively instead of as bare shifts like `(2 << 10) | (3 << 16) | (1 << 6)`.
const TRB_SETUP_STAGE = 2;
const TRB_DATA_STAGE = 3;
const TRB_STATUS_STAGE = 4;
const EP0_DCI: u32 = 1; // EP0's device-context index (and its doorbell target)
const TRB_TRT_IN: u32 = 3 << 16; // Setup-stage Transfer Type = IN data stage
const TRB_DIR_IN: u32 = 1 << 16; // Data/Status-stage Direction = IN
const TRB_IOC: u32 = 1 << 5; // Interrupt On Completion
const TRB_IDT: u32 = 1 << 6; // Immediate Data (Setup stage carries data inline)
const TRB_ISP: u32 = 1 << 2; // Interrupt on Short Packet (interrupt-IN transfers)
const TRB_CHAIN: u32 = 1 << 4; // this TRB is not the last of its TD (xHCI §6.4.1.1)

// The TRB/context BIT PACKING lives in xhci_ctx.zig — pure and host-tested. The
// context stride in particular (HCCPARAMS1.CSZ: 32 on QEMU, 64 on every real xHC)
// is a divergence emulation cannot show, so it must live where a test can reach it.
const ctrl = xhci_ctx.ctrl;

/// Type field of any TRB (control bits 15:10).
fn trbType(t: trb.Trb) u32 {
    return xhci_ctx.trbType(t.control);
}

/// Write one 32-bit field of a device/input context: DWord `dword` of context slot
/// `idx` within the array at `base`. The 32-vs-64-byte stride (HCCPARAMS1.CSZ) is
/// applied by xhci_ctx.ctxOffset — the single place it lives.
///
/// SEAM (pub with ctxSlotDw0): input-context editing for the split-out class
/// glue (hub.zig via hub_vtable) — the stride stays this driver's fact.
pub fn ctxSet(base: usize, idx: usize, dword: usize, value: u32) void {
    w32(base + xhci_ctx.ctxOffset(context_size, idx, dword), value);
}

const EP_TYPE_CONTROL = xhci_ctx.EP_TYPE_CONTROL;
const EP_TYPE_BULK_OUT = xhci_ctx.EP_TYPE_BULK_OUT;
const EP_TYPE_BULK_IN = xhci_ctx.EP_TYPE_BULK_IN;
const EP_TYPE_INTERRUPT_IN = xhci_ctx.EP_TYPE_INTERRUPT_IN;
const EP_DCS = xhci_ctx.EP_DCS; // Dequeue Cycle State (Set TR Dequeue also carries it)

/// Write a TR Dequeue Pointer (with DCS=1) into endpoint-context DWords
/// `dword_lo` and `dword_lo+1` — the 64-bit physical address split lo/hi. The
/// same lo/hi+DCS pattern is needed for every endpoint ring, so it lives here.
fn ctxSetPtr(base: usize, idx: usize, dword_lo: usize, phys: usize) void {
    ctxSet(base, idx, dword_lo, xhci_ctx.trDequeueLo(phys));
    ctxSet(base, idx, dword_lo + 1, xhci_ctx.trDequeueHi(phys));
}

/// Zero the Input Control Context (the drop/add-flags dwords at index 0) of an
/// input context before a command sets the flags it needs.
fn clearInputControl(input_ctx: usize) void {
    var i: usize = 0;
    while (i < context_size / 4) : (i += 1) ctxSet(input_ctx, 0, i, 0);
}

/// Write Slot Context DW0 (route string | Context Entries | speed, plus any extra
/// bits such as the Hub flag) into an input context. xHCI §6.2.2 Table 6-4.
///
/// SEAM (pub with ctxSet): hub.zig sets the Hub bit through this via hub_vtable.
pub fn ctxSlotDw0(input_ctx: usize, route: u32, ctx_entries: u32, speed: u32, extra: u32) void {
    ctxSet(input_ctx, 1, 0, xhci_ctx.slotDw0(route, ctx_entries, speed, extra));
}

/// Configure an endpoint context at `ep_idx`: DW1 (EP Type | CErr | Max Packet
/// Size) and the TR Dequeue Pointer (DW2/3 with DCS=1). The one place EP0 and the
/// interrupt-IN endpoint share — addressDevice, fixEp0MaxPacket, and setupHid all
/// route through it instead of repeating the dword math. xHCI §6.2.3.
fn ctxEp(input_ctx: usize, ep_idx: usize, ep_type: u32, mps: u32, ring_phys: usize) void {
    ctxSet(input_ctx, ep_idx, 1, xhci_ctx.epDw1(ep_type, mps));
    ctxSetPtr(input_ctx, ep_idx, 2, ring_phys);
}

// PORTSC bit definitions, the neutral-write helper, and every PORTSC/
// wPortStatus → verdict decision live in port_fsm.zig (pure, host-tested);
// this driver owns only the register access, sleeps, and retry loops.

/// Outcome of a root-port reset attempt. `speed` is non-zero (the PORTSC speed id)
/// only when the port trained to Enabled/U0; on any drop it is 0 and `result` names
/// the specific reason the port produced no device. `portsc` is the last PORTSC read
/// — the state enumerate() records for the port. Distinguishing the drop reasons is
/// the whole point of the instrumentation build: "no device" vs "connected then
/// bounced" vs "reset never enabled the port" are three different bugs.
const PortResult = struct { speed: u32, portsc: u32, result: []const u8 };

/// Debounce + reset a root-hub port and return its {speed, portsc, result}.
/// Ensures the port is powered, runs the Linux stability-window debounce, then
/// the retried reset. An empty
/// port (no connect, no pending connect-change) returns immediately — a late
/// connect posts a Port Status Change Event that poll() picks up instead.
fn resetPort(port: u32) PortResult {
    const psc = OP_PORTSC + (port - 1) * 0x10;

    // Ensure Port Power; on PPC=1 controllers ports come up unpowered and CCS
    // will never assert until PP is driven. Wait power-on-to-good (real time)
    // before reading connect — too-early reads see CCS=0 and miss the device.
    var v = r32(op_base + psc);
    if ((v & port_fsm.PORTSC_PP) == 0) {
        w32(op_base + psc, port_fsm.portscNeutral(v) | port_fsm.PORTSC_PP);
        timer.sleep(T_PORT_POWER_GOOD_MS);
        v = r32(op_base + psc);
    }
    logPort(port, v);

    // Fast path: nothing connected and no connect-change latched — the port is
    // empty. No waiting: a device that shows up later posts a PSCE.
    if ((v & (port_fsm.PORTSC_CCS | port_fsm.PORTSC_CSC)) == 0) {
        return .{ .speed = 0, .portsc = v, .result = "no connect" };
    }

    // Debounce (Linux hub_port_debounce): the connect bit must hold unchanged
    // for a full stability window; any bounce restarts it (debounce.zig).
    // Breadcrumb BEFORE entering: this loop and the reset below are the only
    // places the scan can dwell, so if the stream ever stops during enumeration,
    // the last port line names the culprit. On real hardware the netdebug stream
    // is the only diagnostic available here.
    logx("xhci: port debounce enter, port=", port);
    var db = debounce.Debounce{};
    while (true) {
        v = r32(op_base + psc);
        const change = (v & port_fsm.PORTSC_CSC) != 0;
        if (change) w32(op_base + psc, port_fsm.portscNeutral(v) | port_fsm.PORTSC_CSC);
        switch (db.feed((v & port_fsm.PORTSC_CCS) != 0, change)) {
            .pending => timer.sleep(debounce.STEP_MS),
            .stable_connected => break,
            .stable_empty => return .{ .speed = 0, .portsc = v, .result = "bounced away" },
            .timeout => return .{ .speed = 0, .portsc = v, .result = "connect never stabilized" },
        }
    }

    return resetPortOnly(port);
}

/// The reset half of resetPort, callable on its own so a failed init attempt can
/// re-reset its port without re-debouncing (Linux hub_port_connect resets per
/// attempt but debounces once). Up to hub.PORT_RESET_TRIES attempts, each polled
/// to completion for hub.HUB_RESET_TIMEOUT_MS with the escalating step; a SuperSpeed
/// link wedged in SS.Inactive/Compliance escalates to a WARM reset. Completion
/// requires Enabled + U0 + reset clear + still connected (covers link
/// retraining). Success is followed by the TRSTRCY recovery delay.
fn resetPortOnly(port: u32) PortResult {
    logx("xhci: port reset enter, port=", port); // dwell breadcrumb (see debounce)
    const psc = OP_PORTSC + (port - 1) * 0x10;
    var v: u32 = r32(op_base + psc);
    var attempt: u32 = 0;
    while (attempt < hub.PORT_RESET_TRIES) : (attempt += 1) {
        // Escalate to a warm reset when the SS link is beyond a hot reset's
        // reach (Linux hub_port_warm_reset_required; port_fsm.rootResetKind).
        const warm = port_fsm.rootResetKind(v) == .warm;
        w32(op_base + psc, port_fsm.portscNeutral(v) | (if (warm) port_fsm.PORTSC_WPR else @as(u32, port_fsm.PORTSC_PR)));

        // First attempt starts on the short step and escalates after two misses
        // (Linux hub_port_wait_reset); retries go straight to the long step.
        var step: u64 = if (attempt == 0) hub.HUB_ROOT_RESET_TIME_MS else hub.HUB_LONG_RESET_TIME_MS;
        var waited: u64 = 0;
        var done = false;
        while (waited < hub.HUB_RESET_TIMEOUT_MS) {
            timer.sleep(step);
            waited += step;
            v = r32(op_base + psc);
            if (port_fsm.rootResetComplete(v)) {
                done = true;
                break;
            }
            step = hub.HUB_LONG_RESET_TIME_MS;
        }
        // Acknowledge the change bits this attempt raised (connect/reset/warm-
        // reset) so the port doesn't read as "changed" forever.
        w32(op_base + psc, port_fsm.portscNeutral(v) | port_fsm.PORTSC_CSC | port_fsm.PORTSC_PRC | port_fsm.PORTSC_WRC);
        if (done) {
            // Reset-recovery (TRSTRCY): not addressable until this elapses.
            timer.sleep(hub.T_RESET_RECOVERY_MS);
            return .{ .speed = (v >> 10) & 0xF, .portsc = v, .result = "connected" };
        }
        if (port_fsm.rootResetFail(v) == .vanished) {
            // Device left during reset — abandon, don't retry (Linux -ENOTCONN).
            return .{ .speed = 0, .portsc = v, .result = "vanished during reset" };
        }
        logx2("xhci: port reset retry, port=", port, " attempt=", attempt + 1);
    }
    return .{ .speed = 0, .portsc = v, .result = "reset did not enable port" };
}

/// VBUS power-cycle a root port (Linux hub_port_connect's halfway remedy for a
/// device wedged deeper than a reset reaches): power off, wait twice the
/// power-on-good time, power on, wait it once more.
fn powerCycleRootPort(port: u32) void {
    const a = op_base + OP_PORTSC + (port - 1) * 0x10;
    logx("xhci: power-cycling root port=", port);
    w32(a, port_fsm.portscNeutral(r32(a)) & ~@as(u32, port_fsm.PORTSC_PP));
    timer.sleep(2 * T_PORT_POWER_GOOD_MS);
    w32(a, port_fsm.portscNeutral(r32(a)) | port_fsm.PORTSC_PP);
    timer.sleep(T_PORT_POWER_GOOD_MS);
}

// The speed → EP0 max-packet table lives in port_fsm.zig (pure, host-tested):
// port_fsm.maxPacketForSpeed. It is a fact about real silicon — SuperSpeedPlus EP0
// is 512, and a port that falls through to the 8-byte default babbles — so it must
// live where a test can reach it, not in this file, which cannot compile on the host.
const maxPacketForSpeed = port_fsm.maxPacketForSpeed;

const Ring = struct {
    trbs: [*]volatile trb.Trb,
    phys: usize,
    size: usize,
    enqueue: usize,
    cycle: u32,

    /// Allocate a `trbs`-entry producer ring with its last slot pre-wired as a
    /// Link TRB back to the ring head (Toggle Cycle set), so `push` wraps
    /// automatically. Starts at cycle 1 (matching the controller's initial RCS).
    fn create(trbs: usize) Ring {
        const phys = dmaAlloc(trbs * @sizeOf(trb.Trb));
        // Alloc failure must return BEFORE the Link-TRB store: writing
        // through phys 0 lands in the real-mode IVT/BDA (review M-U2).
        if (phys == 0) return Ring{ .trbs = undefined, .phys = 0, .size = trbs, .enqueue = 0, .cycle = 1 };
        var r = Ring{ .trbs = @ptrFromInt(phys), .phys = phys, .size = trbs, .enqueue = 0, .cycle = 1 };
        r.trbs[trbs - 1].param = phys;
        r.trbs[trbs - 1].control = (TRB_LINK << 10) | TRB_TOGGLE_CYCLE;
        return r;
    }

    /// Return the ring to its freshly-created state (all TRBs zero, Link TRB
    /// re-wired, enqueue at head, cycle 1) WITHOUT re-allocating, so a failed
    /// init attempt can reuse the same DMA (there is no DMA free path; reuse,
    /// never re-allocate).
    /// Only valid while no controller endpoint is armed on the ring (the
    /// caller has Disabled the slot / not yet addressed it).
    fn reset(self: *Ring) void {
        var i: usize = 0;
        while (i < self.size) : (i += 1) self.trbs[i] = .{};
        self.trbs[self.size - 1].param = self.phys;
        self.trbs[self.size - 1].control = (TRB_LINK << 10) | TRB_TOGGLE_CYCLE;
        self.enqueue = 0;
        self.cycle = 1;
    }

    /// Enqueue one TRB, stamping the ring's current cycle bit (bit 0) into the
    /// control word so callers never set it themselves. On reaching the slot
    /// before the Link TRB, refresh the Link's cycle, wrap to head, and flip
    /// the ring cycle — the standard xHCI producer-ring advance (§4.9.2).
    fn push(self: *Ring, param: u64, status: u32, control: u32) void {
        const i = self.enqueue;
        self.trbs[i].param = param;
        self.trbs[i].status = status;
        self.trbs[i].control = (control & ~@as(u32, 1)) | self.cycle;
        self.enqueue += 1;
        if (self.enqueue == self.size - 1) {
            // The Link TRB the controller traverses to wrap must carry CHAIN
            // when the TRB just written is mid-TD, else a chained bulk TD that
            // straddles the ring boundary is silently split (xHCI §4.11.5.1).
            // The rule lives in trb.linkControl, host-tested; small files stay
            // under one ring lap and never hit it.
            self.trbs[self.size - 1].control = trb.linkControl(self.cycle, control);
            self.enqueue = 0;
            self.cycle ^= 1;
        }
    }
};

/// The controller -> driver event ring (a single ERST segment). Unlike a command
/// ring it has no link TRB: the driver tracks a dequeue index + expected cycle
/// state and wraps at the end. `next()` returns the next event TRB once its cycle
/// bit matches, advancing the dequeue pointer and writing it back to ERDP.
const EventRing = struct {
    trbs: [*]volatile trb.Trb,
    phys: usize,
    size: usize,
    dequeue: usize,
    cycle: u32,

    /// Allocate a `trbs`-entry event ring (single ERST segment, no Link TRB).
    /// Starts at dequeue 0, expected cycle 1 — the controller fills slot 0
    /// first with cycle 1 (xHCI §4.9.4).
    fn create(trbs: usize) EventRing {
        const phys = dmaAlloc(trbs * @sizeOf(trb.Trb));
        // Same guard as Ring.create, and for a worse reason. With phys == 0 we
        // would publish a NULL ERDP/ERSTBA to the controller, which then DMAs
        // every event over physical 0 — the real-mode IVT/BDA. `phys == 0` is the
        // caller's signal to abort init; `trbs` is left undefined so a missed
        // check faults loudly rather than reading the IVT as a cycle bit.
        if (phys == 0) return .{ .trbs = undefined, .phys = 0, .size = trbs, .dequeue = 0, .cycle = 1 };
        return .{ .trbs = @ptrFromInt(phys), .phys = phys, .size = trbs, .dequeue = 0, .cycle = 1 };
    }

    /// Consume the next event TRB if the producer has filled it (its cycle bit
    /// matches ours). Returns a copy, advances the dequeue index (wrapping and
    /// flipping expected cycle at the end), and writes the new position back to
    /// ERDP with EHB so the controller may reuse the slot. Null if no event yet.
    fn next(self: *EventRing) ?trb.Trb {
        const e = &self.trbs[self.dequeue];
        const c = e.control;
        if ((c & 1) != self.cycle) return null; // producer hasn't filled this slot
        // Read barrier AFTER the cycle-bit check, BEFORE consuming the event or
        // any DMA buffer the transfer filled. The controller writes the data
        // payload, THEN posts this event (PCIe producer ordering). This lfence
        // forbids the CPU/compiler from hoisting a later descriptor-buffer read
        // ahead of the cycle-bit load — without it a control transfer's caller
        // could read descbuf while it still holds the pre-transfer @memset 0
        // (observed on real HW: a hub descriptor read nports=0 then 4 in the same
        // function). Mirrors Linux xhci-ring.c dma_rmb() after the cycle check.
        asm volatile ("lfence" ::: .{ .memory = true });
        const copy = trb.Trb{ .param = e.param, .status = e.status, .control = c };
        cnt_ev_consumed.inc();
        switch (trbType(copy)) {
            TRB_TRANSFER_EVENT => cnt_ev_xfer.inc(),
            TRB_PORT_STATUS_CHANGE => cnt_ev_psc.inc(),
            TRB_COMMAND_COMPLETION => cnt_ev_cmd.inc(),
            else => cnt_ev_other.inc(),
        }
        self.dequeue += 1;
        if (self.dequeue == self.size) {
            self.dequeue = 0;
            self.cycle ^= 1;
        }
        // Advance ERDP (with EHB write-back) so the controller can reuse consumed slots.
        w64(rt_base + RT_ERDP, (self.phys + self.dequeue * @sizeOf(trb.Trb)) | ERDP_EHB);
        return copy;
    }
};

const TRB_NORMAL = 1;

const keyboard = @import("../input/keyboard.zig");
const imouse = @import("imouse");

// A device's place in the topology is hub.Topo — the topology IS the hub tree,
// so the type lives with the hub class (hub.zig), below this driver.

/// The interrupt-IN endpoint + report buffer for a configured HID device.
/// The device kind and report layout are hid_report.zig's (pure, host-tested)
/// descriptor-parse products.
const Hid = struct {
    kind: hid_report.Kind,
    ring: Ring,
    dci: u32, // device context index of the interrupt-IN endpoint
    report: usize, // DMA buffer the endpoint writes reports into
    mps: u32, // endpoint max packet size
    last_keys: [6]u8 = .{0} ** 6, // previous keyboard report, for the press/release diff
    last_mods: u8 = 0, // previous modifier bitmap, for the modifier edges
    layout: hid_report.MouseLayout = .{}, // mouse report field offsets (boot layout default)
    // Per-endpoint recovery state (a composite device drives two endpoints — a
    // keyboard and a mouse — and each falls silent, halts, and self-heals on its
    // own, so this cannot be shared per-device). See handleHidEvent / poll().
    seen_report: bool = false, // has delivered at least one genuine report
    recover_pending: bool = false, // a failed completion is waiting for a free command ring
    rekicks_since_event: u32 = 0, // ineffective doorbell re-kicks since the last event
    resurrected: bool = false, // one resurrect per silence episode
    last_event_ms: u64 = 0, // when this endpoint last produced an event
};

/// Size of each device's `descbuf` DMA scratch buffer (control-IN destination
/// for descriptors). Single source of truth: the alloc, the zero-on-read clamp,
/// and the largest control-IN length (the report descriptor) all use it.
const DESCBUF_SIZE: usize = 256;

/// The most HID interrupt endpoints one device may drive at once. A composite
/// device presents up to three the driver cares about — a boot pointer plus TWO
/// boot keyboards (a combo board's 6KRO and NKRO/consumer interfaces, either of
/// which may be the one that actually streams key presses) — and each is bound to
/// its own endpoint so the whole device works, mirroring Linux usbhid (which
/// claims every HID interface, not one per device).
const MAX_DEV_HID: usize = 3;

/// One enumerated USB device. Every device (hub or HID) is addressed via its
/// slot + EP0; HID devices additionally carry `hid` and are kept in devs[] for
/// polling, while hubs are transient — used only to reach the devices behind
/// them.
const Device = struct {
    // Slot / addressing.
    slot: u32 = 0,
    ep0: Ring = undefined,
    input_ctx: usize = 0,
    dctx: usize = 0, // output device context (owned so Disable Slot can recycle it)
    descbuf: usize = 0,
    speed: u32 = 0,
    topo: hub.Topo = .{},
    // Hub role: this hub's power-on-to-good delay (bPwrOn2PwrGood, floored),
    // needed again when a child init attempt power-cycles its port.
    pwr_on_good_ms: u64 = T_PORT_POWER_GOOD_MS,
    // HID interrupt endpoints. A device may drive up to MAX_DEV_HID of them (a
    // composite keyboard+mouse is driven as both). Each slot's DMA (ring + report
    // buffer) is allocated once by setupHid and REUSED by every later init attempt
    // (no DMA free path); the buffers travel through the recycle pool. Per-endpoint
    // recovery state — seen_report, recover_pending, rekicks, resurrected,
    // last_event_ms — lives IN each Hid, because two endpoints fall silent, halt,
    // and self-heal independently and cannot share one per-device counter.
    hid_rings: [MAX_DEV_HID]?Ring = .{null} ** MAX_DEV_HID,
    hid_reports: [MAX_DEV_HID]usize = .{0} ** MAX_DEV_HID,
    hids: [MAX_DEV_HID]?Hid = .{null} ** MAX_DEV_HID,
    // Mass-storage role (setupMsc): the two bulk pipes + a CBW/CSW staging
    // page. Data phases DMA straight into the caller's (identity-mapped,
    // physically contiguous heap) buffer; only the tiny wrappers stage.
    msc_in_ring: ?Ring = null,
    msc_out_ring: ?Ring = null,
    msc_in_dci: u32 = 0,
    msc_out_dci: u32 = 0,
    // Bulk endpoint max-packet sizes. Needed to compute each TRB's TD Size when a
    // transfer is split across a 64 KiB boundary (trb.tdSize).
    msc_in_mps: u32 = 0,
    msc_out_mps: u32 = 0,
    msc_staging: usize = 0,
    // This device's enumeration attempt number — its `usb.devN` debug-key id,
    // so runtime facts (first reports, transfer errors) land in the SAME dbg
    // group as its enumeration facts.
    dbg_id: usize = 0,
    // How many raw reports have been dumped for this device (first-reports tap).
    reports_dumped: u8 = 0,
};
var devs: [16]Device = undefined; // HID devices kept for polling
var ndev: usize = 0;
// Monotonic count of devices bringUp() was invoked for (connected ports + hub
// children), so each attempt — including one that fails and is never kept in
// devs[] — gets a stable `usb.devN.*` line in the debug record with its outcome.
var attempts: usize = 0;
// The current device's `usb.devN` debug key prefix, so setupHid() (called deep
// in bringUp) can annotate the SAME device's record with a specific drop
// reason. Points at the innermost live bringUp's stack-local prefix buffer
// (saved/restored around recursion into a hub's children).
var cur_pre: []const u8 = "";
// The completion code (event status 31:24) of the most recent command or transfer
// event seen — including failures — so a drop in bringUp() can record the ACTUAL
// xHC verdict (Transaction Error=4, Stall=6, Bandwidth Error=17, …) rather than a
// bare "failed". 0xFF marks "no event at all" (a genuine timeout: nextEvent never
// returned a TRB), which is a different fault from a device that answered with an
// error code. Stamped by cmdOk/awaitXfer at the single point each verdict is read.
const CC_TIMEOUT = xhci_cc.CC_TIMEOUT;
var last_cc: u32 = CC_TIMEOUT;

// ---- Per-device DMA buffer set: allocate once, reuse forever ----
// There is no DMA free path (dmaAlloc is a bump over PMM frames), so a retried
// or removed device must never re-allocate: a failed init attempt reuses the
// same set, and a set whose device is abandoned/unplugged goes to this pool for
// the next bringUp to pop.
const DevBufs = struct { ep0: Ring, input_ctx: usize, dctx: usize, descbuf: usize, hid_rings: [MAX_DEV_HID]?Ring, hid_reports: [MAX_DEV_HID]usize };
var buf_pool: [8]DevBufs = undefined;
var nbuf_pool: usize = 0;

/// Give `d` its DMA buffer set: pop a recycled set (reset + zeroed) or allocate
/// a fresh one. Returns false on allocation failure (recorded by the caller).
fn allocDeviceBufs(d: *Device) bool {
    if (nbuf_pool > 0) {
        nbuf_pool -= 1;
        const b = buf_pool[nbuf_pool];
        d.ep0 = b.ep0;
        d.input_ctx = b.input_ctx;
        d.dctx = b.dctx;
        d.descbuf = b.descbuf;
        d.hid_rings = b.hid_rings;
        d.hid_reports = b.hid_reports;
        resetDeviceBufs(d);
        return true;
    }
    d.ep0 = Ring.create(DEVICE_RING_TRBS);
    if (d.ep0.phys == 0) return false;
    d.input_ctx = dmaAlloc(33 * context_size);
    if (d.input_ctx == 0) return false;
    d.dctx = dmaAlloc(32 * context_size);
    if (d.dctx == 0) return false;
    d.descbuf = dmaAlloc(DESCBUF_SIZE);
    return d.descbuf != 0;
}

/// Scrub `d`'s buffer set back to as-allocated state for the next init attempt:
/// EP0 ring re-armed at cycle 1, both contexts zeroed. Only valid with the slot
/// Disabled (nothing armed on the ring, contexts unowned by the xHC).
fn resetDeviceBufs(d: *Device) void {
    d.ep0.reset();
    for (&d.hid_rings) |*maybe| if (maybe.*) |*hr| hr.reset();
    @memset(@as([*]u8, @ptrFromInt(d.input_ctx))[0 .. 33 * context_size], 0);
    @memset(@as([*]u8, @ptrFromInt(d.dctx))[0 .. 32 * context_size], 0);
}

/// Return `d`'s buffer set to the pool for the next bringUp. If the pool is
/// full the set is retained unreferenced — log it rather than dropping the
/// fact (bounded: pool overflow needs >8 abandoned devices between reuses).
fn releaseDeviceBufs(d: *Device) void {
    if (d.input_ctx == 0) return; // never allocated
    if (nbuf_pool == buf_pool.len) {
        log("xhci: buffer pool full — device DMA set retained (leak)\n");
        return;
    }
    buf_pool[nbuf_pool] = .{ .ep0 = d.ep0, .input_ctx = d.input_ctx, .dctx = d.dctx, .descbuf = d.descbuf, .hid_rings = d.hid_rings, .hid_reports = d.hid_reports };
    nbuf_pool += 1;
    d.input_ctx = 0;
}

/// Release a device's xHC slot after a failed init attempt or an unplug
/// (Linux hub_port_disable + release_devnum analogue): Disable Slot returns the
/// slot id to the controller and clears its DCBAA entry. Safe on a device whose
/// slot was never enabled (no-op).
fn disableSlot(d: *Device) void {
    if (d.slot == 0) return;
    _ = submitCommand(0, (TRB_DISABLE_SLOT << 10) | (d.slot << 24));
    dcbaa[d.slot] = 0;
    d.slot = 0;
}

/// Control IN on EP0: setup (immediate) + data IN + status OUT. Returns the
/// number of data bytes the device actually returned (requested `len` minus the
/// Transfer Event residual), or null on failure. Callers that only care about
/// success test `!= null`; the report-descriptor scan uses the count so it never
/// reads past the real descriptor into the stale tail of `descbuf`.
///
/// SEAM (pub with controlOut/controlInRetry/descByte): the control-transfer
/// surface for the class glue split out of this driver (hub.zig via
/// hub_vtable) — widening it is a visible act.
pub fn controlIn(d: *Device, setup: u64, len: u16) ?u16 {
    // Zero the destination first: a short read leaves the tail holding the
    // PREVIOUS transfer's bytes, and any consumer that over-reads would see
    // stale, valid-looking data and silently accept it. descbuf is DESCBUF_SIZE
    // bytes; clear the region we expose.
    if (len > 0) @memset(@as([*]u8, @ptrFromInt(d.descbuf))[0..@min(@as(usize, len), DESCBUF_SIZE)], 0);
    // SETUP (IN transfer type) -> DATA IN -> STATUS OUT (status dir is opposite the
    // data stage, so no DIR_IN here). xHCI §6.4.1.
    d.ep0.push(setup, 8, ctrl(TRB_SETUP_STAGE, TRB_TRT_IN | TRB_IDT));
    // Set ISP (Interrupt on Short Packet) on the DATA stage so a device that returns
    // FEWER bytes than requested raises a Transfer Event for THIS TRB, carrying the
    // real residual. Without it the only event is the STATUS stage's (residual 0), so
    // `len -| residual` reports the full requested length and the descriptor walk
    // over-reads a short reply's stale tail — the class of bug that skipped a real
    // device. xHCI §4.11.5.2; matches Linux setting ISP on IN control data TRBs.
    if (len > 0) d.ep0.push(d.descbuf, len, ctrl(TRB_DATA_STAGE, TRB_DIR_IN | TRB_ISP));
    d.ep0.push(0, 0, ctrl(TRB_STATUS_STAGE, TRB_IOC));
    ringDoorbell(d.slot, EP0_DCI);
    const residual = awaitXfer(d) orelse return null;
    // residual = bytes NOT transferred (xHCI Transfer Event status low 24 bits).
    return len -| @as(u16, @truncate(residual));
}

/// Read byte `i` of a device's DMA descriptor buffer through a VOLATILE pointer.
/// The controller DMAs the descriptor in asynchronously — the CPU issues no
/// store — so a plain [*]const u8 load lets the optimizer fold the read to the
/// last value it can see (the pre-transfer @memset 0), constant-folding real
/// descriptor bytes to 0 under ReleaseFast. Volatile forces the reload (the
/// READ_ONCE guarantee). ALL descriptor reads use this.
///
/// SEAM (pub with controlIn): the split-out class glue reads its control-IN
/// payloads back through this via hub_vtable.
pub inline fn descByte(d: *const Device, i: usize) u8 {
    return @as([*]const volatile u8, @ptrFromInt(d.descbuf))[i];
}

/// Wait for a Transfer Event addressed to `d`'s slot. Returns the event's residual
/// byte count (status low 24 bits) on success, or null on failure/timeout.
/// Other slots' Transfer Events (e.g. interrupt reports from already-running HID
/// devices) are skipped so they can't be mistaken for this control transfer's
/// completion — both are TRB type 32, distinguished only by slot id.
///
/// The retry budget bounds **timeouts**, not events: a foreign-slot event is
/// drained and the wait continues WITHOUT spending the budget, because it means
/// the ring is live and our completion is simply queued behind it. Only a genuine
/// nextEvent timeout (nothing posted within the window) counts toward giving up.
/// This way an already-streaming HID device cannot starve a control completion by
/// flooding the ring — it would only burn the budget if each report cost a full
/// timeout, which it never does. (Polling is also deferred until enumeration
/// finishes so this case should not arise at all.)
///
/// On a control STALL the transfer failed (returns null), but EP0 is now HALTED —
/// left un-reset, the NEXT control transfer on this device would run no TRBs and
/// time out. A protocol STALL (e.g. SET_PROTOCOL to a non-boot interface) is a
/// legitimate device response, so this must recover rather than abandon the device:
/// reset EP0 (DCI=1) + Set TR Dequeue on its ring before returning.
fn awaitXfer(d: *Device) ?u32 {
    last_cc = CC_TIMEOUT; // marker until a completion for our slot is seen
    var short_residual: ?u32 = null; // set by a Data-stage Short Packet; see below
    var timeouts: u32 = 0;
    const deadline = timer.millis() + XFER_WALL_MS;
    while (timeouts < XFER_TIMEOUT_TRIES) {
        // Stay reachable on EVERY iteration. A dead transfer alongside live HID traffic
        // can keep this loop busy indefinitely, and if the remote-control channel is not
        // serviced from inside it, the machine cannot be rebooted for as long as that
        // lasts (see XFER_WALL_MS).
        serviceHost();
        if (timer.millis() > deadline) {
            log("xhci: transfer wall-clock ceiling — abandoning transfer\n");
            drainEvents();
            return null;
        }
        const ev = nextEvent(EVENT_POLL_SPINS) orelse {
            // Nothing posted within the window: a real timeout. After enough of
            // them, drain any straggler and fail — a late completion must not
            // desync the next transfer's ring dequeue/cycle.
            timeouts += 1;
            if (timeouts >= XFER_TIMEOUT_TRIES) {
                drainEvents();
                return null;
            }
            continue;
        };
        if (trbType(ev) == TRB_TRANSFER_EVENT and ((ev.control >> 24) & 0xFF) == d.slot) {
            const cc = completionCode(ev); // the xHC's REAL verdict for our slot
            last_cc = cc;

            // SHORT PACKET IS NOT THE END OF THE TRANSFER. A control transfer is three
            // TDs (Setup / Data / Status); the Data TD carries ISP so it only reports
            // when the device returns FEWER bytes than asked, while the Status TD
            // carries IOC and always reports. So a short read posts TWO events, and
            // returning on the first leaves the Status event sitting on the ring —
            // which the NEXT transfer then consumes as its own completion. Every
            // subsequent control transfer and command is answered by the previous
            // one's event: SET_CONFIGURATION "succeeds" before it runs, a descriptor
            // read "succeeds" before its DMA lands, and an Address Device waits forever
            // for an event that was already eaten. That event-ring desync is what
            // produces an "Address Device timeout", and what makes a hub descriptor
            // read nports=0 then 4 (hub.zig's bNbrPorts settle poll).
            //
            // Keep the residual and go round again for the Status event, which is the
            // one that actually ends the TD chain. (QEMU coalesces control transfers
            // into a single event, which is why this never showed up in emulation.)
            if (cc == CC_SHORT_PACKET) {
                short_residual = ev.status & 0xFFFFFF;
                continue;
            }
            if (!xferOk(ev)) {
                // Any non-OK completion (STALL, transaction error, babble) may have
                // halted EP0 — un-halt it (Reset Endpoint + Set TR Dequeue) so the
                // next control transfer runs, else EP0 is dead for the session.
                _ = recoverEndpoint(d.slot, EP0_DCI, &d.ep0);
                // …and RESTORE the verdict: recoverEndpoint runs two commands of its
                // own, and their SUCCESS completions overwrite last_cc with 1. That is
                // the whole "18-byte descriptor read failed, yet cc=1 (success)" mystery
                // on the Phison stick — the failure code was being erased by the code
                // that handles the failure, so every trace lied about why.
                last_cc = cc;
                return null;
            }
            // The Status event ends the chain. If a Short Packet preceded it, ITS
            // residual is the real one (the Status TD moves no data).
            return short_residual orelse (ev.status & 0xFFFFFF);
        }
        // Foreign/unrelated event (another slot's report, or a port change):
        // already dequeued by nextEvent; dispatch it (a live device's report
        // must be processed + re-queued, a PSCE latched) and keep waiting
        // without counting it as a timeout.
        {
            const saved_cc = last_cc; // see submitCommand's foreign-dispatch note
            dispatchForeign(ev);
            last_cc = saved_cc;
        }
    }
    return null;
}

/// Control OUT with no data stage (SET_CONFIGURATION, SET_PROTOCOL). With no data
/// stage the status stage is IN (DIR_IN), the opposite of the absent OUT data.
///
/// SEAM (pub with controlIn): serves the split-out class glue via hub_vtable.
pub fn controlOut(d: *Device, setup: u64) bool {
    d.ep0.push(setup, 8, ctrl(TRB_SETUP_STAGE, TRB_IDT)); // TRT=0: no data stage
    d.ep0.push(0, 0, ctrl(TRB_STATUS_STAGE, TRB_DIR_IN | TRB_IOC));
    ringDoorbell(d.slot, EP0_DCI);
    return awaitXfer(d) != null; // success regardless of residual
}

/// Hard ceiling on the WHOLE root-port enumeration.
///
/// USB MUST NOT BE ABLE TO HANG THE BOOT. A device that never answers can make
/// enumeration retry indefinitely, and this runs inside `xhci.init()` — upstream of the
/// steady loop that brings up the network. A machine stuck here therefore has no trace
/// bus and no remote control: it can only be recovered by hand, at the wall.
///
/// Nothing lower down will save us. The chipset watchdog is held disabled by firmware
/// (NO_REBOOT is set, and measured to be unclearable on this board — even Linux's
/// iTCO_wdt cannot reset it), so the only reliable remote reset is the one kudos itself
/// serves from the steady loop.
///
/// REACHING THAT LOOP THEREFORE OUTRANKS FINISHING ENUMERATION. Past this deadline we
/// abandon USB, say so loudly, and boot on with no keyboard and no mouse: a kudos we can
/// still reboot and screenshot beats a kudos that bricks the machine.
const ENUM_BUDGET_MS: u64 = 15_000;

/// Keep-the-machine-reachable hook, set by main_root.zig before init() (a function
/// pointer, because xhci must not import the net stack).
///
/// Enumeration runs BEFORE the steady loop, and the steady loop is what pumps the
/// network and answers KMR1. So while xhci grinds, kudos is mute (no netdebug) and
/// deaf (no remote reboot): a stuck enumeration leaves a machine that can only be
/// fixed by hand, and the PCH watchdog cannot help (NO_REBOOT is stuck on lemon's
/// board).
///
/// Calling this from the slow paths below keeps telemetry flowing and — the point —
/// keeps OP_REBOOT answerable THROUGHOUT enumeration. A kudos wedged in USB that we
/// can still reboot remotely is a bad boot; one we cannot is a dead machine.
pub var service_hook: ?*const fn () void = null;

fn serviceHost() void {
    if (service_hook) |h| h();
}

/// Wall-clock deadline for the whole enumeration, set once by enumerate(). Checked
/// BETWEEN ports and inside bringUp's retry loop: a single port can grind forever
/// inside its own bringUp (every transfer timing out on the event ring, retried),
/// which a between-ports check alone would never reach.
var enum_deadline_ms: u64 = 0;

/// Consecutive failed enumeration attempts per root port (index = port number;
/// port 0 unused). A port that reaches PORT_GIVE_UP is abandoned for the rest of
/// the boot — see the give-up check in processPortChanges. Reset to 0 the moment
/// the port produces a real device, so a flaky-but-working port is not condemned
/// by a transient failure.
///
/// Sized to the port-change bitmap: `pending_ports` is a u32 indexed by (port-1),
/// so ports 1..32 are the only ones this driver can ever latch a change for.
const PORT_SLOTS: usize = 33;
var port_fail: [PORT_SLOTS]u8 = @splat(0);
const PORT_GIVE_UP = port_fsm.PORT_GIVE_UP;

/// True once enumeration has overrun its budget. Every retry loop in the
/// enumeration path consults this and bails.
fn enumExpired() bool {
    return enum_deadline_ms != 0 and timer.millis() > enum_deadline_ms;
}

/// Enumerate every connected root-hub port, recursing through any hubs found.
fn enumerate() void {
    var connected: u32 = 0;
    var port: u32 = 1;
    const t_start = timer.millis();
    enum_deadline_ms = t_start + ENUM_BUDGET_MS;
    while (port <= max_ports) : (port += 1) {
        serviceHost(); // stay reachable: ship telemetry, answer OP_REBOOT
        if (timer.millis() -% t_start > ENUM_BUDGET_MS) {
            log("xhci: ENUMERATION BUDGET EXHAUSTED — abandoning USB, booting on\n");
            logx("xhci: abandoned at port=", port);
            dbg.setNum(.usb, "usb.enum_abandoned_at_port", port);
            dbg.set(.usb, "usb.stopped_at", "enumeration budget exhausted");
            break;
        }
        const pr = resetPort(port);
        // Record EVERY port's decoded PORTSC + verdict, connected or not, so the
        // one native reboot shows exactly which ports read CCS=0 / bounced / failed
        // reset — the boot keyboard/mouse's USB2 companion port among them.
        recordRootPort(port, pr.portsc, pr.result);
        if (pr.speed != 0) {
            connected += 1;
            // Boot walk: every connected port is tried exactly once, so there is no
            // failure count to keep here (port_fail is the HOTPLUG path's business).
            _ = bringUp(.{ .route = 0, .root_port = port, .parent_slot = 0, .parent_port = 0, .tier = 0 }, pr.speed, null);
        }
    }
    dbg.setNum(.usb, "usb.ports_connected", connected);
    dbg.setNum(.usb, "usb.ports_total", max_ports);
    logx("xhci: HID devices=", ndev);
}

/// One init attempt's verdict, driving the PORT_INIT_TRIES loop in bringUp.
const Attempt = enum {
    ok_hid, // HID configured — keep the device for polling
    ok_msc, // mass storage configured + probed — kept as THE block device
    ok_hub, // hub configured + downstream walked — device is transient
    retry, // transient failure — worth another attempt from a fresh reset
    declined, // DEFINITIVELY declined by vid/pid (a masked audio/RGB/BT codec): it
    // will never be wanted, so its port is marked owned — no re-enum, no reset-storm
    unsupported, // no driver for it AS SEEN — but a composite device mid-bring-up (a
    // keyboard whose HID interface is not ready yet) looks exactly like this, so the
    // port is NOT owned: a later, complete connect re-enumerates it (see bringUp)
};

/// Enumerate a device at `topo` with the full Linux hub_port_connect retry
/// structure: up to PORT_INIT_TRIES
/// full attempts, each failed attempt Disabling the slot and starting over from
/// a fresh port reset; at the halfway attempt the port is VBUS power-cycled.
/// `parent` is the hub the device hangs off (null = on a root port) — needed to
/// re-reset / power-cycle the right port between attempts.
///
/// The device is brought up in a stack-LOCAL `Device`, never directly in
/// `devs[ndev]`: a hub recurses (its children write `devs[ndev]`), so sharing
/// storage with `devs[ndev]` would let a child overwrite the hub's slot/rings
/// mid-enumeration and wedge it. A successful HID device is copied into `devs[]`
/// only at the end. The DMA buffer set is allocated ONCE (or popped from the
/// recycle pool) and reused across attempts; an abandoned device returns it.
/// Returns TRUE if the device enumerated — a hub, a HID device, OR a mass-storage
/// device.
///
/// THE PORT'S VERDICT IS THIS RETURN VALUE, never something inferred from a side effect.
/// The obvious-looking test is "did the device count go up", but that count tracks HID
/// devices only — so a USB stick or an HID-less hub coming up perfectly reads as a FAILED
/// enumeration. Fail a port three times and it is blacklisted, which means it is dead for
/// whatever you plug in next, too.
fn bringUp(topo: hub.Topo, first_speed: u32, parent: ?*Device) bool {
    var dev: Device = .{ .speed = first_speed, .topo = topo };
    const d = &dev;

    // Reserve this device's debug key prefix (`usb.devN.`) up front so every
    // early return can annotate WHY the device dropped, not just the successes.
    // The prefix buffer is a LOCAL, and the global cur_pre is saved/restored
    // around this device: a hub's children (recursion via hub.Hub.setup's
    // bringUpChild callback) must not
    // clobber the hub's own `usb.devN` record mid-walk.
    const n = attempts;
    attempts += 1;
    d.dbg_id = n;
    var pre_buf: [16]u8 = undefined;
    const pre = std.fmt.bufPrint(&pre_buf, "usb.dev{d}", .{n}) catch "usb.devN";
    const prev_pre = cur_pre;
    cur_pre = pre;
    defer cur_pre = prev_pre;
    dvSetStr(pre, "speed", speedName(first_speed));
    dvSet(pre, "tier", topo.tier);
    dvSet(pre, "root_port", topo.root_port);
    if (topo.tier != 0) dvSetHex(pre, "route", topo.route);

    if (!allocDeviceBufs(d)) {
        dvSetStr(pre, "drop", "DMA alloc failed");
        return false;
    }

    var attempt: u32 = 0;
    while (attempt < PORT_INIT_TRIES) : (attempt += 1) {
        serviceHost(); // each attempt is seconds of event-ring timeouts — stay reachable
        // Abandon THIS device the moment enumeration overruns. Each attempt costs
        // several event-ring timeouts against a device that never answers, so a
        // dead port burns the budget here — and boot must not wait for it.
        if (enumExpired()) {
            dvSetStr(pre, "drop", "enumeration budget exhausted");
            logx("xhci: budget exhausted, abandoning dev=", n);
            releaseDeviceBufs(d);
            return false;
        }
        if (attempt != 0) {
            // Fresh start (Linux hub_port_connect loop): release the failed
            // attempt's slot, scrub the reusable DMA set, and re-reset the port.
            // Halfway through the attempts, VBUS power-cycle the port first.
            dvSet(pre, "init_retry", attempt);
            logx2("xhci: init retry dev=", n, " attempt=", attempt);
            disableSlot(d);
            d.hids = .{null} ** MAX_DEV_HID;
            resetDeviceBufs(d);
            if (attempt == PORT_INIT_TRIES / 2) powerCyclePort(parent, topo);
            d.speed = reResetPort(parent, topo) orelse {
                dvSetStr(pre, "drop", "vanished on re-reset");
                releaseDeviceBufs(d);
                return false;
            };
        }
        switch (initAttempt(d, pre)) {
            // A hub stays live for routing (slot + contexts owned by the xHC),
            // so its buffer set is intentionally retained, not released.
            .ok_hub => {
                if (topo.tier == 0) markRootPort(topo.root_port, true);
                return true;
            },
            .ok_hid => {
                logx("xhci: device ready slot=", d.slot);
                dvSetStr(pre, "drop", "none (ready)");
                if (topo.tier == 0) markRootPort(topo.root_port, true);
                if (ndev < devs.len) { // keep this HID device for polling
                    devs[ndev] = dev;
                    ndev += 1;
                } else {
                    log("xhci: devs[] full — HID device not kept\n");
                    dvSetStr(pre, "drop", "devs[] full");
                }
                return true;
            },
            .ok_msc => {
                // Keep the device in its dedicated slot (the transport ctx
                // must point at STABLE storage) and run the BOT probe —
                // TEST UNIT READY / INQUIRY / READ CAPACITY + the capacity
                // whitelist (msc.zig).
                if (topo.tier == 0) markRootPort(topo.root_port, true);
                msc_device = dev;
                msc_dev = .{ .t = .{ .ctx = &msc_device, .vtable = &msc_transport_vtable } };
                if (msc_dev.probe()) {
                    msc_ready = true;
                    logx("xhci: MASS STORAGE ready, sectors=", msc_dev.nblocks);
                    dvSetStr(pre, "drop", "none (block device ready)");
                } else |e| {
                    // LOUD refusal — the whitelist and probe failures must
                    // be visible, and the device is never read again.
                    logx2("xhci: MASS STORAGE refused err#=", @intFromError(e), " capacity_bytes=", msc_dev.refused_bytes);
                    dvSetStr(pre, "drop", @errorName(e));
                    disableSlot(d);
                    releaseDeviceBufs(d);
                }
                // The device ENUMERATED either way. A probe refusal (capacity
                // whitelist, dead LUN) is the class driver declining a healthy
                // device — it is not the PORT failing, and blacklisting the port
                // for it would punish whatever gets plugged in next.
                return true;
            },
            .retry => {},
            .declined => {
                // DEFINITIVELY declined by vid/pid (a masked audio/RGB/Bluetooth
                // codec). It answered its device descriptor, so the PORT did its job
                // — it must NOT be scored a failure, or the port reset-storms
                // PORT_GIVE_UP times and blacklists every boot (the "gave up after
                // repeated enumeration failures" a plain audio port produced). And
                // because this vid/pid will NEVER be wanted, mark the port owned so
                // its next spurious change does not re-enumerate the same codec. Free
                // the slot/buffers (we keep nothing) and report the enumeration a
                // success.
                if (topo.tier == 0) markRootPort(topo.root_port, true);
                disableSlot(d);
                releaseDeviceBufs(d);
                return true;
            },
            .unsupported => {
                // We have no driver for it AS SEEN — but do NOT own the port. A
                // composite device still bringing its USB up (a keyboard whose HID
                // interface is not yet ready) presents exactly like this, and owning
                // the port would blacklist it for the whole boot; when it completes
                // and re-posts a connect, the port must be free to re-enumerate it.
                // Return false so a GENUINELY unsupported device that keeps re-arming
                // still gives up via port_fail (no livelock), while a slow device
                // gets another chance on its next, complete connect. Free the slot.
                disableSlot(d);
                releaseDeviceBufs(d);
                return false;
            },
        }
    }
    dvSetStr(pre, "drop", "all init attempts failed");
    dvSetCc(pre);
    disableSlot(d);
    releaseDeviceBufs(d);
    return false;
}

/// One full init attempt (Linux hub_port_init): address the device, read its
/// descriptors (with the GET_DESCRIPTOR_TRIES inner retry), then dispatch to
/// the hub or HID setup path. Any transient failure returns .retry — bringUp
/// re-resets the port and tries again.
fn initAttempt(d: *Device, pre: []const u8) Attempt {
    if (!addressDevice(d)) {
        // addressDevice records its own sub-step (`addr_fail`); add the CC that the
        // failing command returned so the reboot names the exact xHC verdict.
        dvSetStr(pre, "drop", "addressDevice failed");
        dvSetCc(pre);
        return .retry;
    }
    dvSet(pre, "addr", d.slot);

    // SET_ADDRESS recovery (USB 9.2.6.3): the device needs time after being
    // addressed before it will answer descriptor requests on real hardware.
    timer.sleep(T_SET_ADDRESS_MS);

    // Read the first 8 bytes of the device descriptor to learn bMaxPacketSize0
    // (offset 7), then correct EP0's max packet size for full-speed devices
    // before any larger control transfer. See fixEp0MaxPacket.
    // GET_DESCRIPTOR(device, 8 bytes): req_type 0x80 (in/std/device), req 6,
    // value 0x0100 (descriptor type 1 << 8).
    if (controlInRetry(d, setupPkt(0x80, 6, 0x0100, 0, 8), 8) == null) {
        dvSetStr(pre, "drop", "8-byte device desc read failed");
        dvSetCc(pre);
        dvSetCcTries(pre);
        return .retry;
    }
    const mps0 = descByte(d, 7);
    if (!fixEp0MaxPacket(d, mps0)) {
        dvSetStr(pre, "drop", "EP0 max-packet fix failed");
        dvSetCc(pre);
        return .retry;
    }

    // Now the full device descriptor: offset 4 = bDeviceClass, 8-9 = idVendor,
    // 10-11 = idProduct (USB 2.0 §9.6.1).
    if (controlInRetry(d, setupPkt(0x80, 6, 0x0100, 0, 18), 18) == null) {
        dvSetStr(pre, "drop", "18-byte device desc read failed");
        dvSetCc(pre);
        dvSetCcTries(pre);
        return .retry;
    }
    const dd: [*]const volatile u8 = @ptrFromInt(d.descbuf);
    const class = dd[4];
    const vid = @as(u16, dd[8]) | (@as(u16, dd[9]) << 8);
    const pid = @as(u16, dd[10]) | (@as(u16, dd[11]) << 8);
    var vbuf: [dbg.VAL_CAP]u8 = undefined;
    dvSetStr(pre, "vid_pid", std.fmt.bufPrint(&vbuf, "{x:0>4}:{x:0>4}", .{ vid, pid }) catch "?");

    // MASKED? Give up NOW, before the config descriptor. kudos drives exactly three
    // classes, so an onboard audio codec or an RGB controller is going to be rejected
    // anyway — but rejecting it late costs a full config-descriptor read and interface
    // walk, and lemon's audio card answers that slowly enough to dominate USB bring-up.
    // The device is still identified in the trace, so it is visible, not vanished.
    if (devmask.masked(vid, pid)) |why| {
        logx2("xhci:  masked device, vid=", vid, " pid=", pid);
        dvSetStr(pre, "kind", "masked");
        dvSetStr(pre, "drop", why);
        return .declined;
    }

    if (class == 9) { // hub — transient; enumerate the devices behind it
        log("xhci:  hub — enumerating downstream ports\n");
        dvSetStr(pre, "kind", "hub");
        if (!hubView(d).setup(pre)) {
            dvSetStr(pre, "drop", "hub setup failed");
            dvSetCc(pre);
            return .retry;
        }
        return .ok_hub;
    }
    switch (setupHid(d)) {
        .unsupported => return .unsupported, // maybe a device mid-bring-up — don't own its port
        .failed => {
            dvSetStr(pre, "drop", "setupHid failed");
            dvSetCc(pre);
            return .retry;
        },
        .msc => return .ok_msc, // bringUp keeps it + runs the probe
        .ok => {},
    }
    // Diag for the device's first configured endpoint. A composite device drives
    // a second (d.hids[1]); its presence is proven by the usb.hid_present counts.
    const hid = &d.hids[0].?;
    dvSetStr(pre, "kind", kindName(hid.kind));
    dvSet(pre, "ep_dci", hid.dci);
    dvSet(pre, "ep_mps", hid.mps);
    if (hid.kind == .mouse) {
        var mbuf: [dbg.VAL_CAP]u8 = undefined;
        dvSetStr(pre, "mouse_layout", std.fmt.bufPrint(&mbuf, "x_byte={d} size={d} btn_byte={d}", .{ hid.layout.x_byte, hid.layout.size_bytes, hid.layout.buttons_byte }) catch "?");
    }
    return .ok_hid;
}

/// controlIn with the Linux GET_DESCRIPTOR_TRIES retry: a transient descriptor
/// read failure gets another chance after T_DESC_RETRY_MS before the whole
/// attempt is retried from a port reset (hub_port_init's outer loop).
///
/// SEAM (pub with controlIn): serves the split-out class glue via hub_vtable.
pub fn controlInRetry(d: *Device, setup: u64, len: u16) ?u16 {
    var t: u32 = 0;
    ctrl_try_n = 0;
    while (t < GET_DESCRIPTOR_TRIES) : (t += 1) {
        if (t != 0) timer.sleep(T_DESC_RETRY_MS);
        if (controlIn(d, setup, len)) |got| return got;
        // Record EVERY try's completion code, not just the last one. A single trailing
        // code is ambiguous to the point of being misleading: a failed descriptor read
        // whose final try happened to complete reports "success", and nothing in the
        // trace says whether the earlier tries timed out or came back with an error.
        if (ctrl_try_n < ctrl_try_ccs.len) {
            ctrl_try_ccs[ctrl_try_n] = @truncate(last_cc);
            ctrl_try_n += 1;
        }
    }
    return null;
}

/// Per-try completion codes from the LAST controlInRetry (0xFF = timed out with
/// no completion for the slot). Written only when a try fails, so on the drop
/// path this is the failure history the single `cc` record collapses.
var ctrl_try_ccs: [8]u8 = undefined;
var ctrl_try_n: usize = 0;

/// Emit the per-try CC history of the last controlInRetry alongside a
/// descriptor-read drop record.
fn dvSetCcTries(pre: []const u8) void {
    const S = struct {
        var buf: [dbg.VAL_CAP]u8 = undefined;
    };
    var fw = std.Io.Writer.fixed(&S.buf);
    var i: usize = 0;
    while (i < ctrl_try_n) : (i += 1)
        fw.print("{s}{d}", .{ if (i == 0) @as([]const u8, "") else ",", ctrl_try_ccs[i] }) catch break;
    dvSetStr(pre, "cc_tries", fw.buffered());
}

/// Re-reset a device's port between init attempts: the root port for a tier-0
/// device, the parent hub's downstream port otherwise. Returns the (possibly
/// re-trained) port speed, or null if the device is gone.
fn reResetPort(parent: ?*Device, topo: hub.Topo) ?u32 {
    if (parent) |h| return hubView(h).portReset(topo.parent_port);
    const pr = resetPortOnly(topo.root_port);
    return if (pr.speed != 0) pr.speed else null;
}

/// VBUS power-cycle a device's port (Linux hub_port_connect halfway remedy):
/// root ports via PORTSC.PP, hub downstream ports via hub.Hub.powerCyclePort
/// (the PORT_POWER feature, timed by the hub's recorded power-on-good delay).
fn powerCyclePort(parent: ?*Device, topo: hub.Topo) void {
    if (parent) |h| {
        hubView(h).powerCyclePort(topo.parent_port, h.pwr_on_good_ms);
        return;
    }
    powerCycleRootPort(topo.root_port);
}

/// Debug-record helpers: write `<pre>.<field> = value`, building the dotted key
/// once. Keep the per-attempt device lines terse and consistently keyed so the
/// `debug` command groups a device's fields together.
fn dvKey(pre: []const u8, field: []const u8) []const u8 {
    const S = struct {
        var buf: [dbg.KEY_CAP]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}.{s}", .{ pre, field }) catch pre;
}
fn dvSetStr(pre: []const u8, field: []const u8, value: []const u8) void {
    dbg.set(.usb, dvKey(pre, field), value);
}
fn dvSet(pre: []const u8, field: []const u8, value: u64) void {
    dbg.setNum(.usb, dvKey(pre, field), value);
}
fn dvSetHex(pre: []const u8, field: []const u8, value: u64) void {
    dbg.setHex(.usb, dvKey(pre, field), value);
}

const ccName = xhci_cc.ccName;
/// Record the last completion code both ways: `<pre>.cc = <n>` (raw byte) and
/// `<pre>.cc_name = <name>` — the raw number survives even when ccName can't decode
/// it, and the name reads at a glance in the netdebug trace.
fn dvSetCc(pre: []const u8) void {
    dvSet(pre, "cc", last_cc);
    dvSetStr(pre, "cc_name", ccName(last_cc));
}

/// Human speed name for the debug record.
fn speedName(speed: u32) []const u8 {
    return switch (speed) {
        port_fsm.SPEED_LOW => "LS",
        port_fsm.SPEED_FULL => "FS",
        port_fsm.SPEED_HIGH => "HS",
        port_fsm.SPEED_SUPER => "SS",
        port_fsm.SPEED_SUPER_PLUS => "SSP",
        else => "?",
    };
}
/// Human HID-kind name for the debug record.
fn kindName(k: hid_report.Kind) []const u8 {
    return switch (k) {
        .keyboard => "kbd",
        .mouse => "mouse",
        .tablet => "tablet",
    };
}

/// Enable a slot and Address Device for `d`, building the slot + EP0 contexts
/// from its topology. Returns false on any failure.
fn addressDevice(d: *Device) bool {
    // Each early return records WHICH sub-step failed into this attempt's device
    // record (`usb.devN.addr_fail`), so a reboot distinguishes enable-slot vs a bad
    // slot id vs a DMA-alloc exhaustion vs the Address Device command itself — very
    // different faults that otherwise all read as one "addressDevice failed".
    const slot_ev = submitCommand(0, TRB_ENABLE_SLOT << 10) orelse {
        dvSetStr(cur_pre, "addr_fail", "enable-slot: no completion");
        return false;
    };
    if (!cmdOk(slot_ev)) {
        dvSetStr(cur_pre, "addr_fail", "enable-slot: cmd error");
        return false;
    }
    d.slot = (slot_ev.control >> 24) & 0xFF;
    // The slot id is controller/firmware-supplied. Bound it against the DCBAA size
    // ((max_slots+1) entries) before indexing: slot 0 would clobber the scratchpad
    // pointer at dcbaa[0]; slot > max_slots writes a device-context pointer past the
    // DCBAA DMA buffer (OOB corruption). A bad slot is a controller fault — bail.
    if (d.slot == 0 or d.slot > max_slots) {
        dvSet(cur_pre, "addr_fail_slot", d.slot); // out-of-range slot id from the xHC
        dvSetStr(cur_pre, "addr_fail", "bad slot id");
        return false;
    }

    // The DMA buffer set (EP0 ring, input/device contexts, descbuf) was
    // allocated ONCE by bringUp (allocDeviceBufs) and is reused across init
    // attempts — publish this attempt's device context to the controller.
    dcbaa[d.slot] = d.dctx;

    ctxSet(d.input_ctx, 0, 1, 0b11); // add slot + EP0 contexts
    // Slot DW0: Route String | Context Entries=1 | Speed.
    ctxSlotDw0(d.input_ctx, d.topo.route, 1, d.speed, 0);
    // Slot dword 1: Root Hub Port Number (16-23).
    ctxSet(d.input_ctx, 1, 1, d.topo.root_port << 16);
    // Slot dword 2: Parent (TT) hub slot id (0-7) + port number (8-15), for a
    // full/low-speed device behind a high-speed hub.
    if (d.topo.parent_slot != 0 and (d.speed == port_fsm.SPEED_FULL or d.speed == port_fsm.SPEED_LOW)) {
        ctxSet(d.input_ctx, 1, 2, d.topo.parent_slot | (d.topo.parent_port << 8));
    }
    // EP0: Control endpoint, max-packet guessed from speed (corrected later for FS).
    ctxEp(d.input_ctx, 2, EP_TYPE_CONTROL, maxPacketForSpeed(d.speed), d.ep0.phys);

    // Address Device, with retries: the command can time out / fail the first
    // time on real HW — a device (especially a hub behind a hub) may not be ready
    // right after its port reset. Re-issue up to ADDRESS_DEVICE_TRIES times with a
    // recovery delay between attempts (mirrors Linux hub_port_init
    // SET_ADDRESS_TRIES). A transient failure that dropped the device outright
    // otherwise loses every device on that hub — the intermittent "two hubs
    // failed addressDevice" on the target board.
    var tries: u32 = 0;
    while (tries < ADDRESS_DEVICE_TRIES) : (tries += 1) {
        if (tries != 0) timer.sleep(T_ADDRESS_RETRY_MS);
        if (submitCommand(d.input_ctx, (TRB_ADDRESS_DEVICE << 10) | (d.slot << 24))) |addr_ev| {
            if (cmdOk(addr_ev)) return true;
        }
        // WHY DID THE COMMAND NOT COMPLETE? The xHC always posts a Command Completion
        // Event — even for a command it rejects — so "no event at all" means it never
        // EXECUTED the command, and that is a controller/ring state question, not a
        // slot-context one. Ask the controller directly instead of guessing again:
        //   usbsts.HCE/HSE  -> the host controller has faulted (everything after is dead)
        //   crcr.CRR        -> is the command ring even RUNNING?
        //   portsc          -> is the device still there, and in the right state?
        logx("xhci:  Address Device retry, attempt=", tries + 1);
        logx("xhci:   usbsts=", r32(op_base + OP_USBSTS));
        logx("xhci:   crcr_lo=", r32(op_base + OP_CRCR));
        // Is the event ring genuinely EMPTY, or has the producer filled slots whose
        // cycle bit we no longer agree with? EINT says events exist; if the TRB at our
        // dequeue carries the opposite cycle to the one we expect, then our dequeue and
        // the controller's producer have desynced and every event from here is invisible.
        logx("xhci:   ev_dequeue=", events.dequeue);
        logx("xhci:   ev_cycle=", events.cycle);
        logx("xhci:   ev_trb_ctrl=", events.trbs[events.dequeue].control);
        // LATCH it too. netdebug is metered and the .usb trace is a firehose — these
        // very lines were dropped on the wire the first time we asked for them. The 1 Hz
        // heartbeat record always gets through, so the snapshot rides out on that.
        dbg_addr_usbsts = r32(op_base + OP_USBSTS);
        dbg_addr_evdeq = @intCast(events.dequeue);
        dbg_addr_evcyc = events.cycle;
        dbg_addr_evctrl = events.trbs[events.dequeue].control;
    }
    // All ADDRESS_DEVICE_TRIES exhausted — record the command's last CC (stamped by
    // submitCommand/cmdOk) so the reboot shows whether it timed out or errored.
    dvSetStr(cur_pre, "addr_fail", "address-device cmd");
    dvSet(cur_pre, "addr_fail_tries", tries);
    return false;
}

/// For a FULL-speed device, correct EP0's max packet size to the descriptor's real
/// bMaxPacketSize0 via an Evaluate Context command. EP0 was addressed with a guess
/// of 64; if the device actually uses 8/16/32 the xHC would keep fragmenting at 64
/// and larger control reads fail on real HW. Mirrors Linux xhci_check_ep0_maxpacket.
///
/// WHICH value to program (and whether to program at all) is decided by
/// port_fsm.ep0MpsCorrection — pure and host-tested, so the "only full speed, only
/// the four legal sizes" rule cannot silently rot. This function is only the command.
/// Returns false only on a command failure.
fn fixEp0MaxPacket(d: *Device, mps0: u8) bool {
    const want = port_fsm.ep0MpsCorrection(d.speed, mps0) orelse return true;

    // Input context: add EP0 only (A1). Slot context is untouched.
    clearInputControl(d.input_ctx);
    ctxSet(d.input_ctx, 0, 1, 0b10); // add flags: EP0 context only
    ctxEp(d.input_ctx, 2, EP_TYPE_CONTROL, want, d.ep0.phys); // Control EP0, corrected MPS

    const ev = submitCommand(d.input_ctx, (TRB_EVALUATE_CONTEXT << 10) | (d.slot << 24)) orelse return false;
    logx("xhci:  EP0 max packet corrected to=", want);
    return cmdOk(ev);
}

// The endpoint-interval encoding (bInterval → xHCI Interval exponent) lives in
// port_fsm.zig (pure, host-tested): port_fsm.endpointInterval.

/// Fetch interface `iface`'s HID report descriptor (GET_DESCRIPTOR type 0x22)
/// into `buf` and return the bytes the transfer ACTUALLY returned — the pure
/// parsers (hid_report.zig: mouseLayout, classifyPointer) scan only that
/// slice; walking the stale tail of `descbuf` past the real descriptor is
/// what made a real mouse misparse to .none under ReleaseFast (the tail was
/// non-zero) while Debug got lucky. The copy goes through a volatile pointer:
/// descbuf is a DMA target and a plain read folds to the pre-transfer memset.
/// Overwrites d.descbuf; null if the read fails.
fn readReportDescriptor(d: *Device, iface: u8, declared_len: u16, buf: *[DESCBUF_SIZE]u8) ?[]const u8 {
    // Request exactly the interface's declared wDescriptorLength (from its HID
    // class descriptor, hid_report.Pick.rdesc_len) like Linux's
    // hid_get_class_descriptor. A fixed over-length read is mis-served by some
    // devices behind hubs. A zero declared length is a
    // malformed HID interface: refuse the read rather than guess (no fallbacks).
    if (declared_len == 0) return null;
    const req: u16 = @min(declared_len, @as(u16, DESCBUF_SIZE));
    const got = controlIn(d, setupPkt(0x81, 6, 0x2200, iface, req), req) orelse return null;
    const n: usize = @min(@as(usize, got), DESCBUF_SIZE); // actual descriptor bytes
    const rd: [*]const volatile u8 = @ptrFromInt(d.descbuf);
    for (buf[0..n], 0..) |*b, i| b.* = rd[i];
    return buf[0..n];
}

/// setupHid's verdict: transient failures are RETRIED by bringUp's init loop; a
/// device that positively has nothing we can drive is abandoned (retrying a
/// webcam 4 times only slows boot).
const HidResult = enum { ok, msc, failed, unsupported };

// ---- USB mass storage (msc.zig) ----
// The one MSC device kudos drives (the ~1 TB stick). The Device copy lives
// here so its rings/slot outlive enumeration; msc_dev's transport ctx points
// at it. main_root.zig asks blockDev() after init and mounts FAT on it.
var msc_device: Device = undefined;
var msc_dev: msc.Device = undefined;
var msc_ready: bool = false;

/// The event-ring/doorbell mutex: xhci.poll() (system task) and a BOT
/// transaction (any core-0 task, e.g. `ls /usbdisk` on the command worker)
/// must not interleave on the shared event ring. Taken with interrupts LIVE (see
/// usb_lock_depth): the transfers under it wait on tick-driven timeouts, which cannot
/// advance with IF=0. Held for a whole bulk transaction — up to ~1 ms.
var usb_lock: spinlock.SpinLock = .{};
var usb_lock_irq_was: bool = false;

/// The stick as a block device, once enumerated + probed (capacity
/// whitelist applied). Null = no usable stick this boot.
pub fn blockDev() ?@import("iblockdev").IBlockDev {
    if (!msc_ready) return null;
    return msc_dev.blockDev();
}

// msc.Transport over this controller: whole-transaction locking + one bulk
// transfer per call on the stick's pipes.
/// Re-entrant depth for the USB lock. Two constraints force this shape:
///
/// (1) RE-ENTRANCY: poll() holds usb_lock and calls processPortChanges -> bringUp ->
///     .ok_msc -> msc.probe -> mscBegin, which takes the same lock again. A
///     non-recursive lock deadlocks the core there, permanently.
/// (2) INTERRUPTS MUST STAY LIVE: every BOT transfer under this lock waits on xHC
///     events, and those waits are tick-driven — with IF=0 the tick cannot advance and
///     the wait never ends. So the lock is taken WITHOUT masking interrupts.
var usb_lock_depth: u32 = 0;
fn lockEnter() void {
    if (usb_lock_depth == 0) usb_lock.acquire(); // interrupts stay ON: the waits below need them
    usb_lock_depth += 1;
}
fn lockExit() void {
    usb_lock_depth -= 1;
    if (usb_lock_depth == 0) usb_lock.release();
}

fn mscBegin(_: *anyopaque) void {
    lockEnter();
}
fn mscEnd(_: *anyopaque) void {
    lockExit();
}
fn mscBulkOut(ctx: *anyopaque, bytes: []const u8) bool {
    const d: *Device = @ptrCast(@alignCast(ctx));
    // The CBW (31 bytes) stages through the DMA page.
    if (bytes.len > 512) return false;
    const dst: [*]volatile u8 = @ptrFromInt(d.msc_staging);
    for (bytes, 0..) |b, i| dst[i] = b;
    var ring = &d.msc_out_ring.?;
    ring.push(d.msc_staging, @intCast(bytes.len), ctrl(TRB_NORMAL, TRB_IOC));
    ringDoorbell(d.slot, d.msc_out_dci);
    return awaitBulk(d, d.msc_out_dci, ring) != null;
}
/// Enqueue ONE bulk TD, split so that no TRB's buffer crosses a 64 KiB boundary
/// (xHCI §4.11.2.1 — the controller requires it; see trb.zig for why this is not
/// optional and why only a host test can guard it).
///
/// A TD split across several TRBs is CHAINED: every TRB but the last carries CH,
/// and only the last carries IOC/ISP, so the controller still posts exactly one
/// Transfer Event for the whole TD and `awaitBulk`'s single-event assumption holds.
/// TD Size tells the xHC how many packets are still to come (§4.11.7.1).
///
/// Returns false if the TD needs more TRBs than the ring can hold — pushing a
/// partial TD would leave a chained TRB whose continuation never arrives.
fn pushBulkTd(ring: *Ring, addr: u64, len: u32, mps: u32, last_flags: u32) bool {
    if (trb.spanCount(addr, len) > ring.size - 1) {
        log("xhci: bulk TD needs more TRBs than the ring holds — refusing\n");
        return false;
    }
    var it = trb.Splitter.init(addr, len);
    var done: u32 = 0;
    while (it.next()) |s| {
        done += s.len;
        const remaining = len - done;
        const last = remaining == 0;
        const flags = if (last) last_flags else TRB_CHAIN;
        ring.push(s.addr, trb.statusWord(s.len, trb.tdSize(remaining, mps)), ctrl(TRB_NORMAL, flags));
    }
    return true;
}

fn mscBulkOutData(ctx: *anyopaque, bytes: []const u8) bool {
    const d: *Device = @ptrCast(@alignCast(ctx));
    // The WRITE(10) data phase (sectors) DMAs STRAIGHT from the caller's heap
    // buffer — identity-mapped, no 512-byte staging cap — the exact mirror of
    // the read data phase in mscBulkIn. The only writer is the boot-log ring,
    // whose 32 KiB scratch buffer is exactly the one that straddles a 64 KiB
    // boundary depending on where the linker put it (trb.zig).
    const ring = &d.msc_out_ring.?;
    if (!pushBulkTd(ring, @intFromPtr(bytes.ptr), @intCast(bytes.len), d.msc_out_mps, TRB_IOC)) return false;
    ringDoorbell(d.slot, d.msc_out_dci);
    return awaitBulk(d, d.msc_out_dci, ring) != null;
}
fn mscBulkIn(ctx: *anyopaque, buf: []u8) ?u32 {
    const d: *Device = @ptrCast(@alignCast(ctx));
    // Small transfers (the 13-byte CSW) stage through the DMA page; data
    // phases DMA straight into the caller's heap buffer (identity-mapped).
    const staged = buf.len <= 512;
    const dma: usize = if (staged) d.msc_staging + 512 else @intFromPtr(buf.ptr);
    const ring = &d.msc_in_ring.?;
    if (!pushBulkTd(ring, dma, @intCast(buf.len), d.msc_in_mps, TRB_IOC | TRB_ISP)) return null;
    ringDoorbell(d.slot, d.msc_in_dci);
    const residual = awaitBulk(d, d.msc_in_dci, ring) orelse return null;
    const got: u32 = @as(u32, @intCast(buf.len)) -| residual;
    if (staged) {
        const src: [*]const volatile u8 = @ptrFromInt(d.msc_staging + 512);
        for (buf[0..got], 0..) |*b, i| b.* = src[i];
    }
    return got;
}
fn mscRecover(ctx: *anyopaque) bool {
    const d: *Device = @ptrCast(@alignCast(ctx));
    // The BOT error ladder: clear both pipes' halts; the class-level Bulk-Only
    // Reset only if that fails.
    const in_ok = recoverEndpoint(d.slot, d.msc_in_dci, &d.msc_in_ring.?);
    const out_ok = recoverEndpoint(d.slot, d.msc_out_dci, &d.msc_out_ring.?);
    if (in_ok and out_ok) return true;
    return controlOut(d, setupPkt(0x21, 0xFF, 0, 0, 0)); // Bulk-Only Mass Storage Reset
}
const msc_transport_vtable = msc.Transport.VTable{
    .begin = mscBegin,
    .end = mscEnd,
    .bulkOut = mscBulkOut,
    .bulkOutData = mscBulkOutData,
    .bulkIn = mscBulkIn,
    .recover = mscRecover,
};

/// awaitXfer for a BULK pipe: same event loop, but a failed completion recovers THE
/// BULK ENDPOINT (not EP0) so the pipe runs again.
///
/// THE WALL CLOCK AND serviceHost() ARE NOT OPTIONAL. `timeouts` advances only on an
/// EMPTY event window, and a foreign event (a live HID report) is dispatched below
/// WITHOUT spending budget — so a stalled transfer plus any streaming HID device pins
/// the counter at 0 forever. The loop holds `usb_lock`, so without a deadline the
/// machine spins here mute (netdebug never drains) and deaf (OP_REBOOT never lands).
/// awaitXfer carries the same pair for the same reason.
///
/// The deadline rides the TSC, not the tick: the tick is the clock that can itself die,
/// and a timeout measured on a dead clock never expires.
fn awaitBulk(d: *Device, dci: u32, ring: *Ring) ?u32 {
    last_cc = CC_TIMEOUT;
    var timeouts: u32 = 0;
    const deadline = tsc.rdtsc() +% tsc.msTicks(BULK_WALL_MS);
    while (timeouts < XFER_TIMEOUT_TRIES) {
        // Stay reachable while we wait: this is where OP_REBOOT must always land.
        serviceHost();
        if (tsc.rdtsc() >= deadline) {
            log("xhci: bulk wall-clock ceiling — abandoning transfer\n");
            _ = recoverEndpoint(d.slot, dci, ring);
            drainEvents();
            return null;
        }
        const ev = nextEvent(EVENT_POLL_SPINS) orelse {
            timeouts += 1;
            if (timeouts >= XFER_TIMEOUT_TRIES) {
                logx("xhci: bulk transfer TIMED OUT (no completion) dci=", dci);
                drainEvents();
                return null;
            }
            continue;
        };
        if (trbType(ev) == TRB_TRANSFER_EVENT and ((ev.control >> 24) & 0xFF) == d.slot and
            ((ev.control >> 16) & 0x1F) == dci)
        {
            last_cc = completionCode(ev);
            if (!xferOk(ev)) {
                // A bulk completion with a bad code returned null SILENTLY here —
                // no trace line — which is why a failed large read showed no
                // usb.devN.xfer_error at all. Name the code (the foreign-event
                // path stamps the same counter for HID errors).
                const cc = completionCode(ev);
                logx2("xhci: bulk xfer error dci=", dci, " cc=", cc);
                var val: [dbg.VAL_CAP]u8 = undefined;
                var key: [dbg.KEY_CAP]u8 = undefined;
                if (std.fmt.bufPrint(&key, "usb.dev{d}.xfer_error", .{d.dbg_id}) catch null) |k|
                    dbg.set(.usb, k, std.fmt.bufPrint(&val, "cc={d} ({s})", .{ cc, ccName(cc) }) catch "?");
                _ = recoverEndpoint(d.slot, dci, ring);
                return null;
            }
            // Bulk is a single TD: one event ends it, and its residual is authoritative.
            // (No Setup/Data/Status chain here, so no short-packet follow-up event.)
            return ev.status & 0xFFFFFF;
        }
        {
            const saved_cc = last_cc; // see submitCommand's foreign-dispatch note
            dispatchForeign(ev);
            last_cc = saved_cc;
        }
    }
    return null;
}

/// Configure a Mass Storage BOT device: SET_CONFIGURATION, both bulk endpoint
/// contexts, GET MAX LUN, then the msc.zig probe (TEST UNIT READY / INQUIRY /
/// READ CAPACITY + the capacity whitelist). Only ONE stick is driven per boot;
/// a second is skipped loudly.
fn setupMsc(d: *Device, pick: msc.EpPick, config_value: u8) HidResult {
    if (msc_ready) {
        log("xhci:  second mass-storage device — only one stick is driven; skipping\n");
        dvSetStr(cur_pre, "drop", "second MSC device");
        return .unsupported;
    }
    if (!controlOut(d, setupPkt(0x00, 9, config_value, 0, 0))) return .failed;

    if (d.msc_in_ring == null) {
        const ir = Ring.create(DEVICE_RING_TRBS);
        const or_ = Ring.create(DEVICE_RING_TRBS);
        if (ir.phys == 0 or or_.phys == 0) return .failed;
        d.msc_staging = dmaAlloc(1024);
        if (d.msc_staging == 0) return .failed;
        d.msc_in_ring = ir;
        d.msc_out_ring = or_;
    }
    d.msc_in_dci = hid_report.dci(pick.in_addr);
    d.msc_out_dci = hid_report.dci(pick.out_addr);
    d.msc_in_mps = pick.in_mps;
    d.msc_out_mps = pick.out_mps;

    // Configure Endpoint with BOTH bulk pipes (xHCI §6.2.3; interval 0,
    // no burst — Max ESIT is a periodic-endpoint field, left 0 for bulk).
    const max_dci = @max(d.msc_in_dci, d.msc_out_dci);
    clearInputControl(d.input_ctx);
    ctxSet(d.input_ctx, 0, 1, (@as(u32, 1) << @intCast(d.msc_in_dci)) | (@as(u32, 1) << @intCast(d.msc_out_dci)) | 1);
    ctxSlotDw0(d.input_ctx, d.topo.route, max_dci, d.speed, 0);
    ctxSet(d.input_ctx, d.msc_in_dci + 1, 0, 0);
    ctxEp(d.input_ctx, d.msc_in_dci + 1, EP_TYPE_BULK_IN, pick.in_mps, d.msc_in_ring.?.phys);
    ctxSet(d.input_ctx, d.msc_in_dci + 1, 4, pick.in_mps);
    ctxSet(d.input_ctx, d.msc_out_dci + 1, 0, 0);
    ctxEp(d.input_ctx, d.msc_out_dci + 1, EP_TYPE_BULK_OUT, pick.out_mps, d.msc_out_ring.?.phys);
    ctxSet(d.input_ctx, d.msc_out_dci + 1, 4, pick.out_mps);
    const cfg_ev = submitCommand(d.input_ctx, (trb.TYPE_CONFIGURE_ENDPOINT << 10) | (d.slot << 24)) orelse return .failed;
    if (!cmdOk(cfg_ev)) return .failed;

    // GET MAX LUN (class request; a STALL means "LUN 0 only" — Linux
    // tolerates it the same way). kudos uses LUN 0 regardless.
    _ = controlIn(d, setupPkt(0xA1, 0xFE, 0, pick.iface, 1), 1);

    log("xhci:  -> MASS STORAGE configured; probing\n");
    dvSetStr(cur_pre, "kind", "mass-storage");
    return .msc;
}

/// Configure an addressed HID device for polling: walk its configuration
/// descriptor to pick every drivable HID interface (a composite keyboard+mouse
/// yields both), SET_CONFIGURATION, then configureHidInterface for each — which
/// classifies a protocol-0 interface via its report descriptor, issues its
/// Configure Endpoint with the endpoint's real interval/MPS, SET_PROTOCOL(boot)
/// for a boot keyboard, and records the endpoint in `d.hids[slot]`. Does NOT
/// start polling — the first interrupt transfer is queued later by startPolling.
fn setupHid(d: *Device) HidResult {
    // Read the config descriptor header (9 bytes) to learn wTotalLength, then
    // re-read the WHOLE descriptor so EVERY interface is walked. Reading only the
    // first 64 bytes hid any interface past byte 64 — a composite mouse whose
    // pointer interface sits later would never be found.
    if (controlInRetry(d, setupPkt(0x80, 6, 0x0200, 0, 9), 9) == null) return .failed;
    const head: [*]const volatile u8 = @ptrFromInt(d.descbuf);
    const total = @min(@as(u16, head[2]) | (@as(u16, head[3]) << 8), @as(u16, DESCBUF_SIZE));
    const got = controlInRetry(d, setupPkt(0x80, 6, 0x0200, 0, total), total) orelse return .failed;
    const c: [*]const volatile u8 = @ptrFromInt(d.descbuf);
    const config_value = c[5];
    logx("xhci:  config wTotalLength=", total);
    logx("xhci:  config bytes read=", got);
    logBytes("xhci:  cfgdesc=", d.descbuf, @min(got, @as(u16, 96)));

    // Snapshot the transferred bytes through a volatile pointer (descbuf is a
    // DMA target — a plain read folds to the pre-transfer memset) so the pure
    // walk scans plain memory, and ONLY the bytes the transfer actually returned.
    var cfg_buf: [DESCBUF_SIZE]u8 = undefined;
    const walk_end: usize = @min(@as(usize, got), DESCBUF_SIZE); // bytes actually returned
    for (cfg_buf[0..walk_end], 0..) |*b, i| b.* = c[i];
    const cfg = cfg_buf[0..walk_end];

    // Per-interface diag trace (the pick itself is hid_report's pure walk
    // below): every interface's class/subclass/proto stays visible in the
    // netdebug even for devices that end up skipped (webcams, audio).
    if (gate.on(.usb)) {
        var doff: usize = if (cfg.len > 0) cfg[0] else 0;
        while (doff + 9 <= cfg.len and cfg[doff] != 0) : (doff += cfg[doff]) {
            if (cfg[doff + 1] == 4)
                logx("xhci:  iface class<<16|sub<<8|proto=", (@as(u64, cfg[doff + 5]) << 16) | (@as(u64, cfg[doff + 6]) << 8) | cfg[doff + 7]);
        }
    }

    // Walk the configuration descriptor pairing each interrupt-IN endpoint
    // with the interface it actually belongs to, boot interfaces preferred
    // (hid_report.pickHidEndpoint — pure, host-tested; rationale there).
    const picks = hid_report.pickHidEndpoint(cfg);
    logx("xhci:  pick kbd|mouse<<1|cand<<2|kbd2<<3=", @as(u64, @intFromBool(picks.kbd != null)) | (@as(u64, @intFromBool(picks.mouse != null)) << 1) | (@as(u64, @intFromBool(picks.candidate != null)) << 2) | (@as(u64, @intFromBool(picks.kbd2 != null)) << 3));
    if (picks.empty()) {
        // Not HID — a Mass Storage BOT interface (class 08/06/50) takes the
        // storage path instead (msc.zig).
        if (msc.pickBulkEndpoints(cfg)) |pick| {
            return setupMsc(d, pick, config_value);
        }
        log("xhci:  no usable HID interface — skipping device\n");
        dvSetStr(cur_pre, "drop", "no usable HID interface");
        return .unsupported;
    }

    // SET_CONFIGURATION comes BEFORE any class read: interface-recipient
    // requests in the Address state are undefined (USB 2.0 §9.4.3) and a strict
    // real device Request-Errors them — QEMU tolerated the old
    // pre-configuration report-descriptor read, which silently degraded a real
    // G Pro to a boot layout it does not stream (dead cursor). Linux reads the
    // rdesc at probe time, always post-configuration.
    if (!controlOut(d, setupPkt(0x00, 9, config_value, 0, 0))) return .failed;

    // The interfaces to drive, ASCENDING by dci so each per-interface Configure
    // Endpoint only grows the slot's Context Entries (a higher-dci endpoint added
    // second never lowers Context Entries and drops the one before it). A boot
    // device drives its boot interfaces (a composite keyboard+mouse → BOTH); a
    // device with no boot interface drives its single classified candidate.
    var to_drive: [MAX_DEV_HID]hid_report.Pick = undefined;
    var n_drive: usize = 0;
    if (picks.hasBoot()) {
        for ([_]?hid_report.Pick{ picks.kbd, picks.kbd2, picks.mouse }) |maybe| {
            if (maybe) |p| {
                to_drive[n_drive] = p;
                n_drive += 1;
            }
        }
    } else if (picks.candidate) |p| {
        to_drive[0] = p;
        n_drive = 1;
    }
    // Add endpoints ASCENDING by dci (see to_drive's declaration): a higher-dci
    // endpoint added second only grows the slot's Context Entries and never drops
    // a lower one. Insertion sort — n_drive is at most MAX_DEV_HID.
    {
        var i: usize = 1;
        while (i < n_drive) : (i += 1) {
            var j = i;
            while (j > 0 and hid_report.dci(to_drive[j - 1].ep_addr) > hid_report.dci(to_drive[j].ep_addr)) : (j -= 1) {
                const tmp = to_drive[j - 1];
                to_drive[j - 1] = to_drive[j];
                to_drive[j] = tmp;
            }
        }
    }
    // A spec-malformed composite that declares two interfaces on the SAME endpoint
    // number would have the second Configure Endpoint overwrite the first (one dci,
    // one doorbell). After sorting, any duplicate dci is adjacent — drop it, keeping
    // the first. Real composites use distinct endpoints.
    {
        var i: usize = 1;
        while (i < n_drive) {
            if (hid_report.dci(to_drive[i].ep_addr) == hid_report.dci(to_drive[i - 1].ep_addr)) {
                log("xhci:  two HID interfaces share an endpoint — dropping the duplicate\n");
                var k = i;
                while (k + 1 < n_drive) : (k += 1) to_drive[k] = to_drive[k + 1];
                n_drive -= 1;
            } else i += 1;
        }
    }

    var configured: usize = 0;
    for (to_drive[0..n_drive], 0..) |p, slot| {
        switch (configureHidInterface(d, p, slot, !picks.hasBoot())) {
            .ok => configured += 1,
            .unsupported => {}, // a candidate that classified to nothing — skip it
            else => return .failed,
        }
    }
    if (configured == 0) {
        dvSetStr(cur_pre, "drop", "no HID interface could be configured");
        return .unsupported;
    }
    return .ok;
}

/// Configure ONE HID interface as endpoint `slot` of device `d`, registering it
/// in d.hids[slot]: classify a protocol-0 candidate from its report descriptor,
/// learn a mouse's report layout, allocate/reuse this slot's interrupt ring +
/// report buffer, ADD its endpoint via a Configure Endpoint command (endpoints
/// are added one at a time, in the caller's ascending-dci order, so an existing
/// endpoint is never dropped), and SET_PROTOCOL(boot)/SET_IDLE it. `is_candidate`
/// = a protocol-0 interface with no boot protocol; its kind is decided here.
fn configureHidInterface(d: *Device, pick: hid_report.Pick, slot: usize, is_candidate: bool) HidResult {
    var sel = pick;

    // Read the report descriptor ONCE (post-configuration, declared length) —
    // shared by candidate classification and mouse-layout parsing below.
    // Failure stays null: each consumer has its own DEFINED response.
    var rbuf: [DESCBUF_SIZE]u8 = undefined;
    const rdesc: ?[]const u8 = if (sel.kind != .keyboard)
        readReportDescriptor(d, sel.iface, sel.rdesc_len, &rbuf)
    else
        null; // keyboards never need it (boot protocol is SET explicitly)

    // Classify a protocol-0 candidate by its report descriptor: absolute
    // pointer -> tablet, relative pointer -> ordinary mouse (driven like a boot
    // mouse, just no SET_PROTOCOL), no pointer axes -> skip. The relative case
    // must be driven too, not just the tablet: that is what keeps a real non-boot
    // mouse alive. QEMU's boot mouse works either way and hides a miss here.
    // An unreadable descriptor classifies as .none — a protocol-0 interface has
    // no boot protocol to fall back to, so it cannot be driven safely.
    if (is_candidate) {
        const pk = hid_report.classifyPointer(rdesc orelse "");
        logx("xhci:  protocol-0 pointer classify (0=abs,1=rel,2=none)=", @intFromEnum(pk));
        switch (pk) {
            .absolute => sel.kind = .tablet,
            .relative => sel.kind = .mouse,
            .none => {
                // Not a pointer — but a protocol-0 interface has no boot protocol to
                // announce what it IS, so "not a pointer" never meant "not a device".
                // Ask the report descriptor whether it is a keyboard before dropping
                // it, or every non-boot keyboard is thrown away here.
                if (hid_report.isKeyboard(rdesc orelse "")) {
                    log("xhci:  protocol-0 interface is a KEYBOARD (report descriptor)\n");
                    sel.kind = .keyboard;
                } else {
                    log("xhci:  protocol-0 interface is neither pointer nor keyboard — skipping\n");
                    return .unsupported;
                }
            },
        }
    }
    const iface = sel.iface;
    const ep_addr = sel.ep_addr;
    const ep_mps = sel.ep_mps;
    const ep_interval = sel.ep_interval;
    const kind = sel.kind;
    // SET_PROTOCOL(boot) is issued to boot KEYBOARDS only — mice are left in
    // report protocol (Linux usbhid parity; the full rationale is on that
    // decision). A protocol-0 candidate has no boot protocol at all. The one
    // exception is the defined fallback below: a boot-capable mouse whose report
    // descriptor is unreadable is SWITCHED to boot protocol so the boot layout
    // used for it matches what it streams.
    var set_boot_protocol = hid_report.wantsBootProtocol(is_candidate, kind);
    const dci: u32 = hid_report.dci(ep_addr);
    // For a mouse, learn the report layout from its report descriptor — a
    // non-boot device (e.g. the G Pro: 16 button bits then 16-bit X/Y) does not
    // move the cursor if read as an 8-bit boot report. Only meaningful for
    // kind == .mouse.
    const layout = if (kind == .mouse) blk: {
        if (rdesc) |bytes| break :blk hid_report.mouseLayout(bytes);
        // Report descriptor unreadable for a BOOT-capable mouse (a candidate
        // cannot reach here — its unreadable descriptor classified .none
        // above): pair layout and protocol EXPLICITLY rather than guess.
        // SET_PROTOCOL(boot) + boot layout is a defined combination (HID 1.11
        // §7.2.6), whereas boot layout against an unknown report stream decodes
        // as zero motion — a live device with a dead cursor.
        log("xhci:  mouse rdesc unreadable — SET_PROTOCOL(boot) + boot layout\n");
        set_boot_protocol = true;
        break :blk hid_report.MouseLayout{};
    } else hid_report.MouseLayout{};
    if (kind == .mouse) logx("xhci:  mouse layout x_byte=", layout.x_byte);
    if (kind == .mouse) logx("xhci:  mouse layout size_bytes=", layout.size_bytes);
    // The raw report descriptor — so a mis-parsed mouse can be turned into a
    // host test for mouseLayout with the device's ACTUAL bytes.
    if (kind == .mouse) if (rdesc) |rb| logBytes("xhci:  mouse rdesc=", @intFromPtr(rb.ptr), @min(rb.len, 96));
    // Which interface/endpoint a keyboard is actually driven on, and whether it
    // took boot protocol — a keyboard that enumerates but never reports.
    if (kind == .keyboard) logx2("xhci:  keyboard iface=", iface, " dci=", dci);

    // This slot's HID DMA (interrupt ring + report buffer): allocated once and
    // reused by every retried init attempt (resetDeviceBufs re-arms the ring).
    if (d.hid_rings[slot] == null) {
        const hr = Ring.create(DEVICE_RING_TRBS);
        if (hr.phys == 0) return .failed;
        const rep = dmaAlloc(HID_REPORT_BUF);
        if (rep == 0) return .failed;
        d.hid_reports[slot] = rep;
        d.hid_rings[slot] = hr;
    }
    // A freshly-configured endpoint has not proven itself: the Hid's recovery
    // state defaults (seen_report=false, rekicks=0, resurrected=false) leave it
    // alone until it delivers a report. A resurrect re-arm (queueHid, not this)
    // does NOT reset those: that endpoint already proved live once.
    d.hids[slot] = .{
        .kind = kind,
        .ring = d.hid_rings[slot].?,
        .dci = dci,
        .report = d.hid_reports[slot],
        .mps = ep_mps,
        .layout = layout,
    };
    const hid = &d.hids[slot].?;

    // (SET_CONFIGURATION already issued above, before the class reads.)
    clearInputControl(d.input_ctx);
    ctxSet(d.input_ctx, 0, 1, (@as(u32, 1) << @intCast(dci)) | 1);
    // Slot DW0: the device's REAL route string | Context Entries = dci (highest
    // valid endpoint) | speed. Rebuilding with route 0 mis-describes a
    // hub-attached device (the real machine's mouse/keyboard hang off a hub);
    // Linux instead copies the live slot context (xhci_slot_copy) so the route
    // is always preserved. DW1 (root port) and DW2 (TT fields) still hold the
    // values addressDevice wrote into this same input context.
    ctxSlotDw0(d.input_ctx, d.topo.route, dci, d.speed, 0);

    // Interrupt-IN endpoint context (xHCI §6.2.3). All fields below are required
    // on real HW or Configure Endpoint is rejected (Parameter/Bandwidth Error):
    //   DW0: Interval (16-23, from bInterval) | Max ESIT Payload Hi (24-31)
    //   DW1: EP Type=7 (Interrupt IN) | CErr=3 (1-2) | Max Packet Size (16-31)
    //   DW2/3: TR Dequeue Pointer | DCS=1
    //   DW4: Average TRB Length (0-15) | Max ESIT Payload Lo (16-31)
    // For a boot/HID endpoint (no burst, no mult) Max ESIT Payload == max packet.
    const interval = port_fsm.endpointInterval(d.speed, ep_interval);
    const max_esit = ep_mps; // mps * (burst+1) * mult; burst=mult=0 for HID
    const ep_idx = dci + 1;
    ctxSet(d.input_ctx, ep_idx, 0, (interval << 16) | ((max_esit >> 16) << 24));
    ctxEp(d.input_ctx, ep_idx, EP_TYPE_INTERRUPT_IN, ep_mps, hid.ring.phys); // DW1 + TR dequeue ptr
    ctxSet(d.input_ctx, ep_idx, 4, ep_mps | ((max_esit & 0xFFFF) << 16)); // avg TRB len | ESIT lo

    const cfg_ev = submitCommand(d.input_ctx, (trb.TYPE_CONFIGURE_ENDPOINT << 10) | (d.slot << 24)) orelse return .failed;
    if (!cmdOk(cfg_ev)) return .failed;

    // SET_PROTOCOL (class request, req 0x0B) selects which report format the
    // interface streams. It MUST agree with the layout the driver decodes with,
    // and the firmware/BIOS may have left a boot device in EITHER protocol:
    //   - boot keyboards (set_boot_protocol): SET_PROTOCOL(boot=0) — decoded with
    //     the fixed 8-byte boot layout.
    //   - a mouse/tablet whose layout came from the REPORT descriptor: force
    //     SET_PROTOCOL(report=1). Without this a boot-capable mouse the firmware
    //     left in BOOT protocol streams 3-byte [buttons,X8,Y8] reports into the
    //     report-protocol layout (16-bit X at byte 2), so Y drives X and the
    //     cursor scrambles — the scroll wheel appears to move the pointer.
    //     A device already in report protocol treats this as a no-op. Linux
    //     usbhid sets protocol explicitly for exactly this reason.
    if (set_boot_protocol) {
        _ = controlOut(d, setupPkt(0x21, 0x0B, 0, iface, 0));
    } else {
        _ = controlOut(d, setupPkt(0x21, 0x0B, 1, iface, 0));
    }
    // SET_IDLE(duration=0, report=0): report only on change. Linux usbhid sends
    // this to EVERY HID interface (hid-core.c usbhid_start); some devices stay
    // silent without it. HID 1.11 §7.2.4; a STALL here is benign (device has no
    // idle state — awaitXfer recovers EP0).
    _ = controlOut(d, setupPkt(0x21, 0x0A, 0, iface, 0));
    log(switch (hid.kind) {
        .mouse => "xhci:  -> MOUSE ready\n",
        .keyboard => "xhci:  -> KEYBOARD ready\n",
        .tablet => "xhci:  -> TABLET ready\n",
    });
    // NOTE: the interrupt endpoint is fully configured, but the first interrupt
    // transfer is deliberately NOT queued here. Polling is started for every
    // device at once by startPolling() AFTER enumerate() finishes (deferred
    // interrupt polling). Ringing the doorbell now would
    // let this device stream interrupt reports onto the shared event ring while a
    // LATER device is still enumerating, starving that device's control-transfer
    // completions (awaitXfer) and getting it silently skipped on real hardware.
    return .ok;
}

/// Start interrupt-IN polling for every enumerated HID device. Called once, after
/// enumerate() has set up all devices, so no endpoint streams reports onto the
/// shared event ring during enumeration. devs[] holds copies, so
/// queueHid must run against the stored device (its ring/report DMA), not a stale
/// stack-local — bringUp already copied each ready device into devs[ndev].
fn startPolling() void {
    for (devs[0..ndev]) |*d| queueAllHids(d);
    logx("xhci: polling started devices=", ndev);
}

/// Queue one interrupt-IN transfer for `hid` (a Normal TRB into its report
/// buffer, IOC + Interrupt-on-Short-Packet) and ring its endpoint's doorbell.
/// Re-armed after every report so the endpoint keeps delivering.
fn queueHid(slot_id: u32, hid: *Hid) void {
    hid.last_event_ms = timer.millis();
    cnt_hid_queued.inc();
    hid.ring.push(hid.report, hid.mps, ctrl(TRB_NORMAL, TRB_IOC | TRB_ISP));
    ringDoorbell(slot_id, hid.dci);
}

/// Arm every configured HID endpoint of `d` (a composite device drives two).
fn queueAllHids(d: *Device) void {
    for (&d.hids) |*maybe| if (maybe.*) |*hid| queueHid(d.slot, hid);
}

// ---- The hub seam ----
// The hub class (hub.zig) drives a hub's downstream ports through hub.Hub.VTable
// and never imports this driver — that one-way edge is what breaks the
// hub.Hub.setup <-> bringUp recursion (a hub's child may be a hub) out of the module
// graph. ctx in every per-device entry is the hub's *Device record.

fn hubControlIn(ctx: *anyopaque, setup: u64, len: u16) ?u16 {
    return controlIn(@ptrCast(@alignCast(ctx)), setup, len);
}
fn hubControlOut(ctx: *anyopaque, setup: u64) bool {
    return controlOut(@ptrCast(@alignCast(ctx)), setup);
}
fn hubControlInRetry(ctx: *anyopaque, setup: u64, len: u16) ?u16 {
    return controlInRetry(@ptrCast(@alignCast(ctx)), setup, len);
}
fn hubDescByte(ctx: *anyopaque, i: usize) u8 {
    const d: *Device = @ptrCast(@alignCast(ctx));
    return descByte(d, i);
}
fn hubSetPowerOnGoodMs(ctx: *anyopaque, ms: u64) void {
    const d: *Device = @ptrCast(@alignCast(ctx));
    d.pwr_on_good_ms = ms;
}
fn hubBringUpChild(topo: hub.Topo, first_speed: u32, parent_ctx: *anyopaque) bool {
    return bringUp(topo, first_speed, @as(*Device, @ptrCast(@alignCast(parent_ctx))));
}

const hub_vtable = hub.Hub.VTable{
    .controlIn = hubControlIn,
    .controlOut = hubControlOut,
    .controlInRetry = hubControlInRetry,
    .descByte = hubDescByte,
    .setPowerOnGoodMs = hubSetPowerOnGoodMs,
    .submitCommand = submitCommand,
    .cmdOk = cmdOk,
    .ctxSet = ctxSet,
    .ctxSlotDw0 = ctxSlotDw0,
    .bringUpChild = hubBringUpChild,
    .log = log,
    .logx = logx,
    .logx2 = logx2,
    .dvSetStr = dvSetStr,
    .dvSet = dvSet,
    .dvSetHex = dvSetHex,
    .dvSetCc = dvSetCc,
};

/// View an (already addressed) device as a hub through the seam: its stable
/// slot facts plus the vtable above. Built fresh at each use so the facts are
/// read after addressDevice has filled them in.
fn hubView(d: *Device) hub.Hub {
    return .{ .ctx = d, .vtable = &hub_vtable, .slot = d.slot, .speed = d.speed, .input_ctx = d.input_ctx, .dbg_id = d.dbg_id, .topo = d.topo };
}

/// Drain the event ring to empty. Called after a control-transfer timeout so a
/// late TD completion can't desync the shared ring for the next transfer.
fn drainEvents() void {
    // DISPATCH them, never discard. Throwing these away silently killed devices: a
    // HID interrupt endpoint is only re-armed by queueHid from handleHidEvent, so an
    // eaten completion means that keyboard/mouse is never re-queued and goes dead for
    // the rest of the session — and an eaten port-change event loses a hotplug for good.
    while (nextEventReady()) |ev| dispatchForeign(ev);
}

/// The USB control SETUP packet the Setup-stage TRB carries as immediate data
/// (USB 2.0 §9.3). Packed by xhci_ctx (pure, host-tested).
const setupPkt = xhci_ctx.setupPkt;

/// Non-blocking peek/pop of the module-global event ring: the next event TRB if
/// one is ready, else null (also advances ERDP — see EventRing.next).
fn nextEventReady() ?trb.Trb {
    return events.next();
}

/// Snapshot the interrupt-IN DMA report buffer into a plain array the pure
/// decoders (hid_report.zig) can take as a slice. The copy goes through a
/// volatile pointer: the device DMAs the bytes, so a plain read folds to
/// stale data; the EventRing.next lfence has already ordered these reads
/// against the Transfer Event.
fn snapshotReport(report: usize) [HID_REPORT_BUF]u8 {
    const r: [*]const volatile u8 = @ptrFromInt(report);
    var buf: [HID_REPORT_BUF]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = r[i];
    return buf;
}

/// Translate one HID keyboard boot report into key events. The 6-slot diff is
/// hid_report.decodeKeyboard (pure, host-tested); this turns each edge it found
/// into an injection: F12 and friends as named keys, characters via hidToAscii
/// under the current shift state, and EVERY edge — including the releases and
/// the modifiers, which type nothing — as a Linux key code for whoever needs
/// the whole keyboard rather than the characters it produces (a guest's input
/// stack does).
fn processKeyboard(hid: *Hid) void {
    cnt_kbd_reports.inc();
    const rep = snapshotReport(hid.report);
    const kp = hid_report.decodeKeyboard(rep[0..], hid.last_keys, hid.last_mods) orelse return;
    for (kp.keys[0..kp.count]) |u| {
        const evdev = keyboard.hidToEvdev(u);
        // F1 (HID usage 0x3A) / F10 (0x43) / F12 (0x45): named keys with no ASCII,
        // injected bypassing the ascii!=0 gate. The last_keys press-diff already
        // makes these edge-triggered.
        if (u == 0x3A) {
            _ = keyboard.inject(.{ .ascii = 0, .key = .f1, .evdev = evdev });
        } else if (u == 0x43) {
            _ = keyboard.inject(.{ .ascii = 0, .key = .f10, .evdev = evdev });
        } else if (u == 0x45) {
            _ = keyboard.inject(.{ .ascii = 0, .key = .f12, .evdev = evdev });
        } else {
            const ascii = keyboard.hidToAscii(u, kp.shift);
            // A key that types no character still went down: it carries no ascii
            // and no name, and reaches only the consumers that read key codes.
            _ = keyboard.inject(.{ .ascii = ascii, .key = .none, .evdev = evdev });
        }
    }
    // Releases type nothing by definition, so they carry no ascii at all.
    for (kp.released[0..kp.released_count]) |u| {
        _ = keyboard.inject(.{ .ascii = 0, .key = .none, .evdev = keyboard.hidToEvdev(u), .down = false });
    }
    // Modifiers live in the report's bitmap, never in its key array: each bit
    // that changed is one key edge of its own.
    const changed = kp.mods ^ kp.last_mods;
    var bit: u3 = 0;
    while (true) : (bit += 1) {
        const mask = @as(u8, 1) << bit;
        if (changed & mask != 0) {
            const usage: u8 = keyboard.MOD_USAGE_FIRST + @as(u8, bit);
            _ = keyboard.inject(.{
                .ascii = 0,
                .key = .none,
                .evdev = keyboard.hidToEvdev(usage),
                .down = kp.mods & mask != 0,
            });
        }
        if (bit == 7) break;
    }
    hid.last_keys = kp.next_last; // remember this report for the next diff
    hid.last_mods = kp.mods;
}

/// Relative mouse: boot [buttons, dx, dy] by default, or wherever the report
/// descriptor put the fields — the bytes→delta math (sign extension, 16-bit
/// assembly, Report-ID shift) is hid_report.decodeMouse (pure, host-tested).
fn processMouse(hid: *Hid, report_len: usize) void {
    cnt_mouse_reports.inc();
    const rep = snapshotReport(hid.report);
    // Decode only the bytes the device actually transferred. Passing the whole
    // 64-byte DMA buffer defeats decodeMouse's short-report fallback: a mouse whose
    // wire report is shorter than its descriptor declares (G Pro: 4-byte
    // Report-ID-8 vs an 8-byte 16-bit descriptor) would be read with the long
    // layout over stale buffer tail — a scrambled cursor.
    const n = @min(report_len, HID_REPORT_BUF);
    const ev = hid_report.decodeMouse(rep[0..n], hid.layout) orelse return;
    imouse.inject(.{ .dx = ev.dx, .dy = ev.dy, .buttons = ev.buttons, .t_tsc = tsc.rdtsc() });
}

/// Absolute pointer (usb-tablet): reported as an ABSOLUTE position scaled to
/// the framebuffer; the desktop sets the cursor there directly, so it stays
/// 1:1 with the host pointer (no delta drift, no wrap). The clamp/scale math
/// (incl. the >= 0x8000 wrap guard) is hid_report.decodeTablet (pure,
/// host-tested).
fn processTablet(hid: *Hid) void {
    // The tablet reports a 0..0xFFFF logical position; scaling it into pixels needs the
    // screen extents, which the pointer contract carries (imouse.screen_w/h). Zero means
    // the screen is not up yet — drop the event rather than scale against nothing.
    if (imouse.screen_w == 0 or imouse.screen_h == 0) return;
    const rep = snapshotReport(hid.report);
    const ev = hid_report.decodeTablet(rep[0..], hid.mps, imouse.screen_w, imouse.screen_h) orelse return;
    imouse.inject(.{ .dx = 0, .dy = 0, .buttons = ev.buttons, .abs = .{ .x = ev.x, .y = ev.y }, .t_tsc = tsc.rdtsc() });
}

/// Snapshot of the controller + event-ring state at the last Address Device failure,
/// surfaced on the heartbeat line because the trace that carries it gets dropped.
pub var dbg_addr_usbsts: u32 = 0;
pub var dbg_addr_evdeq: u32 = 0;
pub var dbg_addr_evcyc: u32 = 0;
pub var dbg_addr_evctrl: u32 = 0;

// HID report + liveness counters (kernel/debug/counter.zig; registered in init(),
// flushed on the trace heartbeat, dumpable on demand via KMR1 OP_STATS). The
// invariant `hid.queued` watches: every consumed interrupt-IN completion re-queues
// exactly one TRB (queueHid), so it leads the report counters by exactly the number
// of armed endpoints. Reports frozen with `hid.queued` frozen too = a completion was
// consumed without a re-queue (the endpoint is dead by our own hand); `hid.queued`
// leading = the TRB is armed and the completion never arrived (controller/device
// side). `hid.orphan` counts Transfer Events no armed HID endpoint claimed — a
// silent drop before (the no-silent-drops rail); `hid.badcc` counts failed
// completions (the recovery path).
pub var cnt_kbd_reports = counter.Counter{ .mod = .usb, .name = "kbd_reports" };
/// Mirror of imouse.dropped_events (spec R59): the iface module is pure (host-
/// compiled, cannot import the counter registry), so its overflow tally is
/// synced into a registered counter here, at the consumer that pumps it.
var cnt_mouse_drops = counter.Counter{ .mod = .usb, .name = "mouse.drops" };
pub var cnt_mouse_reports = counter.Counter{ .mod = .usb, .name = "mouse_reports" };
var cnt_hid_queued = counter.Counter{ .mod = .usb, .name = "hid.queued" };
var cnt_hid_orphan = counter.Counter{ .mod = .usb, .name = "hid.orphan" };
var cnt_hid_badcc = counter.Counter{ .mod = .usb, .name = "hid.badcc" };
/// Benign "Stopped" transfer echoes ignored (the Stop Endpoint command's own
/// completion for the in-flight TRB) — climbs with recoveries, never a fault.
var cnt_hid_stopped_echo = counter.Counter{ .mod = .usb, .name = "hid.stopped_echo" };
var cnt_hid_rekick = counter.Counter{ .mod = .usb, .name = "hid.rekick" };
/// Full endpoint resurrections (Reset Endpoint + Set TR Dequeue + re-arm) taken
/// after the doorbell re-kick proved ineffective — and the failures thereof.
var cnt_hid_resurrect = counter.Counter{ .mod = .usb, .name = "hid.resurrect" };
var cnt_hid_resurrect_fail = counter.Counter{ .mod = .usb, .name = "hid.resurrect_fail" };
// Every event TRB ever consumed off the (single, shared) event ring. The value
// mod EVENT_RING_TRBS is the driver's dequeue index — a stream that freezes at a
// suspicious residue (the segment boundary) convicts the ring's wrap/full
// handling rather than any one endpoint.
var cnt_ev_consumed = counter.Counter{ .mod = .usb, .name = "ev.consumed" };
// The same stream classified by TRB type — a flow that continues in one class
// while another freezes names the layer that died (endpoint vs port vs command).
var cnt_ev_xfer = counter.Counter{ .mod = .usb, .name = "ev.xfer" };
var cnt_ev_psc = counter.Counter{ .mod = .usb, .name = "ev.psc" };
var cnt_ev_cmd = counter.Counter{ .mod = .usb, .name = "ev.cmd" };
var cnt_ev_other = counter.Counter{ .mod = .usb, .name = "ev.other" };

// Defensive doorbell re-kick fuse for an armed-but-silent interrupt-IN endpoint.
// The counters proved the failure shape on the emulated controller: the consume→
// re-queue cycle intact (`hid.queued` leading the report counters by exactly the
// number of armed endpoints), a TRB armed, and completions simply stopping mid-
// burst — the endpoint parked on a NAK whose wake-up was lost. Ringing the
// doorbell again is spec-legal at any time (xHCI §4.7: a doorbell for a running
// endpoint just tells the xHC to re-examine the transfer ring — a no-op when
// nothing changed) and revives a parked endpoint that still holds queued device
// events. Paced by this fuse so an idle keyboard costs four MMIO writes a second.
const HID_REKICK_MS: u64 = 250;
/// Ineffective doorbell re-kicks before escalating to the full endpoint
/// recovery (Reset Endpoint + Set TR Dequeue + re-arm): 4 kicks = one second
/// of provable silence — long enough that a genuinely idle device (no typing)
/// is never reset, short enough that a dead keyboard revives before a user
/// concludes the machine hung.
const HID_REKICK_ESCALATE: u32 = 4;

/// What USB actually found, for the heartbeat status line (fileserv's PING sink).
/// Read-only: a liveness probe must not touch the controller. Unused by the
/// `-Dheartbeat` bring-up image, which does not initialise USB at all — it is here
/// for the next step, where the heartbeat reports keyboard/mouse/disk presence.
/// (Named `deviceStatus`, not `status`: this file has locals named `status` all
/// over the TRB/port code, and Zig rejects the shadowing.)
pub const Status = struct {
    keyboard: bool,
    mouse: bool,
    usbdisk: bool,
    kbd_reports: u64,
    mouse_reports: u64,
    devices: usize,
};

pub fn deviceStatus() Status {
    var kbd = false;
    var mouse = false;
    for (devs[0..ndev]) |*d| {
        for (&d.hids) |*maybe| if (maybe.*) |h| switch (h.kind) {
            .keyboard => kbd = true,
            .mouse, .tablet => mouse = true,
        };
    }
    return .{
        .keyboard = kbd,
        .mouse = mouse,
        .usbdisk = msc_ready,
        .kbd_reports = cnt_kbd_reports.v,
        .mouse_reports = cnt_mouse_reports.v,
        .devices = ndev,
    };
}

// First-reports tap: the first few RAW reports of each
// HID device stream out as `usb.devN.reportK` dbg lines, so a real mouse's
// actual on-wire report layout is verifiable over netdebug against the layout
// enumeration parsed for it — the discriminating fact for the native-boot
// dead-mouse bug (a layout/protocol mismatch parses real reports as no-ops).
const FIRST_REPORTS_DUMPED = 4;

/// Emit one raw report as `usb.devN.reportK = xx xx xx ...` (first 8 bytes of
/// the interrupt-IN DMA buffer — boot-style reports fit well within).
fn dumpReport(d: *Device, hid: *const Hid) void {
    const r: [*]const volatile u8 = @ptrFromInt(hid.report);
    var key: [dbg.KEY_CAP]u8 = undefined;
    var val: [dbg.VAL_CAP]u8 = undefined;
    const k = std.fmt.bufPrint(&key, "usb.dev{d}.report{d}", .{ d.dbg_id, d.reports_dumped }) catch return;
    const v = std.fmt.bufPrint(&val, "{x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
        r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
    }) catch return;
    dbg.set(.usb, k, v);
}

// Liveness heartbeat cadence for the `usb.reports` dbg line: proves the HID
// poll loop is running and shows whether report counts move when the user
// moves the mouse / types — the difference between "no reports arriving" and
// "reports arriving but parsed to nothing" is the whole diagnosis.
const REPORT_HEARTBEAT_MS: u64 = 5000;
var last_heartbeat_ms: u64 = 0;

// Root ports with a latched Port Status Change Event, awaiting a re-scan
// (bit N-1 = port N). Latched by any event consumer (poll's drain loop, or
// awaitXfer/submitCommand seeing a PSCE mid-transfer) and processed by poll()
// after the drain — enumeration is event-driven forever, not one-shot.
var pending_ports: u32 = 0;

// Root ports with a successfully-enumerated device (bit N-1 = port N) — HID or
// hub, polled or transient. A PSCE on an owned, still-connected port is a no-op
// (the boot resets themselves latch PSCEs; without ownership tracking, a
// childless hub would be re-enumerated into a duplicate slot on the first
// post-boot poll). Cleared on disconnect.
var root_port_owned: u32 = 0;

/// Set/clear the ownership bit for a root port (ports 1..32).
fn markRootPort(port: u32, owned: bool) void {
    const bit = port_fsm.portBit(port);
    if (bit == 0) return;
    if (owned) root_port_owned |= bit else root_port_owned &= ~bit;
}

/// Route one Transfer Event to the HID device that owns its slot: process the
/// report (or recover the halted endpoint) and re-queue the next transfer.
/// Shared by poll()'s drain loop and the foreign-event path in awaitXfer/
/// submitCommand — during post-boot re-enumeration, live devices keep streaming
/// on the shared event ring, and dropping one of their completions without a
/// re-queue would silently stop that device's polling forever.
fn handleHidEvent(ev: trb.Trb) void {
    const slot = (ev.control >> 24) & 0xFF;
    const ep = (ev.control >> 16) & 0x1F;
    for (devs[0..ndev]) |*d| {
        if (d.slot != slot) continue;
        // Match the ENDPOINT too, across the device's HID interrupt endpoints (a
        // composite device drives two). A late EP0 control completion carries this
        // slot id but no hid.dci matches — without the dci check it was parsed as
        // an interrupt-IN report, injecting garbage motion and resetting the wrong
        // endpoint over a fault that happened on EP0.
        for (&d.hids) |*maybe| {
            const hid = &(maybe.* orelse continue);
            if (ep != hid.dci) continue;
            // An event on this endpoint: the doorbell path produced SOMETHING.
            hid.rekicks_since_event = 0;
            // Success and Short Packet are both valid reports (boot reports are
            // short); any other code is a failed transfer — don't parse stale data.
            if (xferOk(ev)) {
                // Only a GENUINE report re-arms the resurrect escalation: the Stop
                // Endpoint command itself completes the stopped TRB with a Transfer
                // Event (CC=Stopped), and clearing the flag on that echo turned
                // one recovery into a reset-per-second loop.
                hid.resurrected = false;
                // This endpoint has now PROVEN itself live — recovery may act on it
                // if it later falls silent mid-stream. (An endpoint that has never
                // reported is left alone: it is indistinguishable from a healthy
                // idle keyboard nobody has typed on.)
                hid.seen_report = true;
                if (d.reports_dumped < FIRST_REPORTS_DUMPED) {
                    dumpReport(d, hid);
                    d.reports_dumped += 1;
                }
                // Actual bytes the device wrote = queued length (hid.mps, see
                // queueHid) minus the Transfer Event residual (status low 24 bits =
                // bytes NOT transferred). A short report (Interrupt-on-Short-Packet
                // is armed) carries its true residual, so a mouse streaming a report
                // shorter than its descriptor declares is decoded at its real length.
                const residual = ev.status & 0xFFFFFF;
                const got: usize = hid.mps -| residual;
                switch (hid.kind) {
                    .mouse => processMouse(hid, got),
                    .tablet => processTablet(hid),
                    .keyboard => processKeyboard(hid),
                }
            } else if (xferStopped(ev)) {
                // The benign echo of a Stop Endpoint the recovery path itself
                // issued: no data, and the endpoint is already being re-armed by
                // that recovery. Treating it as a fault (below) re-stopped the
                // just-re-armed endpoint on every recovery — the endless
                // self-inflicted reset that froze the HID keyboard/mouse on
                // lemon's controller. Consume it and move on.
                cnt_hid_stopped_echo.inc();
                return;
            } else {
                cnt_hid_badcc.inc();
                logx("xhci: bad xfer cc<<8|slot=", (((ev.status >> 24) & 0xFF) << 8) | slot);
                var val: [dbg.VAL_CAP]u8 = undefined;
                var key: [dbg.KEY_CAP]u8 = undefined;
                if (std.fmt.bufPrint(&key, "usb.dev{d}.xfer_error", .{d.dbg_id}) catch null) |k|
                    dbg.set(.usb, k, std.fmt.bufPrint(&val, "cc={d}", .{(ev.status >> 24) & 0xFF}) catch "?");
                // Deferred while a command is in flight: recoverEndpoint issues commands
                // of its own, and a nested command eats the outer one's completion event
                // (see cmd_in_flight). The flag makes the deferral REAL: poll() retries
                // the recovery once the command ring is free. Returning without it left
                // the endpoint dead — no TRB armed, nothing ever re-queued it.
                if (cmd_in_flight) {
                    hid.recover_pending = true;
                    return;
                }
                // Any non-OK completion (STALL, transaction error once CErr is
                // exhausted, babble) may have HALTED this interrupt endpoint:
                // the xHC runs no further TRBs until it is reset. Recover it
                // (Reset Endpoint + Set TR Dequeue) before re-queuing, or the
                // device is dead for the rest of the session. If recovery
                // fails, skip the re-queue — ringing the doorbell on a
                // still-halted endpoint does nothing.
                if (!recoverEndpoint(d.slot, hid.dci, &hid.ring)) {
                    log("xhci: endpoint recovery failed — device stalled\n");
                    var key2: [dbg.KEY_CAP]u8 = undefined;
                    if (std.fmt.bufPrint(&key2, "usb.dev{d}.stalled", .{d.dbg_id}) catch null) |k2|
                        dbg.set(.usb, k2, "endpoint recovery failed");
                    return;
                }
            }
            queueHid(d.slot, hid);
            return;
        }
    }
    // A Transfer Event no armed HID endpoint claims. Late EP0 completions land here
    // legitimately (awaitXfer gave up first); anything else is a consumed completion
    // whose endpoint will never be re-armed — the counter makes that visible.
    cnt_hid_orphan.inc();
}

/// Latch a Port Status Change Event's port (param bits 31:24) for the next
/// processPortChanges() pass. Latch-only — never re-enters enumeration — so it
/// is safe from any depth (awaitXfer inside an ongoing bringUp included).
fn latchPortChange(ev: trb.Trb) void {
    const port: u32 = @intCast((ev.param >> 24) & 0xFF);
    pending_ports |= port_fsm.portBit(port); // out-of-range port latches nothing
}

/// Handle events that arrive while some caller is waiting for a specific
/// completion (awaitXfer / submitCommand): live HID reports are dispatched +
/// re-queued, port changes are latched. Anything else is dropped as before.
fn dispatchForeign(ev: trb.Trb) void {
    switch (trbType(ev)) {
        TRB_TRANSFER_EVENT => handleHidEvent(ev),
        TRB_PORT_STATUS_CHANGE => latchPortChange(ev),
        else => {},
    }
}

/// Remove every polled device on a root port after a disconnect: Disable the
/// slot (releasing it to the xHC) and recycle the DMA buffer set, then compact
/// devs[]. Their in-flight interrupt TRBs die with the slot.
fn removeDevicesOnRootPort(port: u32) void {
    // If the driven mass-storage stick was on this port it is now gone: clear the
    // "one stick already driven" latch so a re-plugged stick re-enumerates and is
    // driven again. Without this, msc_ready stays true forever and the
    // replacement is refused as a "second MSC device" (setupMsc) — the stick
    // never self-heals across an unplug. msc_device is the stable copy taken at
    // ok_msc, so its root_port is the driven stick's.
    if (msc_ready and msc_device.topo.root_port == port) {
        msc_ready = false;
        log("xhci: mass-storage stick unplugged — a re-plug will be driven again\n");
    }
    var i: usize = 0;
    while (i < ndev) {
        if (devs[i].topo.root_port == port) {
            logx("xhci: device removed, slot=", devs[i].slot);
            disableSlot(&devs[i]);
            releaseDeviceBufs(&devs[i]);
            ndev -= 1;
            devs[i] = devs[ndev];
        } else {
            i += 1;
        }
    }
}

/// Re-scan every root port with a latched status change (Linux hub_event for
/// the root hub): a new connect is debounced + reset + enumerated — the SAME
/// bringUp path as boot, hubs included — and its HID devices start polling
/// immediately; a disconnect removes the port's devices. A port that fails
/// simply waits for its next change event, exactly like Linux.
fn processPortChanges() void {
    while (pending_ports != 0) {
        const bit: u5 = @intCast(@ctz(pending_ports));
        pending_ports &= ~(@as(u32, 1) << bit);
        const port: u32 = @as(u32, bit) + 1;
        if (port > max_ports) continue;
        const a = op_base + OP_PORTSC + (port - 1) * 0x10;
        const v = r32(a);
        // Ack every change bit we just observed (write-1-to-clear) so the port
        // can post a fresh PSCE for the next change.
        w32(a, port_fsm.portscNeutral(v) | (v & port_fsm.PORTSC_CHANGE_MASK));
        const have = (root_port_owned & port_fsm.portBit(port)) != 0;
        logx2("xhci: port change, port=", port, " portsc=", v);
        // (ccs, owned) → action, incl. the owned-port no-op that prevents
        // duplicate-slot re-enumeration (port_fsm.portChangeAction).
        switch (port_fsm.portChangeAction((v & port_fsm.PORTSC_CCS) != 0, have)) {
            .enumerate => {
                // A port that has failed to enumerate PORT_GIVE_UP times in a row is
                // DONE. Its change bits are still acked above (so the controller is
                // not left with a stuck PSCE), we simply stop trying to bring it up.
                // Without this, a port that can never enumerate re-arms a change on
                // every failure and is retried forever — a livelock that consumed a
                // device slot per attempt (lemon reached dev113) and starved the
                // session loop of everything else.
                if (port_fail[port] >= PORT_GIVE_UP) continue;

                // A FRESH budget for THIS attempt. enum_deadline_ms is set once, by
                // enumerate(), at boot — so a hotplug arriving later measured itself
                // against a deadline that had already passed and every attempt
                // reported "budget exhausted" INSTANTLY, at full speed. The budget is
                // meant to bound one enumeration, not to expire the feature.
                enum_deadline_ms = timer.millis() + ENUM_BUDGET_MS;

                // If the port is ALREADY enabled and trained to U0 (PED=1, PLS=U0,
                // CCS=1 — rootResetComplete), the device finished its reset on its
                // own: a slow composite device (the boot keyboard, its MCU still
                // coming up when the connect first posts) reaches this state a beat
                // later, already enabled at its speed. Re-resetting it here knocks a
                // good port back to nothing and the still-initializing device fails
                // to re-establish — so it never enumerates. Address it IN PLACE with
                // the speed the port already reports; only a not-yet-enabled port is
                // reset. Scoped to this exact state, so a normal fresh connect (PED=0)
                // still takes the reset path unchanged.
                const pr = if (port_fsm.rootResetComplete(v))
                    PortResult{ .speed = (v >> 10) & 0xF, .portsc = v, .result = "already enabled" }
                else
                    resetPort(port); // debounce + retried reset
                recordRootPort(port, pr.portsc, pr.result);
                const before = ndev;
                var enumerated = false;
                if (pr.speed != 0) {
                    enumerated = bringUp(.{ .route = 0, .root_port = port, .parent_slot = 0, .parent_port = 0, .tier = 0 }, pr.speed, null);
                    // Boot defers polling until all devices are up;
                    // a late device has no such phase — start it now.
                    for (devs[before..ndev]) |*nd| queueAllHids(nd);
                }
                // The verdict comes from the bring-up OUTCOME, never from `ndev` —
                // that counts HID devices only, so a hub or a USB stick coming up
                // perfectly would register as a port FAILURE. See `bringUp`.
                const verdict = port_fsm.portVerdict(enumerated, port_fail[port]);
                port_fail[port] = port_fsm.portFailNext(verdict, port_fail[port]);
                if (verdict == .give_up)
                    logx("xhci: port gave up after repeated enumeration failures, port=", port);
            },
            .remove => {
                markRootPort(port, false);
                removeDevicesOnRootPort(port);
                // The device left; the port is innocent. Without this, unplugging
                // burned a failure each time and the port could be condemned by
                // nothing more than being used.
                port_fail[port] = 0;
            },
            .ignore => {},
        }
    }
}

/// Re-attempt any root port that is connected and ENABLED (rootResetComplete) but
/// not yet owned — a leaf device whose bring-up was not ready when its connect was
/// first handled. THE BOOT KEYBOARD is exactly this: it posts its connect while its
/// HID interface is still initializing, the one attempt at connect-time fails
/// (.unsupported, not owned), and no fresh PSCE follows to trigger a retry. This
/// re-attempts it — addressing it IN PLACE, with NO reset (an enabled port needs
/// none, and skipping the reset is what makes the retry safe: no reset means no live
/// subtree to knock down, the mistake that broke the stick). No port_fail here: this
/// runs only inside the bounded pre-present USB settle, where a slow device is
/// expected to need several tries; it succeeds (and becomes owned) the moment its
/// interface is ready. Meant for that settle only — NOT the steady session loop,
/// where a blocking bring-up would drop a frame.
pub fn retryLatePorts() void {
    if (!controller_up) return;
    var port: u32 = 1;
    while (port <= max_ports) : (port += 1) {
        if (root_port_owned & port_fsm.portBit(port) != 0) continue; // already up
        const a = op_base + OP_PORTSC + (port - 1) * 0x10;
        const v = r32(a);
        if (!port_fsm.rootResetComplete(v)) continue; // only connected+enabled+U0 ports
        const speed = (v >> 10) & 0xF;
        if (speed == 0) continue;
        enum_deadline_ms = timer.millis() + ENUM_BUDGET_MS;
        const before = ndev;
        _ = bringUp(.{ .route = 0, .root_port = port, .parent_slot = 0, .parent_port = 0, .tier = 0 }, speed, null);
        for (devs[before..ndev]) |*nd| queueAllHids(nd);
    }
}

/// Drain the event ring: HID interrupt transfers are processed and re-queued;
/// root-port status changes are latched, then re-scanned. Called from the main
/// loop — including with zero devices, so a late first connect still enumerates.
pub fn poll() void {
    if (!controller_up) return;
    // Sync the pure mouse ring's overflow tally into the registry (R59).
    if (imouse.dropped_events > cnt_mouse_drops.v) cnt_mouse_drops.add(imouse.dropped_events - cnt_mouse_drops.v);
    // PHASE 1 — the event-ring drain, under the IRQ-OFF lock. Short, bounded, and
    // free of any wait: exactly what an interrupts-masked region may contain.
    {
        // Mutual exclusion with an in-flight BOT transaction (msc transport):
        // both sides pop the SHARED event ring (design note at usb_lock).
        const was = usb_lock.acquireIrqSave();
        defer usb_lock.releaseIrqRestore(was);
        const now = timer.millis();
        if (now - last_heartbeat_ms >= REPORT_HEARTBEAT_MS) {
            last_heartbeat_ms = now;
            var val: [dbg.VAL_CAP]u8 = undefined;
            dbg.set(.usb, "usb.reports", std.fmt.bufPrint(&val, "kbd={d} mouse={d}", .{ cnt_kbd_reports.v, cnt_mouse_reports.v }) catch "?");
            // Every HID endpoint's live controller state — including endpoints that
            // never reported (a keyboard that delivers nothing), which the silence
            // path skips. Shows whether an idle/dead endpoint is running vs halted.
            for (devs[0..ndev]) |*dv| {
                for (&dv.hids) |*mb| {
                    const h = &(mb.* orelse continue);
                    var k: [dbg.KEY_CAP]u8 = undefined;
                    var v2: [dbg.VAL_CAP]u8 = undefined;
                    if (std.fmt.bufPrint(&k, "usb.dev{d}.ep{d}", .{ dv.dbg_id, h.dci }) catch null) |kk|
                        dbg.set(.usb, kk, std.fmt.bufPrint(&v2, "{s} {s} seen={}", .{ kindName(h.kind), epStateName(epState(dv, h.dci)), h.seen_report }) catch "?");
                }
            }
            // Re-emitted enumerated-HID inventory — a RELIABLE readiness signal. The
            // one-shot "-> KEYBOARD ready" boot line is emitted before the async DHCP
            // lease is up, so telemetry can drop it and a harness cannot confirm a
            // keyboard that IS enumerated and live. This line re-emits every
            // heartbeat, so a dropped copy is recovered by the next — the same
            // survives-drops property the wm-state mirror relies on.
            var n_kbd: u32 = 0;
            var n_mouse: u32 = 0;
            for (devs[0..ndev]) |*dv| {
                for (&dv.hids) |*maybe| {
                    const h = &(maybe.* orelse continue);
                    switch (h.kind) {
                        .keyboard => n_kbd += 1,
                        .mouse => n_mouse += 1,
                        .tablet => {},
                    }
                }
            }
            var inv: [dbg.VAL_CAP]u8 = undefined;
            dbg.set(.usb, "usb.hid_present", std.fmt.bufPrint(&inv, "kbd={d} mouse={d}", .{ n_kbd, n_mouse }) catch "?");
        }
        while (nextEventReady()) |ev| {
            switch (trbType(ev)) {
                TRB_TRANSFER_EVENT => handleHidEvent(ev),
                TRB_PORT_STATUS_CHANGE => latchPortChange(ev),
                else => {},
            }
        }
        // HID endpoint liveness, same lock as the drain:
        //  - retry a deferred endpoint recovery now that the command ring is free
        //    (a bad completion during a command left the endpoint un-recovered and
        //    un-armed — without this pickup it stays dead forever);
        //  - re-ring the doorbell of a PROVEN-LIVE endpoint that has fallen quiet
        //    past the fuse (see HID_REKICK_MS — the lost-wake-up self-heal).
        for (devs[0..ndev]) |*d| {
            for (&d.hids) |*maybe| {
                const hid = &(maybe.* orelse continue);
                if (hid.recover_pending) {
                    // A bad completion is real evidence of a stuck endpoint — recover
                    // it regardless of whether it had reported before.
                    if (cmd_in_flight) continue;
                    hid.recover_pending = false;
                    if (recoverEndpoint(d.slot, hid.dci, &hid.ring)) queueHid(d.slot, hid);
                    continue;
                }
                // Silence-driven recovery targets ONLY an endpoint that reported and
                // then went quiet (the mid-stream freeze). A never-reported endpoint
                // is a healthy idle keyboard nobody has typed on — leave it armed and
                // untouched, or a doorbell storm/reset could drop the first keypress.
                if (!hid.seen_report) continue;
                if (now -% hid.last_event_ms >= HID_REKICK_MS) {
                    hid.last_event_ms = now;
                    // Record the controller's live endpoint state while it is
                    // silent — running (a lost wakeup a doorbell should fix),
                    // halted/stopped (needs the reset/stop recovery). The key
                    // overwrites, so it always shows the latest verdict.
                    {
                        var k: [dbg.KEY_CAP]u8 = undefined;
                        if (std.fmt.bufPrint(&k, "usb.dev{d}.ep{d}_state", .{ d.dbg_id, hid.dci }) catch null) |kk|
                            dbg.set(.usb, kk, epStateName(epState(d, hid.dci)));
                    }
                    if (hid.rekicks_since_event >= HID_REKICK_ESCALATE and !hid.resurrected) {
                        // The doorbell has proven ineffective — the controller has
                        // internally stopped the endpoint (measured on lemon's PCH:
                        // hundreds of re-kicks, zero events). Full recovery: Reset
                        // Endpoint + Set TR Dequeue at the ring's enqueue, then
                        // re-arm a fresh TRB. Needs the command ring free.
                        if (cmd_in_flight) continue;
                        hid.rekicks_since_event = 0;
                        hid.resurrected = true;
                        if (recoverEndpointFrom(.running, d.slot, hid.dci, &hid.ring)) {
                            cnt_hid_resurrect.inc();
                            queueHid(d.slot, hid);
                        } else {
                            cnt_hid_resurrect_fail.inc();
                        }
                        continue;
                    }
                    hid.rekicks_since_event += 1;
                    cnt_hid_rekick.inc();
                    ringDoorbell(d.slot, hid.dci);
                }
            }
        }
    }

    // PHASE 2 — port changes, with INTERRUPTS LIVE.
    //
    // processPortChanges ENUMERATES: reset, address, read descriptors — a path
    // built on `timer.sleep` (SET_ADDRESS recovery, debounce, TRSTRCY), and the
    // tick those sleeps wait on comes from IRQ0. So this lock MUST NOT mask
    // interrupts: with IF=0 the tick cannot arrive, `sleep` parks the core in
    // `hlt` forever, and every tick-driven timeout that would otherwise notice
    // (the enum budget, awaitXfer's wall clock, the dead-man fuse) is disabled
    // with it. The plain lock still excludes a concurrent BOT transaction.
    //
    // The cost is that the holder can be PREEMPTED, so under SMP a same-core task
    // taking usb_lock via mscBegin (which does cli+spin) could deadlock against
    // it. If SMP ever drives USB from two tasks, the fix is a preempt-disable
    // primitive — never masking the interrupt this path needs to make progress.
    lockEnter();
    defer lockExit();
    processPortChanges();
}
