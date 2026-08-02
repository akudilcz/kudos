//! Host tests for the virtual-address-space builder (MEM-001, MEM-003,
//! MEM-010): build identity maps at both leaf sizes, punch and heal holes, and
//! check each property by software-walking the tables — the same oracle
//! test/kernel/virt/ept_test.zig uses for the EPT builder.

const std = @import("std");
const vspace = @import("vspace");

const PAGE_4K = vspace.PAGE_4K;
const PAGE_2M = vspace.PAGE_2M;
const PAGE_1G = vspace.PAGE_1G;

/// A pool over test-owned storage. `base_pa` is arbitrary but non-zero so an
/// address-arithmetic slip cannot masquerade as index 0.
fn pool(storage: []vspace.Table) vspace.TablePool {
    return .{ .tables = storage, .base_pa = 0x100000 };
}

test "identity map with 1 GiB leaves resolves virtual == physical (MEM-001)" {
    var storage: [8]vspace.Table = undefined;
    var p = pool(&storage);
    const s = try vspace.create(&p);
    try vspace.mapIdentity(&p, s, 0, 4 * PAGE_1G, .g1);

    try std.testing.expectEqual(@as(?u64, 0), vspace.resolve(&p, s, 0));
    try std.testing.expectEqual(@as(?u64, 0x1234), vspace.resolve(&p, s, 0x1234));
    try std.testing.expectEqual(@as(?u64, 3 * PAGE_1G + 5 * PAGE_2M), vspace.resolve(&p, s, 3 * PAGE_1G + 5 * PAGE_2M));
    // Beyond the mapped range: nothing.
    try std.testing.expectEqual(@as(?u64, null), vspace.resolve(&p, s, 4 * PAGE_1G));
}

test "identity map with 2 MiB leaves resolves virtual == physical (MEM-001)" {
    var storage: [16]vspace.Table = undefined;
    var p = pool(&storage);
    const s = try vspace.create(&p);
    try vspace.mapIdentity(&p, s, 0, 2 * PAGE_1G, .m2);

    try std.testing.expectEqual(@as(?u64, 0xABC000), vspace.resolve(&p, s, 0xABC000));
    try std.testing.expectEqual(@as(?u64, PAGE_1G + 7), vspace.resolve(&p, s, PAGE_1G + 7));
    try std.testing.expectEqual(@as(?u64, null), vspace.resolve(&p, s, 2 * PAGE_1G));
}

test "two spaces translate independently (MEM-001)" {
    var storage: [16]vspace.Table = undefined;
    var p = pool(&storage);
    const a = try vspace.create(&p);
    const b = try vspace.create(&p);
    try vspace.mapIdentity(&p, a, 0, PAGE_1G, .g1);
    try vspace.mapIdentity(&p, b, 0, PAGE_1G, .g1);
    // Punching a hole in `a` leaves `b`'s translation of the same address intact.
    const hole = 5 * PAGE_2M;
    try vspace.punch(&p, a, hole, PAGE_2M);
    try std.testing.expectEqual(@as(?u64, null), vspace.resolve(&p, a, hole));
    try std.testing.expectEqual(@as(?u64, hole), vspace.resolve(&p, b, hole));
}

test "a punched hole is unreachable and its neighbours are not (MEM-003)" {
    var storage: [16]vspace.Table = undefined;
    var p = pool(&storage);
    const s = try vspace.create(&p);
    try vspace.mapIdentity(&p, s, 0, 4 * PAGE_1G, .g1);

    // An unaligned-to-2M, multi-megabyte hole: forces a 1G split, whole-2M
    // clears in the middle, and 4K-granular PT splits at both edges.
    const base = PAGE_1G + 3 * PAGE_2M + 5 * PAGE_4K;
    const len = 2 * PAGE_2M + 7 * PAGE_4K;
    try vspace.punch(&p, s, base, len);

    // Every page inside the hole is gone.
    var va = base;
    while (va < base + len) : (va += PAGE_4K) {
        try std.testing.expectEqual(@as(?u64, null), vspace.resolve(&p, s, va));
    }
    // The pages immediately outside it still translate identity.
    try std.testing.expectEqual(@as(?u64, base - PAGE_4K), vspace.resolve(&p, s, base - PAGE_4K));
    try std.testing.expectEqual(@as(?u64, base + len), vspace.resolve(&p, s, base + len));
    // And a distant address is untouched.
    try std.testing.expectEqual(@as(?u64, 3 * PAGE_1G), vspace.resolve(&p, s, 3 * PAGE_1G));
}

