//! Host tests of the calculator's visible ledger (src/apps/calchistory.zig):
//! the home screen's history of evaluated expressions — order, the scroll that
//! keeps it a moving window over the session, and row-width truncation.

const std = @import("std");
const calchistory = @import("calchistory");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "evaluated lines appear in order, newest last (APP-017)" {
    var h = calchistory.History{};
    h.push("1+1 = 2");
    h.push("2*3 = 6");
    try expectEqual(2, h.count);
    try expectEqualStrings("1+1 = 2", h.row(0));
    try expectEqualStrings("2*3 = 6", h.row(1));
}

test "a full ledger scrolls: the OLDEST line leaves, the newest always lands (APP-017)" {
    var h = calchistory.History{};
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < calchistory.ROWS + 3) : (i += 1) {
        h.push(std.fmt.bufPrint(&buf, "line {d}", .{i}) catch unreachable);
    }
    try expectEqual(calchistory.ROWS, h.count);
    // The window shows the LAST ROWS lines: 3 .. ROWS+2.
    try expectEqualStrings("line 3", h.row(0));
    var last: [16]u8 = undefined;
    try expectEqualStrings(
        std.fmt.bufPrint(&last, "line {d}", .{calchistory.ROWS + 2}) catch unreachable,
        h.row(calchistory.ROWS - 1),
    );
}

test "an over-long line truncates to the row width, never overruns" {
    var h = calchistory.History{};
    const long = [_]u8{'x'} ** (calchistory.CAP + 40);
    h.push(&long);
    try expectEqual(calchistory.CAP, h.row(0).len);
}
