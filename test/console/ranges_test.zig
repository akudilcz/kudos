//! Host tests of src/console/ranges.zig — the `N,M-K` list `cut` takes. The
//! property under test is that a position is selected by exactly the parts that
//! name it, and that a malformed list is REFUSED rather than read as a subset:
//! a `cut -f 3-1` that quietly selected nothing would look like an empty file.

const std = @import("std");
const ranges = @import("ranges");
const expect = std.testing.expect;

test "a single position selects only itself" {
    const l = ranges.List{ .spec = "3" };
    try expect(!l.selects(2));
    try expect(l.selects(3));
    try expect(!l.selects(4));
}

test "a closed range selects its ends and everything between" {
    const l = ranges.List{ .spec = "2-4" };
    try expect(!l.selects(1));
    try expect(l.selects(2));
    try expect(l.selects(3));
    try expect(l.selects(4));
    try expect(!l.selects(5));
}

test "an open range runs to the start or to the end" {
    const from = ranges.List{ .spec = "3-" };
    try expect(!from.selects(2));
    try expect(from.selects(3));
    try expect(from.selects(10_000));

    const to = ranges.List{ .spec = "-3" };
    try expect(to.selects(1));
    try expect(to.selects(3));
    try expect(!to.selects(4));
}

test "a comma list selects the union of its parts" {
    const l = ranges.List{ .spec = "1,4-5" };
    try expect(l.selects(1));
    try expect(!l.selects(2));
    try expect(!l.selects(3));
    try expect(l.selects(4));
    try expect(l.selects(5));
}

test "position zero is never selected" {
    // Fields are 1-based; a 0 must not be read as "the first", which would
    // shift every column of the output by one.
    try expect(!(ranges.List{ .spec = "0" }).selects(0));
    try expect(!(ranges.List{ .spec = "1-3" }).selects(0));
}

test "valid accepts the list grammar and refuses the rest" {
    try expect(ranges.valid("1"));
    try expect(ranges.valid("1,3-5,7-"));
    try expect(ranges.valid("-2"));
    try expect(!ranges.valid("")); // no list at all
    try expect(!ranges.valid("a")); // not a number
    try expect(!ranges.valid("5-2")); // reversed: a typo, not an empty range
    try expect(!ranges.valid("-")); // neither end named
    try expect(!ranges.valid("1,,2")); // an empty part
}
