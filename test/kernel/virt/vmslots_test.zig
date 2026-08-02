//! Host tests of src/kernel/virt/vmslots.zig — the VM slot retirement handshake.
//! The property under test is the one that makes closing a VM window safe: a slot
//! is reusable only once BOTH its window and its vCPU have let go, so a new guest
//! can never be handed a slot the outgoing guest is still writing to, nor one a
//! still-open window is still reading from. The second property: the two holds are
//! taken at different times, so a slot reserved for a guest that does not exist
//! yet reads as held but NOT running — nothing may execute it.

const std = @import("std");
const vmslots = @import("vmslots");
const testing = std.testing;

/// Three slots — enough to exercise exhaustion and the lowest-free choice while
/// keeping every case readable.
const Reg = vmslots.Registry(3);

test "a fresh registry has every slot free and nothing running" {
    var r = Reg.init;
    var id: usize = 0;
    while (id < 3) : (id += 1) {
        try testing.expect(r.isFree(id));
        try testing.expect(!r.inUse(id));
        try testing.expect(!r.isRunning(id));
        try testing.expectEqual(@as(?u32, null), r.coreOf(id));
    }
    try testing.expectEqual(@as(usize, 0), r.inUseCount());
}

test "claim takes the lowest free slot; the vCPU reports its core later" {
    var r = Reg.init;
    try testing.expectEqual(@as(?usize, 0), r.claim());
    try testing.expect(!r.isFree(0));
    try testing.expect(r.inUse(0));
    // No core yet: the vCPU task has not been placed by the scheduler
    // (VIRT-021 — the core is the SCHEDULER'S choice, discovered, not assigned).
    try testing.expectEqual(@as(?u32, null), r.coreOf(0));
    r.vcpuStarted(0);
    try testing.expect(r.isRunning(0));
    r.setCore(0, 1);
    try testing.expectEqual(@as(?u32, 1), r.coreOf(0));
    // A second guest takes the next slot and reports its own core.
    try testing.expectEqual(@as(?usize, 1), r.claim());
    r.setCore(1, 2);
    try testing.expectEqual(@as(?u32, 2), r.coreOf(1));
    try testing.expectEqual(@as(usize, 2), r.inUseCount());
    // Untouched slots stay free.
    try testing.expect(r.isFree(2));
}

test "window close alone does NOT free the slot (the vCPU still owns it)" {
    var r = Reg.init;
    const id = r.claim().?;
    r.vcpuStarted(id);
    r.windowClosed(id);
    // The guest is still running and still writing its mailbox — reusing the slot
    // here is exactly the bug the handshake prevents.
    try testing.expect(!r.isFree(id));
    try testing.expect(r.isRunning(id));
    try testing.expectEqual(@as(usize, 1), r.inUseCount());
    // Only when the vCPU has finished does it become reusable.
    r.vcpuDone(id);
    try testing.expect(r.isFree(id));
    try testing.expect(!r.isRunning(id));
    try testing.expectEqual(@as(usize, 0), r.inUseCount());
}

test "vCPU exit alone does NOT free the slot (the window still shows it)" {
    var r = Reg.init;
    const id = r.claim().?;
    r.vcpuStarted(id);
    r.setCore(id, 1);
    // The guest halted by itself; its window still displays the halted console.
    r.vcpuDone(id);
    try testing.expect(!r.isRunning(id));
    try testing.expect(!r.isFree(id)); // …but not reusable: the window holds it
    try testing.expect(r.inUse(id));
    try testing.expectEqual(@as(?u32, 1), r.coreOf(id));
    // Closing the window is what finally retires it.
    r.windowClosed(id);
    try testing.expect(r.isFree(id));
}

test "a retired slot is handed out again, in either release order" {
    var r = Reg.init;
    // Order 1: window first, then vCPU.
    const first = r.claim().?;
    r.vcpuStarted(first);
    r.setCore(first, 1);
    r.windowClosed(first);
    r.vcpuDone(first);
    try testing.expectEqual(@as(?usize, first), r.claim());
    // A recycled slot starts with no core: the NEW vCPU has not been placed.
    try testing.expectEqual(@as(?u32, null), r.coreOf(first));
    r.setCore(first, 2);
    try testing.expectEqual(@as(?u32, 2), r.coreOf(first));
    // Order 2: vCPU first, then window.
    r.vcpuDone(first);
    r.windowClosed(first);
    try testing.expectEqual(@as(?usize, first), r.claim());
    try testing.expectEqual(@as(?u32, null), r.coreOf(first));
}

test "claim returns null when every slot is in use" {
    var r = Reg.init;
    try testing.expectEqual(@as(?usize, 0), r.claim());
    try testing.expectEqual(@as(?usize, 1), r.claim());
    try testing.expectEqual(@as(?usize, 2), r.claim());
    try testing.expectEqual(@as(usize, 3), r.inUseCount());
    try testing.expectEqual(@as(?usize, null), r.claim());
    // A half-retired slot is still not handed out.
    r.vcpuStarted(1);
    r.vcpuDone(1);
    try testing.expectEqual(@as(?usize, null), r.claim());
    // Fully retired: it is the one that gets reused.
    r.windowClosed(1);
    try testing.expectEqual(@as(?usize, 1), r.claim());
}

test "a reserved slot with no machine in it does not read as running" {
    var r = Reg.init;
    // What a network boot looks like between the moment it claims a slot and the
    // moment its download finishes: the slot is held against reuse, but there is
    // no machine in it. A run driver that mistakes "reserved" for "runnable"
    // executes a VMCS that was never written — VMXON has not even happened, so
    // the VMPTRLD raises #UD and takes the kernel down with it.
    const id = r.claim().?;
    try testing.expect(!r.isRunning(id)); // nothing to run yet
    try testing.expect(!r.isFree(id)); // …but nobody else may have the slot
    try testing.expect(r.inUse(id)); // and a listing still shows it
    try testing.expectEqual(@as(?u32, null), r.coreOf(id)); // no vCPU placed yet
    // The download lands and the machine is built: NOW it is runnable.
    r.vcpuStarted(id);
    try testing.expect(r.isRunning(id));
}

test "abandon gives back a slot reserved for a guest that never existed" {
    var r = Reg.init;
    const id = r.claim().?;
    // VM creation failed: no vCPU was ever started, so core 0 releases both holds
    // at once and the slot is immediately reusable.
    r.abandon(id);
    try testing.expect(r.isFree(id));
    try testing.expect(!r.isRunning(id));
    try testing.expectEqual(@as(usize, 0), r.inUseCount());
    try testing.expectEqual(@as(?usize, id), r.claim());
}

test "two guests retire independently" {
    var r = Reg.init;
    const a = r.claim().?;
    const b = r.claim().?;
    r.vcpuStarted(a);
    r.vcpuStarted(b);
    r.setCore(b, 2);
    // Close the first window; the second guest is untouched.
    r.windowClosed(a);
    r.vcpuDone(a);
    try testing.expect(r.isFree(a));
    try testing.expect(r.isRunning(b));
    try testing.expectEqual(@as(?u32, 2), r.coreOf(b));
    try testing.expectEqual(@as(usize, 1), r.inUseCount());
    // The freed slot is reusable while the other guest keeps running.
    try testing.expectEqual(@as(?usize, a), r.claim());
    try testing.expect(r.isRunning(b));
}
