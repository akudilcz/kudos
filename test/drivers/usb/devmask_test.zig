//! Host tests of src/drivers/usb/devmask.zig.

const std = @import("std");
const devmask = @import("devmask");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const masked = devmask.masked;

test "the masked devices are masked, and say why" {
    try expectEqual(@as(?[]const u8, "onboard audio (not HID/MSC)"), masked(0x0b05, 0x1a98));
    try expectEqual(@as(?[]const u8, "AURA lighting controller (not HID/MSC)"), masked(0x0b05, 0x18f3));
    try expectEqual(@as(?[]const u8, "onboard Bluetooth (not HID/MSC)"), masked(0x8087, 0x0036));
}

test "regression: the devices kudos MUST drive are never masked" {
    // The whole hazard of a mask is masking something you needed. These are the real
    // devices on lemon's bus, and the boot depends on every one of them:
    try expect(masked(0x3434, 0x0860) == null); // Keychron keyboard
    try expect(masked(0x046d, 0xc088) == null); // Logitech G Pro mouse
    try expect(masked(0x13fe, 0x6500) == null); // Phison USB stick -> /usbdisk
    try expect(masked(0x058f, 0x6254) == null); // hub
    try expect(masked(0x174c, 0x2074) == null); // hub
    try expect(masked(0x3434, 0xd030) == null); // Keychron Link dongle
}

test "a vid match with a different pid is NOT masked" {
    // Masking by vendor alone would be a trap: ASUS makes keyboards and mice too.
    try expect(masked(0x0b05, 0x0000) == null);
    try expect(masked(0x0b05, 0x1a99) == null);
    // …and a pid match under a different vendor is a coincidence, not a match.
    try expect(masked(0x0000, 0x1a98) == null);
}

test "an empty bus position (0000:0000) is not masked into silence" {
    try expect(masked(0, 0) == null);
}
