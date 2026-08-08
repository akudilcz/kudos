//! Host tests of src/iface/ivirt.zig — the VM cross-core mailboxes. Drives both
//! roles single-threaded (the release/acquire ordering is a no-op without
//! contention, but every handshake and both serial directions are exercised),
//! and pins down the property the multi-VM desktop rests on: slots are
//! independent, so two guests never see each other's console, scanout or state.

const std = @import("std");
const ivirt = @import("ivirt");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Two distinct slots used throughout — the two-window case the desktop opens.
const A: ivirt.Id = 0;
const B: ivirt.Id = 1;

/// Clear every slot, so each test starts from a known mailbox regardless of
/// which slots the previous one touched.
fn resetAll() void {
    var id: ivirt.Id = 0;
    while (id < ivirt.MAX_VMS) : (id += 1) ivirt.reset(id);
}

test "lifecycle state: absent by default, set by hypervisor, read by app" {
    resetAll();
    try expectEqual(ivirt.State.absent, ivirt.state(A));
    ivirt.setState(A, .booting);
    try expectEqual(ivirt.State.booting, ivirt.state(A));
    ivirt.setState(A, .running);
    try expectEqual(ivirt.State.running, ivirt.state(A));
    resetAll();
}

test "stop mailbox: one-shot request -> take, with a non-consuming peek" {
    resetAll();
    try expect(!ivirt.stopRequested(A));
    try expect(!ivirt.takeStop(A));
    ivirt.requestStop(A);
    try expect(ivirt.stopRequested(A)); // peek does not consume…
    try expect(ivirt.stopRequested(A));
    try expect(ivirt.takeStop(A)); // …take does
    try expect(!ivirt.stopRequested(A));
    try expect(!ivirt.takeStop(A)); // one-shot
    resetAll();
}

test "serial tx: conWrite (hypervisor) -> conRead (app), in order" {
    resetAll();
    try expectEqual(@as(?u8, null), ivirt.conRead(A));
    for ("boot") |b| try expect(ivirt.conWrite(A, b));
    for ("boot") |b| try expectEqual(@as(?u8, b), ivirt.conRead(A));
    try expectEqual(@as(?u8, null), ivirt.conRead(A));
    resetAll();
}

test "serial rx: conInput (app) -> conFetch (hypervisor), with conPending" {
    resetAll();
    try expect(!ivirt.conPending(A));
    try expectEqual(@as(?u8, null), ivirt.conFetch(A));
    for ("ls\r") |b| try expect(ivirt.conInput(A, b));
    try expect(ivirt.conPending(A)); // data-ready before any fetch
    for ("ls\r") |b| try expectEqual(@as(?u8, b), ivirt.conFetch(A));
    try expect(!ivirt.conPending(A)); // drained
    resetAll();
}

test "full rings drop, return false, and count the loss" {
    resetAll();
    try expectEqual(@as(u64, 0), ivirt.droppedTx(A));
    try expectEqual(@as(u64, 0), ivirt.droppedRx(A));
    for (0..ivirt.TX_CAP) |_| try expect(ivirt.conWrite(A, 'x'));
    try expect(!ivirt.conWrite(A, 'x')); // full — dropped, not overwritten
    try expectEqual(@as(u64, 1), ivirt.droppedTx(A));
    for (0..ivirt.RX_CAP) |_| try expect(ivirt.conInput(A, 'k'));
    try expect(!ivirt.conInput(A, 'k'));
    try expect(!ivirt.conInput(A, 'k'));
    try expectEqual(@as(u64, 2), ivirt.droppedRx(A));
    try expectEqual(@as(?u8, 'x'), ivirt.conRead(A)); // queued bytes survive the drop
    resetAll();
}

test "scanout publish: fb() returns the pointer/dims with a bumped generation" {
    resetAll();
    try expectEqual(@as(?ivirt.Fb, null), ivirt.fb(A));
    var pixels: [4]u32 = .{ 1, 2, 3, 4 };
    ivirt.publishFb(A, &pixels, 2, 2);
    const f = ivirt.fb(A) orelse return error.NoScanout;
    try expectEqual(@as([*]const u32, &pixels), f.ptr);
    try expectEqual(@as(u32, 2), f.w);
    try expectEqual(@as(u32, 2), f.h);
    const first_gen = f.gen;
    ivirt.publishFb(A, &pixels, 2, 1); // SET_SCANOUT again: new mode, new generation
    const f2 = ivirt.fb(A) orelse return error.NoScanout;
    try expectEqual(first_gen +% 1, f2.gen);
    try expectEqual(@as(u32, 1), f2.h);
    resetAll();
}

test "scanout dims are clamped to the FB_MAX ceiling (torn reads stay in-bounds)" {
    resetAll();
    var pixels: [1]u32 = .{0};
    ivirt.publishFb(A, &pixels, ivirt.FB_MAX_W + 1, ivirt.FB_MAX_H * 2);
    const f = ivirt.fb(A) orelse return error.NoScanout;
    try expectEqual(@as(u32, ivirt.FB_MAX_W), f.w);
    try expectEqual(@as(u32, ivirt.FB_MAX_H), f.h);
    resetAll();
}

