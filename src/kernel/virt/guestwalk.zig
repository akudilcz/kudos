//! Software walk of the guest's own long-mode page tables (Intel SDM Vol 3A
//! §4.5, "4-Level Paging"). Pure: it reads paging structures out of the guest-RAM
//! slice, where index == guest-physical address, and never touches a hardware
//! register. Host-tested (test/kernel/virt/guestwalk_test.zig) with hand-built tables.
//!
//! The machine model needs this on a memory-mapped-IO exit: the VMCS reports the
//! faulting guest-physical address, but the instruction bytes live at the guest
//! RIP — a guest-VIRTUAL address the guest's CR3 maps (a Linux kernel text
//! address like 0xffffffff81xxxxxx). `fetch` resolves and copies those bytes so
//! the instruction decoder (virt/insn.zig) can see them.
//!
//! Scope: 4-level paging only — the guest boot tables (virt/gpt.zig) and the
//! staged kernels are built without 5-level paging (LA57), and the CPUID filter
//! never advertises it. Permission and access bits are ignored: the walk serves
//! emulation of an access the guest already performed, not enforcement.

const std = @import("std");

// Paging-entry bits, spelled as the SDM spells them (Vol 3A Table 4-19).
const PTE_P: u64 = 1 << 0; // present
const PTE_PS: u64 = 1 << 7; // PDPTE/PDE: maps a large page rather than a table

/// Bits 51:12 — the physical address field of a table pointer or 4 KiB leaf;
/// also the mask that strips CR3's PCID/flag bits (SDM Vol 3A §4.5.2).
const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

const PAGE_4K: u64 = 4096;
const PAGE_2M: u64 = 2 * 1024 * 1024;
const PAGE_1G: u64 = 1024 * 1024 * 1024;

const ENTRY_BYTES: u64 = 8;
const INDEX_MASK: u64 = 0x1FF; // 9 bits per level

/// Translate guest-virtual `vaddr` through the guest's tables rooted at `cr3`,
/// returning the guest-physical address or null when any structure is
/// non-present or lies outside guest RAM. The returned address is NOT
/// bounds-checked against `ram` — a leaf may legitimately point at a
/// memory-mapped-IO hole; callers that need RAM bytes use `fetch`.
pub fn translate(ram: []const u8, cr3: u64, vaddr: u64) ?u64 {
    const l4: u64 = (vaddr >> 39) & INDEX_MASK;
    const l3: u64 = (vaddr >> 30) & INDEX_MASK;
    const l2: u64 = (vaddr >> 21) & INDEX_MASK;
    const l1: u64 = (vaddr >> 12) & INDEX_MASK;

    const e4 = entry(ram, cr3 & ADDR_MASK, l4) orelse return null;
    if (e4 & PTE_P == 0) return null;

    const e3 = entry(ram, e4 & ADDR_MASK, l3) orelse return null;
    if (e3 & PTE_P == 0) return null;
    if (e3 & PTE_PS != 0) return leaf(e3, vaddr, PAGE_1G);

    const e2 = entry(ram, e3 & ADDR_MASK, l2) orelse return null;
    if (e2 & PTE_P == 0) return null;
    if (e2 & PTE_PS != 0) return leaf(e2, vaddr, PAGE_2M);

    const e1 = entry(ram, e2 & ADDR_MASK, l1) orelse return null;
    if (e1 & PTE_P == 0) return null;
    return leaf(e1, vaddr, PAGE_4K);
}

/// Copy `out.len` bytes of guest-virtual memory into `out`, translating page by
/// page so a run crossing a 4 KiB boundary resolves each page separately.
/// Returns false — with `out` partially written — when any page fails to
/// translate or the resolved bytes fall outside guest RAM.
pub fn fetch(ram: []const u8, cr3: u64, vaddr: u64, out: []u8) bool {
    var done: usize = 0;
    while (done < out.len) {
        const va = vaddr + done;
        const gpa = translate(ram, cr3, va) orelse return false;
        const page_left: usize = @intCast(PAGE_4K - (va & (PAGE_4K - 1)));
        const n = @min(out.len - done, page_left);
        if (gpa + n > ram.len) return false;
        @memcpy(out[done .. done + n], ram[@intCast(gpa)..@intCast(gpa + n)]);
        done += n;
    }
    return true;
}

/// Read paging entry `index` of the table at guest-physical `table_gpa`, or
/// null when the entry lies outside guest RAM.
fn entry(ram: []const u8, table_gpa: u64, index: u64) ?u64 {
    const off = table_gpa + index * ENTRY_BYTES;
    if (off + ENTRY_BYTES > ram.len) return null;
    return std.mem.readInt(u64, ram[@intCast(off)..][0..8], .little);
}

/// Compose the guest-physical address of a leaf mapping: the entry's page frame
/// plus the virtual address's offset within a page of `page_bytes`.
fn leaf(e: u64, vaddr: u64, page_bytes: u64) u64 {
    return (e & ADDR_MASK & ~(page_bytes - 1)) + (vaddr & (page_bytes - 1));
}
