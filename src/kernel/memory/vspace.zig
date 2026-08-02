//! Four-level x86-64 page-table builder for virtual address spaces (MEM-001).
//! Pure: it fills caller-provided 4 KiB tables and never touches CR3 or a live
//! TLB — kernel/memory/sessionspace.zig supplies the table pool (from pmm) and
//! owns loading the result. Host-tested (test/kernel/memory/vspace_test.zig) by
//! software-walking the built tables, the same way virt/ept.zig is checked.
//!
//! A space starts as an identity map — virtual == physical, mirroring the boot
//! trampoline's kernel map (boot/boot.asm) — and is then shaped by punching
//! 4 KiB-granular holes: a hole is memory that space cannot reach (MEM-003),
//! which is how one session's private memory is made unreachable from another's
//! space and how a stack guard page is made to fault (MEM-010). Punching splits
//! a covering 1 GiB or 2 MiB leaf into the next smaller table as needed; healing
//! restores the identity mapping over a previously punched range.

pub const PAGE_4K: u64 = 4096;
pub const PAGE_2M: u64 = 2 * 1024 * 1024;
pub const PAGE_1G: u64 = 1024 * 1024 * 1024;
pub const ENTRIES: usize = 512;

/// One 512-entry paging structure (PML4, PDPT, PD, or PT). 4 KiB, 8 bytes/entry.
pub const Table = [ENTRIES]u64;

// Paging-entry bits (Intel SDM Vol 3A §4.5).
const PTE_PRESENT: u64 = 1 << 0;
const PTE_WRITE: u64 = 1 << 1;
const PTE_LEAF: u64 = 1 << 7; // PDPTE/PDE: maps a large page rather than a table
const PTE_ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000; // bits 51:12 physical address

const PTE_RW: u64 = PTE_PRESENT | PTE_WRITE;

/// A pool of zeroed 4 KiB tables the builder allocates from in order. `base_pa`
/// is the physical (== kernel-virtual) address of `tables[0]`; table `i` sits at
/// `base_pa + i*4096`, so an entry's stored address round-trips to a table
/// index. On hardware the backing comes from pmm.allocContiguous; in tests it is
/// any aligned buffer with a chosen `base_pa`.
pub const TablePool = struct {
    tables: []Table,
    base_pa: u64,
    used: usize = 0,

    fn take(self: *TablePool) error{OutOfTables}!usize {
        if (self.used >= self.tables.len) return error.OutOfTables;
        const i = self.used;
        self.used += 1;
        @memset(&self.tables[i], 0);
        return i;
    }

    /// Physical address of table `i`.
    pub fn pa(self: *const TablePool, i: usize) u64 {
        return self.base_pa + @as(u64, i) * PAGE_4K;
    }

    /// Table index for a physical address produced by `pa` — the inverse, used
    /// to follow a pointer entry back to its child table.
    fn indexOf(self: *const TablePool, addr: u64) usize {
        return @intCast((addr - self.base_pa) / PAGE_4K);
    }
};

/// One address space under construction: its PML4's index in the pool. The CR3
/// value to load is `pool.pa(space.pml4)`.
pub const Space = struct {
    pml4: usize,
};

/// The leaf size an identity map is built from. `g1` mirrors the boot
/// trampoline's 1 GiB-page map (512 GiB in one PDPT); `m2` mirrors its 2 MiB
/// fallback. sessionspace picks the one matching the CPU, exactly as
/// boot/boot.asm does.
pub const Leaf = enum { g1, m2 };

/// Start a space: take its PML4 (empty — nothing mapped).
pub fn create(pool: *TablePool) error{OutOfTables}!Space {
    return .{ .pml4 = try pool.take() };
}

/// Identity-map [base, base+len) read-write with `leaf`-sized pages. `base` and
/// `len` must be leaf-aligned. Large-page leaves keep the table cost at one
/// PDPT for 512 GiB (g1) or one PD per GiB (m2); holes are punched afterwards.
pub fn mapIdentity(pool: *TablePool, space: Space, base: u64, len: u64, leaf: Leaf) error{ OutOfTables, Misaligned }!void {
    const step: u64 = if (leaf == .g1) PAGE_1G else PAGE_2M;
    if (base % step != 0 or len % step != 0) return error.Misaligned;
    var va = base;
    while (va < base + len) : (va += step) {
        const l4: usize = @intCast((va >> 39) & 0x1FF);
        const pdpt = try ensureChild(pool, space.pml4, l4);
        if (leaf == .g1) {
            pool.tables[pdpt][@intCast((va >> 30) & 0x1FF)] = va | PTE_RW | PTE_LEAF;
        } else {
            const pd = try ensureChild(pool, pdpt, @intCast((va >> 30) & 0x1FF));
            pool.tables[pd][@intCast((va >> 21) & 0x1FF)] = va | PTE_RW | PTE_LEAF;
        }
    }
}

/// Make [base, base+len) unreachable in `space` (4 KiB granularity; both must be
/// 4 KiB-aligned). A covering 1 GiB or 2 MiB leaf is first split into the next
/// smaller table — every entry outside the hole keeps its identity mapping —
/// except when the hole covers the whole leaf, which is simply cleared. The
/// caller owns TLB invalidation on every core that may have the space live.
pub fn punch(pool: *TablePool, space: Space, base: u64, len: u64) error{ OutOfTables, Misaligned }!void {
    try eachLeafRange(pool, space, base, len, clearPte);
}