test "retractFb makes fb() null" {
    resetAll();
    var pixels: [1]u32 = .{0};
    ivirt.publishFb(A, &pixels, 1, 1);
    try expect(ivirt.fb(A) != null);
    ivirt.retractFb(A);
    try expectEqual(@as(?ivirt.Fb, null), ivirt.fb(A));
    resetAll();
}

test "markFbDirty -> takeFbDirty true once, then false" {
    resetAll();
    try expect(!ivirt.takeFbDirty(A));
    ivirt.markFbDirty(A);
    try expect(ivirt.takeFbDirty(A));
    try expect(!ivirt.takeFbDirty(A)); // one-shot per flush
    resetAll();
}

test "fetch progress: set by hypervisor, read by app, cleared by reset" {
    resetAll();
    // Unset: nothing known, kernel half by default.
    try expectEqual(ivirt.FetchProgress{ .half = .kernel, .done = 0, .total = 0 }, ivirt.fetchProgress(A));

    ivirt.setFetchProgress(A, .initramfs, 1234, 5678);
    try expectEqual(ivirt.FetchProgress{ .half = .initramfs, .done = 1234, .total = 5678 }, ivirt.fetchProgress(A));
    // Slot independence: B never sees A's download.
    try expectEqual(ivirt.FetchProgress{ .half = .kernel, .done = 0, .total = 0 }, ivirt.fetchProgress(B));

    ivirt.reset(A);
    try expectEqual(ivirt.FetchProgress{ .half = .kernel, .done = 0, .total = 0 }, ivirt.fetchProgress(A));
}

test "two VMs are fully independent: state, console, stop and scanout" {
    resetAll();
    // Lifecycle: setting one leaves the other alone.
    ivirt.setState(A, .running);
    ivirt.setState(B, .booting);
    try expectEqual(ivirt.State.running, ivirt.state(A));
    try expectEqual(ivirt.State.booting, ivirt.state(B));

    // Console output: each app reads only its own guest's bytes, in its own order.
    for ("alpha") |b| try expect(ivirt.conWrite(A, b));
    for ("beta") |b| try expect(ivirt.conWrite(B, b));
    for ("alpha") |b| try expectEqual(@as(?u8, b), ivirt.conRead(A));
    try expectEqual(@as(?u8, null), ivirt.conRead(A)); // A's stream ends where A wrote
    for ("beta") |b| try expectEqual(@as(?u8, b), ivirt.conRead(B));

    // Keystrokes: typing into one window never reaches the other guest.
    try expect(ivirt.conInput(A, 'x'));
    try expect(!ivirt.conPending(B));
    try expectEqual(@as(?u8, 'x'), ivirt.conFetch(A));

    // Stop: closing one window stops only that guest.
    ivirt.requestStop(A);
    try expect(!ivirt.stopRequested(B));
    try expect(ivirt.takeStop(A));
    try expect(!ivirt.takeStop(B));

    // Scanout: two guests publish two independent framebuffers.
    var pa: [4]u32 = .{ 1, 1, 1, 1 };
    var pb: [4]u32 = .{ 2, 2, 2, 2 };
    ivirt.publishFb(A, &pa, 2, 2);
    ivirt.publishFb(B, &pb, 1, 1);
    try expectEqual(@as([*]const u32, &pa), (ivirt.fb(A) orelse return error.NoScanout).ptr);
    try expectEqual(@as([*]const u32, &pb), (ivirt.fb(B) orelse return error.NoScanout).ptr);
    // Retracting one leaves the other published.
    ivirt.retractFb(A);
    try expectEqual(@as(?ivirt.Fb, null), ivirt.fb(A));
    try expect(ivirt.fb(B) != null);
    resetAll();
}

test "a full ring on one VM does not drop or count against another" {
    resetAll();
    for (0..ivirt.TX_CAP) |_| try expect(ivirt.conWrite(A, 'x'));
    try expect(!ivirt.conWrite(A, 'x')); // A is full…
    try expect(ivirt.conWrite(B, 'y')); // …B is untouched
    try expectEqual(@as(u64, 1), ivirt.droppedTx(A));
    try expectEqual(@as(u64, 0), ivirt.droppedTx(B));
    resetAll();
}

