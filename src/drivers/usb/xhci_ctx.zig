//! xHCI context + TRB bit packing — pure, so it can be host-tested.
//!
//! WHY THIS IS NOT IN xhci.zig. Two reasons, and the second is the one that bites:
//!
//! 1. These are field encoders. A wrong shift means Address Device answers Parameter
//!    Error and USB is simply absent — loud, but only *after* a boot.
//!
//! 2. **The CONTEXT STRIDE is a QEMU/real-hardware divergence.** HCCPARAMS1.CSZ says
//!    whether a device context is 32 or 64 bytes. QEMU's xHC reports 32. Real xHCs —
//!    including lemon's Intel PCH — report **64**. So every context-array index in
//!    the driver is computed with a stride that emulation never exercises, and an
//!    off-by-one-context bug writes an endpoint context on top of the slot context of
//!    the next device while every emulated boot stays perfectly green.
//!
//! The driver keeps the MMIO writes; this owns the arithmetic.

const std = @import("std");

// ── TRB control word ─────────────────────────────────────────────────────────
/// Build a TRB control word: type in bits 15:10, plus the given flags. The ring's
/// cycle bit (bit 0) is OR'd in by Ring.push, so it is never set here.
pub fn ctrl(trb_type: u32, flags: u32) u32 {
    return (trb_type << 10) | flags;
}

/// Type field of any TRB (control bits 15:10).
pub fn trbType(control: u32) u32 {
    return (control >> 10) & 0x3F;
}

// ── context array addressing ─────────────────────────────────────────────────
/// Byte offset of DWord `dword` of context slot `idx`, for a controller whose
/// context size is `context_size` (32 or 64 — HCCPARAMS1.CSZ).
///
/// THE STRIDE IS THE WHOLE POINT. Hard-code 32 and it works flawlessly on QEMU and
/// scribbles over the next context on every real controller.
pub fn ctxOffset(context_size: usize, idx: usize, dword: usize) usize {
    return idx * context_size + dword * 4;
}

// ── endpoint context ─────────────────────────────────────────────────────────
// Endpoint Context DW1 (xHCI §6.2.3): EP Type (bits 5:3), CErr (bits 2:1),
// Max Packet Size (bits 31:16).
pub const EP_TYPE_CONTROL: u32 = 4;
pub const EP_TYPE_BULK_OUT: u32 = 2;
pub const EP_TYPE_BULK_IN: u32 = 6;
pub const EP_TYPE_INTERRUPT_IN: u32 = 7;
pub const EP_CERR: u32 = 3 << 1; // CErr = 3 (max transfer-error retries)
pub const EP_DCS: u32 = 1; // Dequeue Cycle State, bit 0 of the TR Dequeue Pointer

/// Endpoint Context DW1: EP Type | CErr | Max Packet Size.
pub fn epDw1(ep_type: u32, mps: u32) u32 {
    return (ep_type << 3) | EP_CERR | (mps << 16);
}

/// Slot Context DW0: route string (bits 19:0) | speed (23:20) | Context Entries
/// (31:27), plus any extra bits (e.g. the Hub flag). xHCI §6.2.2 Table 6-4.
pub fn slotDw0(route: u32, ctx_entries: u32, speed: u32, extra: u32) u32 {
    return route | (ctx_entries << 27) | (speed << 20) | extra;
}

/// The TR Dequeue Pointer, split lo/hi with DCS set in bit 0 of the low dword.
pub fn trDequeueLo(phys: u64) u32 {
    return @truncate(phys | EP_DCS);
}
pub fn trDequeueHi(phys: u64) u32 {
    return @truncate(phys >> 32);
}

// ── SETUP packet ─────────────────────────────────────────────────────────────
/// The 8-byte USB SETUP packet, packed into the u64 a Setup Stage TRB carries
/// inline (TRB_IDT). Little-endian field order: bmRequestType, bRequest, wValue,
/// wIndex, wLength.
pub fn setupPkt(bm_request_type: u8, b_request: u8, w_value: u16, w_index: u16, w_length: u16) u64 {
    return @as(u64, bm_request_type) |
        (@as(u64, b_request) << 8) |
        (@as(u64, w_value) << 16) |
        (@as(u64, w_index) << 32) |
        (@as(u64, w_length) << 48);
}
