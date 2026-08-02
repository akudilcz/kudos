//! Host tests of src/kernel/debug/debug.zig — the structured `dbg:` record
//! emitter. The property under test is record ATOMICITY: one `set` call hands
//! the whole assembled line to the trace bus in exactly ONE klog call, so
//! klog's per-call bus lock is sufficient to keep concurrent emitters from
//! tearing a record mid-line (the boot-3 trace-corruption incident class).

const std = @import("std");
const root = @import("testroot").kernel;
const debug = root.debug;
const counter = root.counter;
const klog = counter.klog;
const gate = counter.gate;
const expect = std.testing.expect;

// The sink under observation: counts calls and keeps the last payload. A
// registered sink cannot be removed, so all tests in this binary share it and
// snapshot `calls` around each emission they assert on.
var calls: usize = 0;
var last: [256]u8 = undefined;
var last_len: usize = 0;

fn countingSink(bytes: []const u8) void {
    calls += 1;
    const n = @min(bytes.len, last.len);
    @memcpy(last[0..n], bytes[0..n]);
    last_len = n;
}

test "a wire-gated set reaches the sinks as ONE whole-line call" {
    klog.addSink(&countingSink);
    gate.enable(&.{.usb});
    const before = calls;
    debug.set(.usb, "test.atomic", "whole-line");
    try expect(calls == before + 1); // one record, one bus call — never torn
    try expect(std.mem.eql(u8, last[0..last_len], "dbg: test.atomic = whole-line\n"));
}

test "an over-cap value truncates visibly, still one call" {
    gate.enable(&.{.usb});
    const before = calls;
    const long = "x" ** (debug.VAL_CAP + 40);
    debug.set(.usb, "test.long", long);
    try expect(calls == before + 1);
    try expect(last_len == debug.LINE_CAP);
    try expect(std.mem.endsWith(u8, last[0..last_len], "~\n")); // truncation is visible, never silent
}

test "a gated-off set stays off the wire but lands in the diag ring" {
    gate.enable(&.{}); // everything off
    const before = calls;
    debug.set(.usb, "test.gated", "ring-only");
    try expect(calls == before); // no sink call — nothing on the wire
    const tail = klog.diagBuf()[klog.diagStart()..][0..klog.diagCount()];
    try expect(std.mem.indexOf(u8, tail, "dbg: test.gated = ring-only\n") != null);
}
