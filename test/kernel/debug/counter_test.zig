//! Host tests of src/kernel/debug/counter.zig.

const std = @import("std");
const counter = @import("testroot").kernel.counter;
const all = counter.all;
const emitAll = counter.emitAll;
const emitChanged = counter.emitChanged;
const expect = std.testing.expect;
const gate = counter.gate;
const klog = counter.klog;
const register = counter.register;

/// The newest bytes of the klog diag ring, linearized enough for a substring
/// check: the ring is far from wrapping in a test binary, so the valid bytes
/// start at diagStart and are contiguous.
fn ringTail() []const u8 {
    return klog.diagBuf()[klog.diagStart()..][0..klog.diagCount()];
}

// Counters live at file scope in real use (a registered pointer must outlive the
// registry) — the test counters mirror that, not stack locals.
var t_reg = counter.Counter{ .mod = .usb, .name = "test.reg" };
var t_moved = counter.Counter{ .mod = .usb, .name = "test.moved" };
var t_forced = counter.Counter{ .mod = .pci, .name = "test.forced" };

test "register is idempotent and add/inc accumulate" {
    register(&t_reg);
    register(&t_reg); // must not duplicate
    var n: usize = 0;
    for (all()) |e| {
        if (e == &t_reg) n += 1;
    }
    try expect(n == 1);
    t_reg.inc();
    t_reg.add(2);
    try expect(t_reg.v == 3);
}

test "peak is a high-water mark: raises to larger, never lowers" {
    var c = counter.Counter{ .mod = .usb, .name = "test.peak" };
    c.peak(7);
    try expect(c.v == 7);
    c.peak(3); // a smaller reading must not erase the worst case
    try expect(c.v == 7);
    c.peak(7); // equal is not a new peak either
    try expect(c.v == 7);
    c.peak(12);
    try expect(c.v == 12);
}

test "emitChanged emits movers once and skips idle counters" {
    register(&t_moved);
    gate.enable(&.{.usb});
    t_moved.add(7);
    emitChanged();
    try expect(std.mem.indexOf(u8, ringTail(), "dbg: usb.test.moved = 7") != null);
    // Unchanged since: a second flush must not emit it (or anything else) again.
    const before = klog.diagCount();
    emitChanged();
    try expect(klog.diagCount() == before);
}

test "emitAll(force) reaches the bus even when the module gate is off" {
    register(&t_forced);
    gate.enable(&.{}); // everything off
    t_forced.add(41);
    emitAll(true);
    try expect(std.mem.indexOf(u8, ringTail(), "dbg: pci.test.forced = 41") != null);
}
