//! Publishes what the machine has plugged in through the peripheral seam
//! (iface/idevices.zig), so anything above the drivers can report the USB and
//! network devices without naming a controller.
//!
//! One file per side of a seam is the pattern the network stack already uses
//! (`netapi.publish`). It lives in the driver group because it is the only place
//! that may see both a controller and the contract it fills.

const idevices = @import("idevices");
const xhci = @import("usb/xhci.zig");
const nic = @import("net/nic/nic.zig");

/// Fill the seam. Called once, at bring-up, after the controllers exist.
pub fn publish() void {
    idevices.instance = .{ .usb = usbStatus, .tx_dropped = nic.txDropped };
}

/// The xHCI controller's enumeration state, in the seam's own terms.
fn usbStatus() idevices.Usb {
    const st = xhci.deviceStatus();
    return .{
        .keyboard = st.keyboard,
        .mouse = st.mouse,
        .usbdisk = st.usbdisk,
        .devices = @intCast(st.devices),
        .kbd_reports = st.kbd_reports,
        .mouse_reports = st.mouse_reports,
    };
}
