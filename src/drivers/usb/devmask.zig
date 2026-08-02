//! The USB device mask: devices kudos deliberately does not drive.
//!
//! Pure, so it is host-tested — and so the list is one greppable, reviewable table
//! rather than a special case buried in the enumeration path.
//!
//! WHY MASK AT ALL. kudos drives exactly three device classes (HID keyboard, HID pointer,
//! mass storage), so a machine's onboard audio codec, RGB controller and Bluetooth radio
//! are going to be rejected anyway — but rejecting them LATE is expensive. Enumeration
//! reads the device descriptor, then the FULL configuration descriptor, then walks every
//! interface, only then concluding "no usable HID interface". For a slow 8-interface
//! audio card that walk is a 256-byte control transfer that dominates USB bring-up.
//!
//! Masking checks vid:pid the moment the DEVICE descriptor lands — before the config
//! descriptor is fetched — and abandons the device immediately, with a reason in the
//! trace. The device is still enumerated far enough to be identified, so a masked
//! device is visible in `usb.devN.*` rather than mysteriously absent.
//!
//! WHAT NOT TO PUT HERE. This is not a workaround list for devices that fail to
//! enumerate. If a device kudos SHOULD drive is failing, that is a bug in the driver
//! and masking it would hide the bug. Only add a device that kudos would correctly
//! refuse anyway, and where skipping the refusal saves real work.

const std = @import("std");

pub const Entry = struct {
    vid: u16,
    pid: u16,
    /// Why. Goes into the trace as the drop reason, so a masked device explains itself.
    why: []const u8,
};

/// The mask. Keep it short, keep every entry justified.
pub const ENTRIES = [_]Entry{
    // lemon's ROG motherboard, onboard. Neither is a HID or a storage device; kudos
    // rejected both after a full config-descriptor walk, and the audio card's walk is
    // the slow one (8 interfaces, 256-byte config, answers lazily).
    .{ .vid = 0x0b05, .pid = 0x1a98, .why = "onboard audio (not HID/MSC)" },
    .{ .vid = 0x0b05, .pid = 0x18f3, .why = "AURA lighting controller (not HID/MSC)" },
    // Intel onboard Bluetooth. Six interfaces, all class 0xe0 (wireless) — kudos walked
    // every one of them to conclude "no usable HID interface", which it could have known
    // from the vid:pid.
    .{ .vid = 0x8087, .pid = 0x0036, .why = "onboard Bluetooth (not HID/MSC)" },
};

/// Why this device is masked, or null if it is not.
pub fn masked(vid: u16, pid: u16) ?[]const u8 {
    for (ENTRIES) |e| {
        if (e.vid == vid and e.pid == pid) return e.why;
    }
    return null;
}
