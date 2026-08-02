//! Extended Page Tables builder (Intel SDM Vol 3C §29.3). Pure: it fills
//! caller-provided 4 KiB tables to describe a guest-physical → host-physical
//! translation and never touches a real page table or CR3. virt/guestmem.zig
//! supplies the table pool (from pmm) and the EPTP is written into the VMCS by
//! virt/vcpu.zig. Host-tested (test/kernel/virt/ept_test.zig) by software-walking the built
//! tables — the one place we can check the map before a real EPT walk faults.
//!
//! The map is an identity-with-offset: guest-physical `g` in [0, len) resolves to
//! host-physical `hpa_base + g`. Because the kudos host address space is itself an
//! identity map (host-phys == kernel-virt), that host-physical is directly
//! writable Zig memory — which is what lets the machine model fill guest RAM by
//! slicing. Leaves are 2 MiB pages: guest RAM is 2 MiB-aligned and a whole number
//! of 2 MiB pages (guestmem guarantees it), so every leaf is naturally aligned in
//! both address spaces.

pub const vmxcaps = @import("vmxcaps.zig");

pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_2M: u64 = 2 * 1024 * 1024;
pub const GIB: u64 = 1024 * 1024 * 1024;
pub const ENTRIES: usize = 512;

/// One 512-entry EPT paging structure (PML4, PDPT, or PD). 4 KiB, 8 bytes/entry.
pub const Table = [ENTRIES]u64;

// EPT paging-entry bits (SDM Vol 3C Tables 29-1..29-6).
const EPT_READ: u64 = 1 << 0;
const EPT_WRITE: u64 = 1 << 1;
const EPT_EXEC: u64 = 1 << 2;
const EPT_RWX: u64 = EPT_READ | EPT_WRITE | EPT_EXEC;
const EPT_MEMTYPE_WB: u64 = 6 << 3; // leaf only: EPT memory type = write-back
const EPT_IGNORE_PAT: u64 = 1 << 6; // leaf only
const EPT_LEAF: u64 = 1 << 7; // PDPTE/PDE: maps a large page rather than a table
const EPT_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000; // bits 51:12 physical address

/// A pool of zeroed 4 KiB tables the builder allocates from in order. `base_hpa`
/// is the host-physical (== kernel-virtual) address of `tables[0]`; table `i` sits
/// at `base_hpa + i*4096`, so an entry's stored address round-trips to a table
/// index. On hardware the backing comes from pmm.allocContiguous; in tests it is
/// any aligned buffer with a chosen `base_hpa`.
pub const TablePool = struct {
    tables: []Table,
    base_hpa: u64,
    used: usize = 0,

    fn take(self: *TablePool) error{OutOfTables}!usize {
        if (self.used >= self.tables.len) return error.OutOfTables;
        const i = self.used;
        self.used += 1;
        @memset(&self.tables[i], 0);
        return i;
    }

    /// Host-physical address of table `i`.
    pub fn hpa(self: *const TablePool, i: usize) u64 {
        return self.base_hpa + @as(u64, i) * PAGE_SIZE;
    }

    /// Table index for a host-physical address produced by `hpa` — the inverse,
    /// used to follow a pointer entry back to its child table while building.
    fn indexOf(self: *const TablePool, addr: u64) usize {
        return @intCast((addr - self.base_hpa) / PAGE_SIZE);
    }
};

/// Tables required to map `guest_len` bytes with 2 MiB leaves: one PML4, one PDPT
/// per 512 GiB, one PD per GiB. Leaves live in the PDs, so no PT tables. The pool
/// guestmem allocates must hold at least this many.
pub fn tablePagesNeeded(guest_len: u64) usize {
    const num_pd = (guest_len + GIB - 1) / GIB;
    const num_pdpt = (num_pd + 511) / 512;
    return @intCast(1 + num_pdpt + num_pd);
}

/// Build a 2 MiB-page identity-offset EPT map of [0, len) → [hpa_base, hpa_base+len).
/// `hpa_base` and `len` must be 2 MiB-aligned. Returns the host-physical address of
/// the PML4 (feed it to `eptp`). Requires 2 MiB EPT pages, which every VT-x CPU we
/// target (and nested KVM) provides.
pub fn buildOffsetMap(pool: *TablePool, hpa_base: u64, len: u64, caps: vmxcaps.EptCaps) error{ OutOfTables, NoLargePages, Misaligned }!u64 {
    if (!caps.page_2m) return error.NoLargePages;
    if (hpa_base % PAGE_2M != 0 or len % PAGE_2M != 0) return error.Misaligned;

    const pml4 = try pool.take();
    var gpa: u64 = 0;
    while (gpa < len) : (gpa += PAGE_2M) {
        const l4: usize = @intCast((gpa >> 39) & 0x1FF);
        const l3: usize = @intCast((gpa >> 30) & 0x1FF);
        const l2: usize = @intCast((gpa >> 21) & 0x1FF);
        const pdpt = try ensureChild(pool, pml4, l4);
        const pd = try ensureChild(pool, pdpt, l3);
        pool.tables[pd][l2] = (hpa_base + gpa) | EPT_RWX | EPT_MEMTYPE_WB | EPT_IGNORE_PAT | EPT_LEAF;
    }
    return pool.hpa(pml4);
}

