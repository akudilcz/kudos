//! USB hub class — configure an addressed hub device, power and walk its
//! downstream ports (connect debounce, reset with retries, speed read-out),
//! and hand every stable child back to the controller for enumeration. Linux
//! drivers/usb/core/hub.c is the reference throughout; constants keep Linux's
//! names so the two diff.
//!
//! THE SEAM: a hub's child may itself be a hub, so hub setup and device
//! bring-up are mutually recursive — yet module dependencies must point one
//! way, so this module never imports xhci.zig. Every controller operation a
//! hub needs — EP0 control transfers, command submission, input-context edits,
//! the diag/log sink, and bringing up a child device — crosses the
//! `Hub.VTable` contract (the same shape as msc.Transport): xhci.zig
//! implements it and imports this module, never the reverse.

const std = @import("std");
const timer = @import("../../kernel/timer/timer.zig");
const debounce = @import("debounce.zig");
const port_fsm = @import("port_fsm.zig");
const xhci_ctx = @import("xhci_ctx.zig");
const trb = @import("trb.zig");

const MAX_TIERS = 5; // root + up to 4 hub levels (route string is 5 nibbles)

/// Where a device sits in the topology — the inputs to its xHCI slot context.
/// Owned here because the topology IS the hub tree (tier 0 hangs directly off
/// a root port); the controller carries one on every device record.
pub const Topo = struct {
    route: u32 = 0, // route string (4 bits of downstream-hub-port per tier)
    root_port: u32 = 0, // root-hub port the chain hangs off
    parent_slot: u32 = 0, // parent hub slot id (TT); 0 = on a root port
    parent_port: u32 = 0, // parent hub port number (TT)
    tier: u32 = 0, // 0 = root device, 1 = behind one hub, …
};

// Port reset (Linux hub_port_reset / hub_port_wait_reset): up to
// PORT_RESET_TRIES attempts, each polled to completion for up to
// HUB_RESET_TIMEOUT_MS; the poll step starts short and escalates to
// HUB_LONG_RESET_TIME_MS after the first misses and on every retry. One reset
// policy for the whole tree, so these are pub: portReset here drives a hub's
// downstream ports with them, and xhci.zig resetPortOnly drives the root
// ports (where completion also covers USB3 link retraining and the
// hot -> warm escalation).
pub const PORT_RESET_TRIES: u32 = 5;
pub const HUB_RESET_TIMEOUT_MS: u64 = 800;
pub const HUB_SHORT_RESET_TIME_MS: u64 = 10; // initial poll step, hub downstream ports
pub const HUB_ROOT_RESET_TIME_MS: u64 = 60; // initial poll step, root ports (USB2 §7.1.7.5)
pub const HUB_LONG_RESET_TIME_MS: u64 = 200; // escalated poll step / retry step
pub const T_RESET_RECOVERY_MS: u64 = 50; // TRSTRCY (≥10) after reset, before address

// Hub-class request retries (get_port_status / get_hub_descriptor) and the
// external-hub power-on-good floor (hub_power_on_good_delay: never below 100ms).
const USB_STS_RETRIES: u32 = 5;
const HUB_DESC_TRIES: u32 = 3;
const T_HUB_POWER_GOOD_FLOOR_MS: u64 = 100;

// Hub bNbrPorts settle poll: the Intel xHC can post a control transfer's
// completion event a moment before its DMA'd payload is CPU-coherent, so the
// hub descriptor's port-count byte can first read 0. A hub always has ≥1 port;
// re-read the (volatile) byte up to this many 1ms waits until it is non-zero.
const HUB_NPORTS_SETTLE_TRIES: u32 = 8;

// Hub-class port feature selectors (USB 2.0 §11.24.2).
const HUB_FEAT_PORT_RESET = 4; // SET_FEATURE selector
const HUB_FEAT_PORT_POWER = 8; // SET_FEATURE selector
const HUB_FEAT_C_PORT_CONNECTION = 16; // CLEAR_FEATURE: ack connection change
const HUB_FEAT_C_PORT_RESET = 20; // CLEAR_FEATURE: ack reset change

/// The USB control SETUP packet the Setup-stage TRB carries as immediate data
/// (USB 2.0 §9.3). Packed by xhci_ctx (pure, host-tested).
const setupPkt = xhci_ctx.setupPkt;

