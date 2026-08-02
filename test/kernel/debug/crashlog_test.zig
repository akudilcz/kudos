//! Host tests of src/kernel/debug/crashlog.zig — the per-core crash records a
//! fatal path writes instead of ever touching the trace bus. The lock-freedom
//! itself is by construction (plain stores into a core-owned buffer, one atomic
//! to publish); these tests prove the record lifecycle: what is written is what
//! ships, exactly one reader claims a record, nothing unsealed is visible, and
//! every loss (truncation, supersession) is counted, never silent.

const std = @import("std");
const kernel_root = @import("testroot").kernel;
const crashlog = kernel_root.crashlog;
const counter = kernel_root.counter;

/// The registered value of a crashlog counter, found through the public
/// registry (counter.all) — the same surface the `stats` command reads.
fn counterValue(name: []const u8) u64 {
    for (counter.all()) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.v;
    }
    return 0;
}

// Distinct core slots per test: the records are module state shared by every
// test in this process, and a slot is only reusable after release().

test "a sealed record ships exactly what was written, then the slot recycles" {
    crashlog.init();
    crashlog.puts(0, "*** CPU EXCEPTION: test vec=");
    crashlog.putHex(0, 0xd);
    crashlog.puts(0, "\n");
    // Nothing is visible before the seal.
    try std.testing.expect(!crashlog.pending());
    try std.testing.expect(crashlog.takeSealed() == null);
    crashlog.seal(0);
    try std.testing.expect(crashlog.pending());
    const rec = crashlog.takeSealed().?;
    try std.testing.expectEqual(@as(usize, 0), rec.core);
    try std.testing.expectEqualStrings("*** CPU EXCEPTION: test vec=0x000000000000000d\n", rec.bytes);
    // The claim is exclusive: a second reader finds nothing.
    try std.testing.expect(crashlog.takeSealed() == null);
    try std.testing.expect(!crashlog.pending());
    crashlog.release(rec.core);
    // The slot is writable again and starts empty.
    crashlog.puts(0, "next");
    crashlog.seal(0);
    const again = crashlog.takeSealed().?;
    try std.testing.expectEqualStrings("next", again.bytes);
    crashlog.release(again.core);
}

test "seal without an open record publishes nothing" {
    crashlog.seal(1); // nothing was written to slot 1
    try std.testing.expect(crashlog.takeSealed() == null);
}

test "a record truncates at RECORD_CAP and the loss is counted" {
    crashlog.init();
    const before = counterValue("crash.truncated");
    const chunk = "x" ** 1024;
    var wrote: usize = 0;
    while (wrote < crashlog.RECORD_CAP + 3 * 1024) : (wrote += chunk.len)
        crashlog.puts(2, chunk);
    crashlog.seal(2);
    const rec = crashlog.takeSealed().?;
    try std.testing.expectEqual(@as(usize, crashlog.RECORD_CAP), rec.bytes.len);
    try std.testing.expectEqual(@as(u64, wrote - crashlog.RECORD_CAP), counterValue("crash.truncated") - before);
    crashlog.release(rec.core);
}

test "a new fault supersedes an unshipped record — newest wins, counted" {
    crashlog.init();
    const before = counterValue("crash.overwritten");
    crashlog.puts(3, "first crash");
    crashlog.seal(3);
    // The core faults again before anything shipped: the new dump replaces the
    // old, and the loss is counted.
    crashlog.puts(3, "second crash");
    crashlog.seal(3);
    try std.testing.expectEqual(@as(u64, 1), counterValue("crash.overwritten") - before);
    const rec = crashlog.takeSealed().?;
    try std.testing.expectEqualStrings("second crash", rec.bytes);
    try std.testing.expect(crashlog.takeSealed() == null);
    crashlog.release(rec.core);
}

test "an out-of-range core is refused without touching any record" {
    const huge = 1 << 20;
    crashlog.puts(huge, "nobody home");
    crashlog.seal(huge);
    crashlog.release(huge);
    try std.testing.expect(!crashlog.pending());
}

test "the backtrace emitter writes numbered BT lines into the record" {
    // A synthetic RBP chain, exactly as backtrace_test builds one: each frame
    // holds [saved rbp][return address], frames ascending.
    var stack: [8]usize align(16) = undefined;
    const base = @intFromPtr(&stack[0]);
    // frame A at stack[0..2] -> frame B at stack[4..6] -> terminator.
    stack[0] = base + 4 * @sizeOf(usize); // A's saved rbp -> B
    stack[1] = 0x1111; // A's return address
    stack[4] = 0; // B's saved rbp: terminates the walk
    stack[5] = 0x2222; // B's return address
    const frames = crashlog.emitBacktrace(4, base, base);
    try std.testing.expectEqual(@as(usize, 2), frames);
    crashlog.seal(4);
    const rec = crashlog.takeSealed().?;
    try std.testing.expectEqualStrings(
        "*** BT #0x0000000000000000 0x0000000000001111\n" ++
            "*** BT #0x0000000000000001 0x0000000000002222\n",
        rec.bytes,
    );
    crashlog.release(rec.core);
}
