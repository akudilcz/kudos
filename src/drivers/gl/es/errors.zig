//! The error flag — GL's whole error-reporting mechanism.
//!
//! OpenGL commands do not return errors. A command that is given something illegal
//! records an error code and otherwise **does nothing**: no state changes, no partial
//! effect, no draw. The application finds out by calling `glGetError`, whenever it
//! feels like it, if ever. This is not an oversight — it is what lets a program issue
//! thousands of commands without a branch after each one.
//!
//! The standard's rule (§2.5) has one detail that is easy to get backwards: the FIRST
//! error sticks. "When an error is detected, a flag is set and the code is recorded.
//! Further errors, if they occur, do not affect this recorded code." So a later,
//! possibly more interesting error is *dropped* while one is already pending. Reading
//! the flag clears it, and the next error is recorded again.
//!
//! The standard allows several flag-code pairs so that a distributed implementation can
//! collect errors from several places. kudos is one machine and one thread of GL work,
//! so it keeps one pair, which the standard explicitly permits ("some positive number
//! of pairs").
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.5, table 2.3.

const std = @import("std");
pub const enums = @import("enums.zig");

pub const GLenum = enums.GLenum;

/// Every error the standard defines (table 2.3). Nothing else may be recorded.
pub const Error = enum(GLenum) {
    /// An enumerated argument was not one this command accepts.
    invalid_enum = enums.GL_INVALID_ENUM,
    /// A numeric argument was out of range.
    invalid_value = enums.GL_INVALID_VALUE,
    /// The command is not legal in the current state.
    invalid_operation = enums.GL_INVALID_OPERATION,
    /// A push would exceed the stack's depth.
    stack_overflow = enums.GL_STACK_OVERFLOW,
    /// A pop would empty a stack that has only its bottom entry left.
    stack_underflow = enums.GL_STACK_UNDERFLOW,
    /// There was not enough memory to execute the command. The only error after which
    /// the standard says the results of GL operation are undefined.
    out_of_memory = enums.GL_OUT_OF_MEMORY,
};

/// One flag-code pair.
pub const Flag = struct {
    code: ?Error = null,

    /// Record an error, unless one is already pending — in which case the standard says
    /// this one is dropped.
    pub fn record(self: *Flag, e: Error) void {
        if (self.code == null) self.code = e;
    }

    /// glGetError: return the pending code and clear the flag.
    pub fn get(self: *Flag) GLenum {
        const c = self.code orelse return enums.GL_NO_ERROR;
        self.code = null;
        return @intFromEnum(c);
    }

    /// Is an error pending? For tests and for the layer's own assertions — an
    /// application cannot ask this without consuming it.
    pub fn pending(self: Flag) ?Error {
        return self.code;
    }
};
