//! Host tests of src/drivers/gl/extent_heap.zig — the VA-extent free list the
//! GL device carves its buffer/texture regions from. The invariants that keep
//! VRAM usable across window churn: every allocation is page-rounded, a freed
//! block coalesces with BOTH abutting neighbours, and a full free list loses
//! the block loudly instead of corrupting the list.

const std = @import("std");
const extent_heap = @import("extent_heap");
const ExtentHeap = extent_heap.ExtentHeap;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const PAGE: u64 = 0x1000;
const BASE: u64 = 0x40_0000;

test "alloc is first-fit and rounds every request up to a page" {
    var h = ExtentHeap.init(BASE, 16 * PAGE);
    try expectEqual(BASE, h.alloc(1).?); // 1 byte still consumes a page
    try expectEqual(BASE + PAGE, h.alloc(PAGE).?);
    try expectEqual(BASE + 2 * PAGE, h.alloc(PAGE + 1).?); // rounds to 2 pages
    try expectEqual(BASE + 4 * PAGE, h.alloc(1).?);
}

test "an exact fit spends the extent; an oversize request returns null" {
    var h = ExtentHeap.init(BASE, PAGE);
    try expect(h.alloc(2 * PAGE) == null); // never over-serves
    try expectEqual(BASE, h.alloc(PAGE).?);
    try expectEqual(@as(usize, 0), h.n); // spent, not left as a zero extent
    try expect(h.alloc(1) == null); // empty heap serves nothing
}

test "free coalesces with both neighbours back into one extent" {
    var h = ExtentHeap.init(BASE, 3 * PAGE);
    const a = h.alloc(PAGE).?;
    const b = h.alloc(PAGE).?;
    const c = h.alloc(PAGE).?;
    try expectEqual(@as(usize, 0), h.n);

    try expect(h.freeBlock(a, PAGE) == null);
    try expect(h.freeBlock(c, PAGE) == null);
    try expectEqual(@as(usize, 2), h.n); // a and c do not touch: two extents

    // Freeing b bridges them: one extent spanning the whole region again.
    try expect(h.freeBlock(b, PAGE) == null);
    try expectEqual(@as(usize, 1), h.n);
    try expectEqual(BASE, h.alloc(3 * PAGE).?);
}

test "free rounds a byte count up to a page, so no unusable sliver remains" {
    var h = ExtentHeap.init(BASE, 2 * PAGE);
    const a = h.alloc(PAGE).?;
    try expect(h.freeBlock(a, 1) == null); // freed by the byte count it was asked for
    try expectEqual(BASE, h.alloc(2 * PAGE).?); // rejoined the remainder in full
}

test "a full free list reports the lost block instead of corrupting the list" {
    // Carve the region into single pages, then free every OTHER page: each free
    // is isolated (both neighbours still allocated), so the list grows by one
    // per free until it is full, and the next isolated free is the lost block.
    const cap = ExtentHeap.CAP; // the (cap+1)th isolated extent cannot fit
    var h = ExtentHeap.init(BASE, 2 * (cap + 2) * PAGE);
    var i: u64 = 0;
    while (i < 2 * (cap + 2)) : (i += 1) _ = h.alloc(PAGE).?;

    i = 0;
    while (i < cap) : (i += 1) {
        try expect(h.freeBlock(BASE + 2 * i * PAGE, PAGE) == null);
    }
    try expectEqual(@as(usize, cap), h.n);
    const lost = h.freeBlock(BASE + 2 * cap * PAGE, PAGE).?;
    try expectEqual(BASE + 2 * cap * PAGE, lost.va);
    try expectEqual(PAGE, lost.size);
    try expectEqual(@as(usize, cap), h.n); // the list itself is untouched
}
