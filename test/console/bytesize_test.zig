//! Host tests of src/console/bytesize.zig — the `-h` size wording.

const std = @import("std");
const bytesize = @import("bytesize");
const expectEqualStrings = std.testing.expectEqualStrings;

test "bytes below 1K print bare" {
    var b: [bytesize.MAX_TEXT]u8 = undefined;
    try expectEqualStrings("0", bytesize.human(0, &b));
    try expectEqualStrings("1023", bytesize.human(1023, &b));
}

test "one decimal under ten units, whole above" {
    var b: [bytesize.MAX_TEXT]u8 = undefined;
    try expectEqualStrings("1.0K", bytesize.human(1024, &b));
    try expectEqualStrings("1.5K", bytesize.human(1536, &b));
    try expectEqualStrings("9.9M", bytesize.human(10 * 1024 * 1024 - 60000, &b));
    try expectEqualStrings("445K", bytesize.human(456024, &b));
    try expectEqualStrings("16G", bytesize.human(16 << 30, &b));
}
