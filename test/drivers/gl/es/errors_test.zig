//! Host tests of src/drivers/gl/es/errors.zig.

const std = @import("std");
const errors = @import("errors");
const Error = errors.Error;
const Flag = errors.Flag;
const GLenum = errors.GLenum;
const enums = errors.enums;
const expectEqual = std.testing.expectEqual;

test "a fresh flag reports no error" {
    var f = Flag{};
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), f.get());
}

test "the FIRST error sticks and later ones are dropped — the standard's rule" {
    var f = Flag{};
    f.record(.invalid_enum);
    f.record(.invalid_value); // dropped: a code is already recorded
    f.record(.out_of_memory); // also dropped
    try expectEqual(@as(GLenum, enums.GL_INVALID_ENUM), f.get());
    // Cleared by the read, so the next error records again.
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), f.get());
    f.record(.invalid_value);
    try expectEqual(@as(GLenum, enums.GL_INVALID_VALUE), f.get());
}

test "reading clears, so a second read reports no error" {
    var f = Flag{};
    f.record(.stack_overflow);
    try expectEqual(@as(GLenum, enums.GL_STACK_OVERFLOW), f.get());
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), f.get());
    try expectEqual(@as(GLenum, enums.GL_NO_ERROR), f.get());
}

test "every code is the value the registry assigns it" {
    // A wrong number here is invisible until an application compares against its own
    // header and disagrees with us.
    try expectEqual(@as(GLenum, 0x0500), @intFromEnum(Error.invalid_enum));
    try expectEqual(@as(GLenum, 0x0501), @intFromEnum(Error.invalid_value));
    try expectEqual(@as(GLenum, 0x0502), @intFromEnum(Error.invalid_operation));
    try expectEqual(@as(GLenum, 0x0503), @intFromEnum(Error.stack_overflow));
    try expectEqual(@as(GLenum, 0x0504), @intFromEnum(Error.stack_underflow));
    try expectEqual(@as(GLenum, 0x0505), @intFromEnum(Error.out_of_memory));
    try expectEqual(@as(GLenum, 0), enums.GL_NO_ERROR);
}

test "pending observes without consuming" {
    var f = Flag{};
    try expectEqual(@as(?Error, null), f.pending());
    f.record(.invalid_operation);
    try expectEqual(@as(?Error, .invalid_operation), f.pending());
    try expectEqual(@as(?Error, .invalid_operation), f.pending()); // still there
    _ = f.get();
    try expectEqual(@as(?Error, null), f.pending());
}
