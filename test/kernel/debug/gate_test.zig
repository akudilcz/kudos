//! Host tests of src/kernel/debug/gate.zig.

const std = @import("std");
const gate = @import("gate");
const enable = gate.enable;
const expect = std.testing.expect;
const on = gate.on;

test "all modules are off by default (initial state, before any enable() call)" {
    // enabled starts as std.EnumSet(Mod).initEmpty() at file scope; verify every
    // tag reads as off without ever calling enable() in this test.
    try expect(!on(.usb));
    try expect(!on(.gpu));
    try expect(!on(.boot));
}

test "enable() turns on exactly the passed set, nothing else" {
    enable(&.{ .usb, .gpu });
    try expect(on(.usb));
    try expect(on(.gpu));
    try expect(!on(.net));
    try expect(!on(.pci));
    try expect(!on(.boot));
}

test "enable() REPLACES the set, does not accumulate across calls" {
    enable(&.{.usb});
    try expect(on(.usb));
    enable(&.{.net}); // second call must fully replace, not add to, the first
    try expect(!on(.usb));
    try expect(on(.net));
}

test "enable() with an empty slice turns everything off" {
    enable(&.{ .usb, .gpu, .net });
    try expect(on(.usb));
    enable(&.{});
    try expect(!on(.usb));
    try expect(!on(.gpu));
    try expect(!on(.net));
}

test "enable() with duplicate entries in the slice is idempotent" {
    enable(&.{ .usb, .usb, .usb });
    try expect(on(.usb));
    try expect(!on(.net));
}