test "a single-page guard hole faults alone (MEM-010)" {
    var storage: [16]vspace.Table = undefined;
    var p = pool(&storage);
    const s = try vspace.create(&p);
    try vspace.mapIdentity(&p, s, 0, PAGE_1G, .g1);

    const guard = 100 * PAGE_2M + 16 * PAGE_4K; // arbitrary interior 4K page
    try vspace.punch(&p, s, guard, PAGE_4K);
    try std.testing.expectEqual(@as(?u64, null), vspace.resolve(&p, s, guard));
    try std.testing.expectEqual(@as(?u64, guard - PAGE_4K), vspace.resolve(&p, s, guard - PAGE_4K));
    try std.testing.expectEqual(@as(?u64, guard + PAGE_4K), vspace.resolve(&p, s, guard + PAGE_4K));
}

test "heal restores identity over a punched range (MEM-007 reuse path)" {
    var storage: [24]vspace.Table = undefined;
    var p = pool(&storage);
    const s = try vspace.create(&p);
    try vspace.mapIdentity(&p, s, 0, 2 * PAGE_1G, .g1);

    const base = 9 * PAGE_2M + 3 * PAGE_4K;
    const len = PAGE_2M;
    try vspace.punch(&p, s, base, len);
    try std.testing.expectEqual(@as(?u64, null), vspace.resolve(&p, s, base));
    try vspace.heal(&p, s, base, len);
    var va = base;
    while (va < base + len) : (va += PAGE_4K) {
        try std.testing.expectEqual(@as(?u64, va), vspace.resolve(&p, s, va));
    }
}

test "misaligned ranges are refused as values, never truncated" {
    var storage: [8]vspace.Table = undefined;
    var p = pool(&storage);
    const s = try vspace.create(&p);
    try std.testing.expectError(error.Misaligned, vspace.mapIdentity(&p, s, 5, PAGE_1G, .g1));
    try vspace.mapIdentity(&p, s, 0, PAGE_1G, .g1);
    try std.testing.expectError(error.Misaligned, vspace.punch(&p, s, 123, PAGE_4K));
    try std.testing.expectError(error.Misaligned, vspace.punch(&p, s, PAGE_4K, 123));
}

test "an exhausted pool is an error, not a partial map" {
    var storage: [1]vspace.Table = undefined; // room for the PML4 only
    var p = pool(&storage);
    const s = try vspace.create(&p);
    try std.testing.expectError(error.OutOfTables, vspace.mapIdentity(&p, s, 0, PAGE_1G, .g1));
}

test "a whole-leaf operation reuses an existing split table, never orphans it" {
    var storage: [24]vspace.Table = undefined;
    var p = pool(&storage);
    const s = try vspace.create(&p);
    try vspace.mapIdentity(&p, s, 0, PAGE_1G, .g1);

    // Split leaf 9 down to 4 KiB with a single-page hole…
    const leaf = 9 * PAGE_2M;
    try vspace.punch(&p, s, leaf + 3 * PAGE_4K, PAGE_4K);
    const used_after_split = p.used;
    // …then cover the whole leaf with a punch and a heal. Neither may take a
    // fresh table (the PT is reused), and the final state is fully mapped.
    try vspace.punch(&p, s, leaf, PAGE_2M);
    try std.testing.expectEqual(@as(?u64, null), vspace.resolve(&p, s, leaf + 7 * PAGE_4K));
    try vspace.heal(&p, s, leaf, PAGE_2M);
    try std.testing.expectEqual(used_after_split, p.used);
    var va = leaf;
    while (va < leaf + PAGE_2M) : (va += PAGE_4K) {
        try std.testing.expectEqual(@as(?u64, va), vspace.resolve(&p, s, va));
    }
}