/// Restore the identity mapping over [base, base+len) in `space` — the inverse
/// of `punch`, used when a neighbouring session's private range is returned to
/// general kernel use and this space must be able to reach it again. Tables
/// created by earlier splits are reused, never merged back; a range that was
/// never punched is left as it stands.
pub fn heal(pool: *TablePool, space: Space, base: u64, len: u64) error{ OutOfTables, Misaligned }!void {
    try eachLeafRange(pool, space, base, len, setIdentityPte);
}

fn clearPte(_: u64) u64 {
    return 0;
}
fn setIdentityPte(va: u64) u64 {
    return va | PTE_RW;
}

/// Walk [base, base+len) at 4 KiB steps applying `pte(va)` to each PTE, taking
/// the whole-leaf shortcut (clear/restore a 2 MiB entry in place) when the range
/// covers it and splitting otherwise.
fn eachLeafRange(pool: *TablePool, space: Space, base: u64, len: u64, comptime pte: fn (u64) u64) error{ OutOfTables, Misaligned }!void {
    if (base % PAGE_4K != 0 or len % PAGE_4K != 0) return error.Misaligned;
    const end = base + len;
    var va = base;
    while (va < end) {
        const l4: usize = @intCast((va >> 39) & 0x1FF);
        const pdpt = try ensureChild(pool, space.pml4, l4);
        const l3: usize = @intCast((va >> 30) & 0x1FF);
        if (isLeaf(pool.tables[pdpt][l3])) try splitLeaf(pool, pdpt, l3, PAGE_1G);
        const pd = try ensureChild(pool, pdpt, l3);
        const l2: usize = @intCast((va >> 21) & 0x1FF);
        // Whole-2M shortcut: the range covers this entire leaf, so rewrite the
        // PDE itself instead of splitting into 512 PTEs — but ONLY when the PDE
        // is not already a pointer to a PT. Overwriting a PT pointer with a
        // leaf would orphan that table (the pool never reclaims), bleeding the
        // fixed pool dry across churn; the PT path below reuses it instead.
        const leaf_base = va & ~(PAGE_2M - 1);
        const pde = pool.tables[pd][l2];
        const pde_is_table = (pde & PTE_PRESENT != 0) and (pde & PTE_LEAF == 0);
        if (va == leaf_base and end - va >= PAGE_2M and !pde_is_table) {
            const v = pte(va);
            pool.tables[pd][l2] = if (v == 0) 0 else (v | PTE_LEAF);
            va += PAGE_2M;
            continue;
        }
        if (isLeaf(pool.tables[pd][l2])) try splitLeaf(pool, pd, l2, PAGE_2M);
        const pt = try ensureChild(pool, pd, l2);
        while (va < end and (va & ~(PAGE_2M - 1)) == leaf_base) : (va += PAGE_4K) {
            pool.tables[pt][@intCast((va >> 12) & 0x1FF)] = pte(va);
        }
    }
}

fn isLeaf(entry: u64) bool {
    return (entry & PTE_PRESENT != 0) and (entry & PTE_LEAF != 0);
}

/// Replace the large-page leaf at `parent[slot]` with a child table mapping the
/// same range in `size/512` pieces, preserving the identity translation.
fn splitLeaf(pool: *TablePool, parent: usize, slot: usize, size: u64) error{OutOfTables}!void {
    const leaf_base = pool.tables[parent][slot] & PTE_ADDR_MASK;
    const child = try pool.take();
    const piece = size / ENTRIES;
    for (0..ENTRIES) |i| {
        const a = leaf_base + @as(u64, i) * piece;
        pool.tables[child][i] = if (piece == PAGE_4K) a | PTE_RW else a | PTE_RW | PTE_LEAF;
    }
    pool.tables[parent][slot] = pool.pa(child) | PTE_RW;
}

/// Follow `parent[slot]` to its child table, creating the child (as a pointer
/// entry) if the slot is empty. The slot must not hold a large-page leaf — the
/// caller splits first.
fn ensureChild(pool: *TablePool, parent: usize, slot: usize) error{OutOfTables}!usize {
    const entry = pool.tables[parent][slot];
    if (entry & PTE_PRESENT != 0) return pool.indexOf(entry & PTE_ADDR_MASK);
    const child = try pool.take();
    pool.tables[parent][slot] = pool.pa(child) | PTE_RW;
    return child;
}

/// Software-walk `space` for `va`: the physical address it maps to, or null if
/// the walk hits a non-present entry. This is how the host tests prove a built
/// map (and a punched hole) before any hardware walk, and how the verification
/// harness asserts one session's memory does not resolve in another's space
/// (MEM-003/004).
pub fn resolve(pool: *const TablePool, space: Space, va: u64) ?u64 {
    const l4 = pool.tables[space.pml4][@intCast((va >> 39) & 0x1FF)];
    if (l4 & PTE_PRESENT == 0) return null;
    const pdpt = pool.tables[pool.indexOf(l4 & PTE_ADDR_MASK)][@intCast((va >> 30) & 0x1FF)];
    if (pdpt & PTE_PRESENT == 0) return null;
    if (pdpt & PTE_LEAF != 0) return (pdpt & PTE_ADDR_MASK) + (va & (PAGE_1G - 1));
    const pd = pool.tables[pool.indexOf(pdpt & PTE_ADDR_MASK)][@intCast((va >> 21) & 0x1FF)];
    if (pd & PTE_PRESENT == 0) return null;
    if (pd & PTE_LEAF != 0) return (pd & PTE_ADDR_MASK) + (va & (PAGE_2M - 1));
    const pt = pool.tables[pool.indexOf(pd & PTE_ADDR_MASK)][@intCast((va >> 12) & 0x1FF)];
    if (pt & PTE_PRESENT == 0) return null;
    return (pt & PTE_ADDR_MASK) + (va & (PAGE_4K - 1));
}