/// Follow `parent[slot]` to its child table, creating the child (as a pointer
/// entry with R/W/X) if the slot is empty.
fn ensureChild(pool: *TablePool, parent: usize, slot: usize) error{OutOfTables}!usize {
    const entry = pool.tables[parent][slot];
    if (entry & EPT_READ != 0) return pool.indexOf(entry & EPT_ADDR_MASK);
    const child = try pool.take();
    pool.tables[parent][slot] = pool.hpa(child) | EPT_RWX;
    return child;
}

/// Compose the EPT pointer (VMCS field ept_pointer): WB memory type, 4-level walk
/// (length−1 = 3), optional access/dirty bits, and the PML4 host-physical address
/// (SDM Vol 3C §24.6.11).
pub fn eptp(pml4_hpa: u64, caps: vmxcaps.EptCaps) u64 {
    var v: u64 = 6; // bits 2:0 memory type = write-back
    v |= 3 << 3; // bits 5:3 page-walk length − 1 = 3 (four levels)
    if (caps.ad_bits) v |= 1 << 6; // enable accessed/dirty flags when supported
    v |= pml4_hpa & EPT_ADDR_MASK;
    return v;
}

/// The result of a software EPT walk (tests, and diagnostics on an EPT violation).
pub const Translation = struct {
    hpa: u64,
    r: bool,
    w: bool,
    x: bool,
    page_bytes: u64,
};

/// Walk the built tables for `gpa`, returning its host-physical mapping or null if
/// unmapped. `deref` turns a table host-physical address into the table itself —
/// on the host, the pool's linear mapping; on hardware, identity. Handles a 2 MiB
/// leaf at the PD level (what `buildOffsetMap` produces) and, defensively, a 1 GiB
/// leaf at the PDPT level.
pub fn translate(pml4_hpa: u64, deref: *const fn (u64) *const Table, gpa: u64) ?Translation {
    const l4: usize = @intCast((gpa >> 39) & 0x1FF);
    const l3: usize = @intCast((gpa >> 30) & 0x1FF);
    const l2: usize = @intCast((gpa >> 21) & 0x1FF);

    const pml4 = deref(pml4_hpa);
    const e4 = pml4[l4];
    if (e4 & EPT_READ == 0) return null;

    const pdpt = deref(e4 & EPT_ADDR_MASK);
    const e3 = pdpt[l3];
    if (e3 & EPT_READ == 0) return null;
    if (e3 & EPT_LEAF != 0) { // 1 GiB page
        return leaf(e3, gpa, GIB);
    }

    const pd = deref(e3 & EPT_ADDR_MASK);
    const e2 = pd[l2];
    if (e2 & EPT_READ == 0) return null;
    if (e2 & EPT_LEAF != 0) { // 2 MiB page
        return leaf(e2, gpa, PAGE_2M);
    }
    return null; // no 4 KiB PT level in this builder
}

fn leaf(entry: u64, gpa: u64, page_bytes: u64) Translation {
    const page_base = entry & EPT_ADDR_MASK & ~(page_bytes - 1);
    return .{
        .hpa = page_base + (gpa & (page_bytes - 1)),
        .r = entry & EPT_READ != 0,
        .w = entry & EPT_WRITE != 0,
        .x = entry & EPT_EXEC != 0,
        .page_bytes = page_bytes,
    };
}

/// INVEPT descriptor (SDM Vol 3C §30.3 "INVEPT"): a 128-bit operand whose low
/// 64 bits are the EPTP and high 64 bits are reserved zero. The IO-edge wrapper in
/// virt/vmxasm.zig points INVEPT at this.
pub const InveptDescriptor = extern struct {
    eptp: u64,
    reserved: u64 = 0,
};

/// INVEPT types (SDM Vol 3C §30.3).
pub const INVEPT_SINGLE_CONTEXT: u64 = 1;
pub const INVEPT_ALL_CONTEXT: u64 = 2;