/// Build a hub downstream-port record key: `usb.hub<hubDevId>.port<p>`, tying the
/// port back to the hub's own `usb.dev<hubDevId>` record so the trace shows which
/// hub the port hangs off. Static buffer, used immediately (single-threaded).
fn portKey(hub_dbg_id: usize, port: u32) []const u8 {
    const S = struct {
        var buf: [32]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "usb.hub{d}.port{d}", .{ hub_dbg_id, port }) catch "usb.hubN.portN";
}

/// One addressed hub device, viewed through the controller seam: the stable
/// facts of its slot plus the vtable xhci.zig implements (xhci.zig hubView
/// builds one per call). This module keeps no state of its own — the one fact
/// a child's later retries need (the power-on-good delay) is written back to
/// the controller's device record through setPowerOnGoodMs.
pub const Hub = struct {
    /// The controller's record for this hub device — opaque here; handed back
    /// on every per-device call, and to bringUpChild as the parent.
    ctx: *anyopaque,
    vtable: *const VTable,
    slot: u32, // xHC slot id (device is already addressed)
    speed: u32, // PORTSC speed id (port_fsm.SPEED_*)
    input_ctx: usize, // the slot's input context (identity-mapped DMA)
    dbg_id: usize, // the hub's `usb.devN` id — keys its ports' diag records
    topo: Topo,

    pub const VTable = struct {
        // ── the hub's EP0 control pipe (ctx = the controller's device record) ──
        /// Control IN into the device's descriptor buffer (read back through
        /// descByte). Returns the bytes actually returned; null = failure.
        controlIn: *const fn (ctx: *anyopaque, setup: u64, len: u16) ?u16,
        /// Control OUT with no data stage. False = transfer failed.
        controlOut: *const fn (ctx: *anyopaque, setup: u64) bool,
        /// controlIn with the controller's transient descriptor-read retry.
        controlInRetry: *const fn (ctx: *anyopaque, setup: u64, len: u16) ?u16,
        /// Volatile read of byte `i` of the device's descriptor DMA buffer.
        descByte: *const fn (ctx: *anyopaque, i: usize) u8,
        /// Record the hub's power-on-to-good delay on the controller's device
        /// record: a child's init retry VBUS power-cycles its port with it.
        setPowerOnGoodMs: *const fn (ctx: *anyopaque, ms: u64) void,
        // ── controller command + input-context surface (controller-global) ──
        /// Enqueue a command TRB and wait for its Command Completion Event.
        submitCommand: *const fn (param: u64, control: u32) ?trb.Trb,
        /// The completion verdict: exactly Success (stamps the diag cc too).
        cmdOk: *const fn (ev: trb.Trb) bool,
        /// Write one 32-bit field of an input context (the controller applies
        /// its 32-vs-64-byte context stride).
        ctxSet: *const fn (base: usize, idx: usize, dword: usize, value: u32) void,
        /// Write Slot Context DW0 (route | Context Entries | speed | extras).
        ctxSlotDw0: *const fn (input_ctx: usize, route: u32, ctx_entries: u32, speed: u32, extra: u32) void,
        // ── the recursion inversion ──
        /// Enumerate one child device hanging off this hub (parent_ctx = this
        /// hub's ctx). This is xhci.zig bringUp, injected so the hub<->device
        /// recursion (a child may be a hub) never becomes an import cycle.
        bringUpChild: *const fn (topo: Topo, first_speed: u32, parent_ctx: *anyopaque) bool,
        // ── diag/log sink (the .usb-gated trace + per-device debug records) ──
        log: *const fn (s: []const u8) void,
        logx: *const fn (s: []const u8, v: u64) void,
        logx2: *const fn (s1: []const u8, v1: u64, s2: []const u8, v2: u64) void,
        dvSetStr: *const fn (pre: []const u8, field: []const u8, value: []const u8) void,
        dvSet: *const fn (pre: []const u8, field: []const u8, value: u64) void,
        dvSetHex: *const fn (pre: []const u8, field: []const u8, value: u64) void,
        /// Record the controller's most recent completion code under `pre`.
        dvSetCc: *const fn (pre: []const u8) void,
    };

    /// GET_STATUS of a hub downstream port, with the Linux get_port_status retry
    /// (USB_STS_RETRIES). Returns wPortStatus | wPortChange<<16, or null once the
    /// retries are exhausted.
    fn getPortStatus(h: Hub, port: u32) ?u32 {
        var t: u32 = 0;
        while (t < USB_STS_RETRIES) : (t += 1) {
            if (h.vtable.controlIn(h.ctx, setupPkt(0xA3, 0, 0, @intCast(port), 4), 4) != null) {
                return @as(u32, h.vtable.descByte(h.ctx, 0)) | (@as(u32, h.vtable.descByte(h.ctx, 1)) << 8) |
                    (@as(u32, h.vtable.descByte(h.ctx, 2)) << 16) | (@as(u32, h.vtable.descByte(h.ctx, 3)) << 24);
            }
        }
        return null;
    }

    /// Reset one hub downstream port and wait for it to enable — the downstream
    /// analogue of xhci.zig resetPortOnly: up to PORT_RESET_TRIES attempts, each
    /// polled up to HUB_RESET_TIMEOUT_MS on the escalating short->long step; the
    /// change bits are acked after every attempt (an unacked change wedges the
    /// hub's control endpoint — Linux hub_port_finish_reset). Ends with the
    /// TRSTRCY recovery. Returns the device speed, or null if the port never
    /// enabled / device gone.
    pub fn portReset(h: Hub, port: u32) ?u32 {
        var attempt: u32 = 0;
        while (attempt < PORT_RESET_TRIES) : (attempt += 1) {
            _ = h.vtable.controlOut(h.ctx, setupPkt(0x23, 3, HUB_FEAT_PORT_RESET, @intCast(port), 0));
            var step: u64 = if (attempt == 0) HUB_SHORT_RESET_TIME_MS else HUB_LONG_RESET_TIME_MS;
            var waited: u64 = 0;
            var status: u32 = 0;
            var enabled = false;
            while (waited < HUB_RESET_TIMEOUT_MS) {
                timer.sleep(step);
                waited += step;
                status = h.getPortStatus(port) orelse break;
                if (port_fsm.hubResetEnabled(status)) { // wPortStatus PORT_ENABLE
                    enabled = true;
                    break;
                }
                // Two short polls, then escalate (Linux hub_port_wait_reset).
                if (waited >= 2 * HUB_SHORT_RESET_TIME_MS) step = HUB_LONG_RESET_TIME_MS;
            }
            // Acknowledge the change bits whether or not it enabled, so the hub
            // keeps servicing control requests for the remaining ports.
            _ = h.vtable.controlOut(h.ctx, setupPkt(0x23, 1, HUB_FEAT_C_PORT_RESET, @intCast(port), 0));
            _ = h.vtable.controlOut(h.ctx, setupPkt(0x23, 1, HUB_FEAT_C_PORT_CONNECTION, @intCast(port), 0));
            if (enabled) {
                timer.sleep(T_RESET_RECOVERY_MS); // TRSTRCY before addressing
                // Child speed from wPortStatus (SS hub children are SS by
                // construction — rationale on port_fsm.hubChildSpeed).
                return port_fsm.hubChildSpeed(h.speed, status);
            }
            // Device gone — abandon (-ENOTCONN); otherwise the next attempt runs.
            if (port_fsm.hubResetFail(status) == .vanished) return null;
            h.vtable.logx2("xhci:  hub port reset retry, port=", port, " attempt=", attempt + 1);
        }
        return null;
    }

    /// VBUS power-cycle one downstream port (Linux hub_port_connect's halfway
    /// remedy for a device wedged deeper than a reset reaches): power off, wait
    /// twice the hub's power-on-good time, power on, wait it once more.
    /// `pwr_on_good_ms` is the delay setup() recorded on the controller's
    /// device record (bPwrOn2PwrGood, floored).
    pub fn powerCyclePort(h: Hub, port: u32, pwr_on_good_ms: u64) void {
        h.vtable.logx("xhci: power-cycling hub port=", port);
        _ = h.vtable.controlOut(h.ctx, setupPkt(0x23, 1, HUB_FEAT_PORT_POWER, @intCast(port), 0));
        timer.sleep(2 * pwr_on_good_ms);
        _ = h.vtable.controlOut(h.ctx, setupPkt(0x23, 3, HUB_FEAT_PORT_POWER, @intCast(port), 0));
        timer.sleep(pwr_on_good_ms);
    }

    /// Configure a hub and enumerate the devices on its downstream ports,
    /// recursing for nested hubs through bringUpChild. `d` views the (already
    /// addressed) hub device; `pre` is its `usb.devN` diag-key prefix. Returns
    /// false on a hub-level failure (config/descriptor/Configure Endpoint) so
    /// bringUp can retry the whole hub; per-port failures are the ports' own
    /// retries, not the hub's, and never fail the hub.
    pub fn setup(d: Hub, pre: []const u8) bool {
        if (d.topo.tier + 1 >= MAX_TIERS) {
            d.vtable.log("xhci:  hub tier limit reached — not descending further\n");
            return true; // configured fine; just not descending
        }

        // SET_CONFIGURATION (read config descriptor first for its bConfigurationValue).
        if (d.vtable.controlInRetry(d.ctx, setupPkt(0x80, 6, 0x0200, 0, 64), 64) == null) return false;
        const config_value = d.vtable.descByte(d.ctx, 5);
        if (!d.vtable.controlOut(d.ctx, setupPkt(0x00, 9, config_value, 0, 0))) return false;

        // GET hub descriptor (Linux get_hub_descriptor retries this 3 times): the
        // bNbrPorts at offset 2 in both variants. The descriptor TYPE is
        // speed-dependent (USB 3.0 §10.15.2.1): a SuperSpeed hub answers ONLY
        // type 0x2A (wValue 0x2A00) and STALLs / returns 0 for the 2.0 type
        // 0x29 — which is why every SS hub here read bNbrPorts=0 and its
        // downstream devices (a mouse included) never enumerated. Mirrors Linux
        // get_hub_descriptor picking USB_DT_SS_HUB for a SuperSpeed hub.
        const hub_desc_value: u16 = if (port_fsm.isSuper(d.speed)) 0x2A00 else 0x2900;
        var desc_try: u32 = 0;
        var desc_ok = false;
        while (desc_try < HUB_DESC_TRIES) : (desc_try += 1) {
            if (d.vtable.controlIn(d.ctx, setupPkt(0xA0, 6, hub_desc_value, 0, 16), 16) != null) {
                desc_ok = true;
                break;
            }
        }
        if (!desc_ok) {
            d.vtable.dvSetStr(pre, "hub", "descriptor read failed");
            return false;
        }
        // bNbrPorts at offset 2. On real HW the Intel xHC posts the transfer's
        // completion event a moment before the DMA'd payload is CPU-coherent (the
        // controller's event-ring fence orders our read against the event, but
        // cannot pull a write the controller has not yet flushed): the first read
        // can still see the pre-transfer zero fill. A hub always has ≥1 port, so
        // poll the (volatile, via descByte) byte briefly until it reads non-zero
        // rather than trusting the first load.
        var nports = d.vtable.descByte(d.ctx, 2);
        var settle: u32 = 0;
        while (nports == 0 and settle < HUB_NPORTS_SETTLE_TRIES) : (settle += 1) {
            timer.sleep(1);
            nports = d.vtable.descByte(d.ctx, 2);
        }
        d.vtable.logx("xhci:  hub ports=", nports);
        d.vtable.dvSet(pre, "hub_nports", nports);

        // Mark the slot as a hub and re-issue Configure Endpoint so the xHC routes
        // through it. Slot context (xHCI Table 6-4): DW0 has Route/Speed/Hub bit 26/
        // Context Entries; DW1 has Root Hub Port Number and Number of Ports [31:24].
        // Configure Endpoint touches ONLY the slot context here: Drop flags = 0, Add
        // flags = A0 (slot) only — setting A1 (EP0) would be a Parameter Error since
        // EP0 is owned by Address Device.
        d.vtable.ctxSet(d.input_ctx, 0, 0, 0); // drop flags
        d.vtable.ctxSet(d.input_ctx, 0, 1, 0b01); // add: slot context only
        d.vtable.ctxSlotDw0(d.input_ctx, d.topo.route, 1, d.speed, 1 << 26); // +Hub bit
        d.vtable.ctxSet(d.input_ctx, 1, 1, (d.topo.root_port << 16) | (@as(u32, nports) << 24));
        const cfg = d.vtable.submitCommand(d.input_ctx, (trb.TYPE_CONFIGURE_ENDPOINT << 10) | (d.slot << 24)) orelse return false;
        if (!d.vtable.cmdOk(cfg)) {
            d.vtable.log("xhci:  hub configure failed\n");
            d.vtable.dvSetStr(pre, "hub", "configure-endpoint failed");
            d.vtable.dvSetCc(pre);
            return false;
        }

        // Power every port, then wait power-on-to-good. The descriptor gives
        // bPwrOn2PwrGood in 2ms units at offset 5; honor it, floored at 100ms for an
        // external hub (Linux hub_power_on_good_delay). Remember the delay on the
        // controller's device record: a child's init retry power-cycles its port
        // with it (powerCyclePort).
        const pwr_on_good_ms = @max(@as(u64, d.vtable.descByte(d.ctx, 5)) * 2, T_HUB_POWER_GOOD_FLOOR_MS);
        d.vtable.setPowerOnGoodMs(d.ctx, pwr_on_good_ms);
        var p: u32 = 1;
        while (p <= nports) : (p += 1) {
            _ = d.vtable.controlOut(d.ctx, setupPkt(0x23, 3, HUB_FEAT_PORT_POWER, @intCast(p), 0));
        }
        timer.sleep(pwr_on_good_ms);

        // For each downstream port: debounce connect (stability window), reset with
        // retries, read speed, then enumerate the device — each step acking the
        // change bits it raises. An unacked change wedges the hub's control endpoint
        // so every later port times out (Linux hub_port_finish_reset).
        p = 1;
        while (p <= nports) : (p += 1) {
            const hpk = portKey(d.dbg_id, p);
            var status = d.getPortStatus(p) orelse {
                d.vtable.logx("xhci:  hub GET_STATUS failed, port=", p);
                d.vtable.dvSetStr(hpk, "result", "GET_STATUS failed");
                d.vtable.dvSetCc(hpk);
                continue;
            };
            // wPortStatus (low 16) | wPortChange (high 16). Record it for every port
            // so a downstream device that fails to report connect is visible, not
            // silent — the boot keyboard/mouse live behind the USB2 companion hub, so
            // this is the path that must not drop a device without a trace.
            d.vtable.logx2("xhci:  hub port=", p, " status=", status);
            d.vtable.dvSetHex(hpk, "status", status);
            d.vtable.dvSet(hpk, "ccs", status & 0x01);
            if ((status & 0x01) == 0 and (status & (1 << 16)) == 0) {
                d.vtable.dvSetStr(hpk, "result", "no connect");
                continue;
            }

            // Debounce (Linux hub_port_debounce): C_PORT_CONNECTION (change bit 16)
            // restarts the stability window and is acked each time it is seen.
            var db = debounce.Debounce{};
            var stable = false;
            while (true) {
                const change = (status & (1 << 16)) != 0;
                if (change) _ = d.vtable.controlOut(d.ctx, setupPkt(0x23, 1, HUB_FEAT_C_PORT_CONNECTION, @intCast(p), 0));
                const verdict = db.feed((status & 0x01) != 0, change);
                if (verdict == .stable_connected) {
                    stable = true;
                    break;
                }
                if (verdict != .pending) break; // stable_empty / timeout
                timer.sleep(debounce.STEP_MS);
                status = d.getPortStatus(p) orelse break;
            }
            if (!stable) {
                d.vtable.dvSetStr(hpk, "result", "connect never stabilized");
                continue;
            }

            const dev_speed = d.portReset(p) orelse {
                d.vtable.dvSetStr(hpk, "result", "connected but reset never enabled");
                continue;
            };

            // Route string: shift this hub port number into the next nibble.
            // Ports > 15 cannot encode in a 4-bit nibble (USB 3 route strings)
            // — skip them with a trace rather than corrupting the route (Linux
            // parity; review M-U6).
            if (p > 15) {
                d.vtable.logx("xhci:  hub port > 15 cannot route — skipping port ", p);
                d.vtable.dvSetStr(hpk, "result", "port > 15: not routable");
                continue;
            }
            const next_route = d.topo.route | (p << @intCast(d.topo.tier * 4));
            d.vtable.logx("xhci:  hub port has device, port=", p);
            d.vtable.dvSet(hpk, "spd", dev_speed);
            d.vtable.dvSetStr(hpk, "result", "device — enumerating");
            // A child that fails to come up does not fail the HUB: the walk continues to
            // the next port and the hub still reports .ok_hub. (This is also why the walk
            // cannot multiply — a hub-level failure returns before we ever get here.)
            _ = d.vtable.bringUpChild(.{
                .route = next_route,
                .root_port = d.topo.root_port,
                .parent_slot = d.slot,
                .parent_port = p,
                .tier = d.topo.tier + 1,
            }, dev_speed, d.ctx);
        }
        return true;
    }
};