test "reset clears one slot completely and leaves its neighbour intact" {
    resetAll();
    ivirt.setState(A, .running);
    ivirt.requestStop(A);
    try expect(ivirt.conWrite(A, 'a'));
    try expect(ivirt.conInput(A, 'b'));
    var pixels: [1]u32 = .{0};
    ivirt.publishFb(A, &pixels, 1, 1);
    ivirt.markFbDirty(A);
    for (0..ivirt.TX_CAP) |_| _ = ivirt.conWrite(A, 'x'); // force a counted drop
    try expect(ivirt.droppedTx(A) > 0);

    // The neighbour is set up too, and must survive A's reset untouched.
    ivirt.setState(B, .running);
    try expect(ivirt.conWrite(B, 'z'));

    ivirt.reset(A);
    try expectEqual(ivirt.State.absent, ivirt.state(A));
    try expect(!ivirt.stopRequested(A));
    try expect(!ivirt.takeStop(A));
    try expectEqual(@as(?u8, null), ivirt.conRead(A));
    try expectEqual(@as(?u8, null), ivirt.conFetch(A));
    try expect(!ivirt.conPending(A));
    try expectEqual(@as(u64, 0), ivirt.droppedTx(A));
    try expectEqual(@as(u64, 0), ivirt.droppedRx(A));
    try expectEqual(@as(?ivirt.Fb, null), ivirt.fb(A));
    try expect(!ivirt.takeFbDirty(A));

    try expectEqual(ivirt.State.running, ivirt.state(B));
    try expectEqual(@as(?u8, 'z'), ivirt.conRead(B));
    resetAll();
}

test "every slot up to MAX_VMS is usable and separate" {
    resetAll();
    var id: ivirt.Id = 0;
    while (id < ivirt.MAX_VMS) : (id += 1) {
        ivirt.setState(id, .running);
        try expect(ivirt.conWrite(id, @intCast('0' + id)));
    }
    id = 0;
    while (id < ivirt.MAX_VMS) : (id += 1) {
        try expectEqual(ivirt.State.running, ivirt.state(id));
        try expectEqual(@as(?u8, @intCast('0' + id)), ivirt.conRead(id));
        try expectEqual(@as(?u8, null), ivirt.conRead(id));
    }
    resetAll();
}

test "net bridge: a posted frame crosses to the wire side byte-identical (VIRT-028)" {
    resetAll();
    const frame = [_]u8{ 0x52, 'S', 'V', 'D', 'K', 0, 1, 2, 3, 4, 5, 6, 0x08, 0x00, 0xAA, 0xBB };
    try expect(ivirt.netPost(A, &frame));
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    const len = ivirt.netFetch(A, &buf) orelse return error.NoFrame;
    try expectEqual(frame.len, len);
    try expect(std.mem.eql(u8, &frame, buf[0..len]));
    try expectEqual(@as(?usize, null), ivirt.netFetch(A, &buf));
    resetAll();
}

test "net bridge: delivery and transmit are independent directions (VIRT-029)" {
    resetAll();
    try expect(ivirt.netPost(A, "to-the-wire"));
    try expect(ivirt.netDeliver(A, "to-the-guest"));
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    const rx = ivirt.netTake(A, &buf) orelse return error.NoFrame;
    try expect(std.mem.eql(u8, "to-the-guest", buf[0..rx]));
    try expectEqual(@as(?usize, null), ivirt.netTake(A, &buf));
    const tx = ivirt.netFetch(A, &buf) orelse return error.NoFrame;
    try expect(std.mem.eql(u8, "to-the-wire", buf[0..tx]));
    resetAll();
}

test "net bridge: an oversized frame is refused and counted, never truncated (VIRT-030)" {
    resetAll();
    const big = [_]u8{0xEE} ** (ivirt.NET_FRAME_BYTES + 1);
    try expect(!ivirt.netPost(A, &big));
    try expectEqual(@as(u64, 1), ivirt.droppedNetTx(A));
    try expect(!ivirt.netDeliver(A, &big));
    try expectEqual(@as(u64, 1), ivirt.droppedNetRx(A));
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    try expectEqual(@as(?usize, null), ivirt.netFetch(A, &buf));
    try expectEqual(@as(?usize, null), ivirt.netTake(A, &buf));
    resetAll();
}

test "net bridge: a full ring drops with a count and leaves queued frames intact (VIRT-030)" {
    resetAll();
    var n: usize = 0;
    while (n < ivirt.NET_RING_FRAMES) : (n += 1) try expect(ivirt.netPost(A, "queued"));
    try expect(!ivirt.netPost(A, "overflow"));
    try expectEqual(@as(u64, 1), ivirt.droppedNetTx(A));
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    var drained: usize = 0;
    while (ivirt.netFetch(A, &buf)) |len| : (drained += 1)
        try expect(std.mem.eql(u8, "queued", buf[0..len]));
    try expectEqual(ivirt.NET_RING_FRAMES, drained);
    resetAll();
}

test "net bridge: slots are independent and reset clears rings and counters" {
    resetAll();
    try expect(ivirt.netDeliver(A, "for-a"));
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    try expectEqual(@as(?usize, null), ivirt.netTake(B, &buf));
    ivirt.reset(A);
    try expectEqual(@as(?usize, null), ivirt.netTake(A, &buf));
    try expectEqual(@as(u64, 0), ivirt.droppedNetTx(A));
    try expectEqual(@as(u64, 0), ivirt.droppedNetRx(A));
    resetAll();
}
