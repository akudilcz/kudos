//! Host tests of src/kernel/virt/vmxcaps.zig — the capability-MSR adjust math.
//!
//! Fixtures are the actual VMX capability MSRs of the development machine (an
//! Intel Core Ultra 7 255U), captured once with `rdmsr` and pasted here as hex.
//! Testing the adjust/fixed-bit math against real allowed-settings words is what
//! proves a mask was not inverted — the failure mode that otherwise surfaces only
//! as a VM-entry failure under nested VMX, which no host test could reach.

const std = @import("std");
const caps = @import("vmxcaps");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

// --- Captured capability MSRs (Core Ultra 7 255U, nested KVM host) ---
const BASIC: u64 = 0x3da050000000013; // IA32_VMX_BASIC (0x480)
const TRUE_PIN: u64 = 0xff00000016; // IA32_VMX_TRUE_PINBASED_CTLS (0x48D)
const CR0_FIXED0: u64 = 0x80000021; // IA32_VMX_CR0_FIXED0 (0x486)
const CR0_FIXED1: u64 = 0xffffffff; // IA32_VMX_CR0_FIXED1 (0x487)
const CR4_FIXED0: u64 = 0x2000; // IA32_VMX_CR4_FIXED0 (0x488)
const CR4_FIXED1: u64 = 0x1f76fff; // IA32_VMX_CR4_FIXED1 (0x489)
const EPT_VPID: u64 = 0xf0106f34141; // IA32_VMX_EPT_VPID_CAP (0x48C)

test "IA32_VMX_BASIC decode" {
    try expectEqual(@as(u31, 0x13), caps.revisionId(BASIC));
    try expectEqual(@as(u32, 1280), caps.regionSize(BASIC));
    try expectEqual(true, caps.usesTrueControls(BASIC));
    try expectEqual(@as(u4, 6), caps.vmcsMemoryType(BASIC)); // 6 = write-back
}

test "adjustControls forces reserved must-be-1 bits and honors what we ask for" {
    // TRUE_PIN low = 0x16 (bits 1,2,4 must be 1); high = 0xff (bits 0..7 allowed).
    // Ask for external-interrupt-exiting (bit 0) + NMI-exiting (bit 3).
    const got = try caps.adjustControls(TRUE_PIN, (1 << 0) | (1 << 3), 0);
    try expectEqual(@as(u32, 0x1F), got); // 0x16 | 0x09
}

test "adjustControls rejects a wanted-on bit the CPU forbids" {
    // Pin-based bit 8 is not allowed-1 (high byte is 0xff → bits 0..7 only).
    try expectError(error.Unsupported, caps.adjustControls(TRUE_PIN, 1 << 8, 0));
}

test "adjustControls rejects a wanted-off bit the CPU forces on" {
    // Bit 1 is a reserved must-be-1 pin control; asking to clear it must fail.
    try expectError(error.Unsupported, caps.adjustControls(TRUE_PIN, 0, 1 << 1));
}

test "applyCrFixed forces the VMX-required control-register bits" {
    // CR0 must gain PE(0), NE(5), PG(31); nothing is forced off (FIXED1 = all-ones).
    try expectEqual(@as(u64, 0x80000021), caps.applyCrFixed(0, CR0_FIXED0, CR0_FIXED1));
    // CR4 must gain VMXE (bit 13); it survives the FIXED1 mask.
    try expectEqual(@as(u64, 0x2000), caps.applyCrFixed(0, CR4_FIXED0, CR4_FIXED1));
    // A bit absent from CR4_FIXED1 (e.g. bit 31) is forced back off.
    try expectEqual(@as(u64, 0x2000), caps.applyCrFixed(0x80000000, CR4_FIXED0, CR4_FIXED1));
}

test "applyCrFixed is idempotent on an already-legal value" {
    const once = caps.applyCrFixed(0, CR0_FIXED0, CR0_FIXED1);
    try expectEqual(once, caps.applyCrFixed(once, CR0_FIXED0, CR0_FIXED1));
}

test "a guest CR0 keeps PE and PG its own under unrestricted-guest mode" {
    // Only NE(5) is still forced on: PE(0) and PG(31) are exempt, so a guest
    // that has turned paging off stays legal for the next VM entry. Forcing PG
    // back on here is what re-entered every pre-6.1 Linux decompressor in long
    // mode with a 32-bit trampoline's state, and it triple-faulted.
    try expectEqual(@as(u64, 0x20), caps.applyGuestCr0Fixed(0, CR0_FIXED0, CR0_FIXED1));
    // A guest that IS paged keeps both bits — the exemption never clears a bit.
    try expectEqual(@as(u64, 0x80000021), caps.applyGuestCr0Fixed(0x80000001, CR0_FIXED0, CR0_FIXED1));
    // Protected mode, paging off: exactly the trampoline's state, and legal.
    try expectEqual(@as(u64, 0x21), caps.applyGuestCr0Fixed(0x1, CR0_FIXED0, CR0_FIXED1));
    // FIXED1's must-be-0 bits are still honoured — the exemption is not a bypass.
    try expectEqual(@as(u64, 0x20), caps.applyGuestCr0Fixed(0, CR0_FIXED0, CR0_FIXED1 & ~@as(u64, 1 << 31)));
}

test "the pinned guest CR0 bits are the must-be-1 bits minus PE and PG" {
    // NE, and only NE, on a part whose FIXED0 is the usual PE|NE|PG. These are
    // the bits that become the CR0 guest/host mask, so the set must be exactly
    // the ones the guest may not be allowed to write for itself: too few and a
    // guest write raises an unhandleable #GP, too many and every ordinary CR0
    // write in the guest becomes a VM exit.
    try expectEqual(@as(u64, 0x20), caps.guestCr0PinnedBits(CR0_FIXED0));
    // The exemption is the only thing removed: a hypothetical part that also
    // pinned CR0.WP would have that bit owned too.
    try expectEqual(@as(u64, 0x10020), caps.guestCr0PinnedBits(CR0_FIXED0 | (1 << 16)));
    // And a part pinning nothing but PE/PG leaves the guest all of CR0.
    try expectEqual(@as(u64, 0), caps.guestCr0PinnedBits(0x8000_0001));
}

test "EPT capability decode" {
    const e = caps.eptCaps(EPT_VPID);
    try expectEqual(true, e.walk_length_4);
    try expectEqual(true, e.memtype_wb);
    try expectEqual(true, e.page_2m);
    try expectEqual(true, e.page_1g);
    try expectEqual(true, e.invept_supported);
}
