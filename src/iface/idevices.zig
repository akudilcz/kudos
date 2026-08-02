//! The peripheral-presence seam: what the machine has plugged in and how those
//! devices are faring, published by the drivers and read by the interface.
//!
//! It exists because the heads-up display has to report the USB and network
//! devices, and a display reaching into `drivers/` would invert the layering —
//! the interface sits above the drivers and must not name them. The drivers
//! publish this contract at bring-up; anything above reads it and never learns
//! which controller answered.
//!
//! Pull, not push: the fields are functions the driver already has, so nothing is
//! copied on a hot path and a reader always sees the driver's live state. A
//! machine with no such device leaves `instance` null, and the reader shows
//! absence rather than zeroes.

/// What the USB stack has enumerated, and how much it has carried.
pub const Usb = struct {
    keyboard: bool = false,
    mouse: bool = false,
    usbdisk: bool = false,
    /// Devices addressed on the bus.
    devices: u8 = 0,
    /// HID reports delivered since boot.
    kbd_reports: u64 = 0,
    mouse_reports: u64 = 0,
};

/// The published contract. A driver group fills the entries it owns.
pub const Devices = struct {
    /// The USB stack's enumeration state, or null when there is no USB stack.
    usb: ?*const fn () Usb = null,
    /// Frames the network interface dropped on transmit, or null when there is
    /// no interface. A drop is never inferred from silence: absent and zero are
    /// different answers and are shown differently.
    tx_dropped: ?*const fn () u64 = null,
};

pub var instance: Devices = .{};

/// The USB state, or an all-absent snapshot when nothing published one.
pub fn usbStatus() Usb {
    if (instance.usb) |f| return f();
    return .{};
}

/// Transmit drops, or null when no interface published a count.
pub fn txDropped() ?u64 {
    if (instance.tx_dropped) |f| return f();
    return null;
}
