//! NIC abstraction. Picks whichever supported Ethernet
//! controller is present and dispatches send/poll/MAC to it: the e1000 (QEMU
//! default) or a modern Intel controller — igb (QEMU `-device igb`) and igc /
//! I225 / I226 (the real target machine), driven by src/drivers/net/nic/igc.zig.
//!
//! Both drivers expose the same `macAddr`/`send`/`poll` surface, so once one
//! claims the hardware its three functions are captured in a single
//! `intel.Driver` value and every call goes straight through it — no per-call
//! backend switch.

const e1000 = @import("e1000.zig");
const igc = @import("igc.zig");
const intel = @import("intel.zig");

const E1000_DRIVER: intel.Driver = .{ .macAddr = e1000.macAddr, .send = e1000.send, .poll = e1000.poll, .linkUp = e1000.linkUp, .txDropped = e1000.txDropped };
const IGC_DRIVER: intel.Driver = .{ .macAddr = igc.macAddr, .send = igc.send, .poll = igc.poll, .linkUp = igc.linkUp, .txDropped = igc.txDropped };

var driver: ?intel.Driver = null;

/// Probe the supported controllers in order; the first present one wins and its
/// driver is captured for all later calls. Returns false if no NIC is found.
/// Idempotent: a NIC already claimed (netdebug starts the NIC before net.init's
/// deferred DHCP bring-up) is not re-probed — re-running a driver's init would
/// reset its rings out from under the live netdebug stream.
pub fn init() bool {
    if (driver != null) return true;
    if (e1000.init()) {
        driver = E1000_DRIVER;
        return true;
    }
    if (igc.init()) {
        driver = IGC_DRIVER;
        return true;
    }
    return false;
}

/// The claimed NIC's MAC; all-zero before init() picks a driver.
pub fn macAddr() [6]u8 {
    return if (driver) |d| d.macAddr() else .{ 0, 0, 0, 0, 0, 0 };
}

/// Transmit one Ethernet frame through the claimed driver; a no-op with no NIC.
pub fn send(frame: []const u8) void {
    if (driver) |d| d.send(frame);
}

/// Next received frame from the claimed driver, or null (also null with no NIC).
pub fn poll() ?[]const u8 {
    return if (driver) |d| d.poll() else null;
}

/// Whether the claimed NIC reports link (STATUS.LU); false with no NIC. Frames
/// sent while this is false (or while the switch port behind it is still not
/// forwarding) are silently lost — netdebug gates its boot-log replay on it.
pub fn linkUp() bool {
    return if (driver) |d| d.linkUp() else false;
}

/// Cumulative TX drops from the claimed driver (0 with no NIC). Polled by
/// net.pump so a TX wedge becomes a record instead of unexplained silence.
pub fn txDropped() u64 {
    return if (driver) |d| d.txDropped() else 0;
}
