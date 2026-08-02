//! Host tests of src/drivers/gl/es/gl.zig.

const std = @import("std");
const gl = @import("gl");
const entrypoints = gl.entrypoints;

test "every one of the standard's 145 entry points exists" {
    // This is what makes "spec-complete OpenGL ES 1.1 Common profile" a fact rather than
    // a claim: the list comes from the Khronos reference pages (and agrees exactly with
    // the Khronos header), and a name on it with no decl here is a compile error.
    @setEvalBranchQuota(20000);
    comptime {
        var missing: usize = 0;
        for (entrypoints.ALL) |e| {
            if (!@hasDecl(gl, e.decl)) {
                missing += 1;
                @compileLog(e.gl);
            }
        }
        if (missing != 0) @compileError("gl.zig is missing entry points the standard requires");
    }
    try std.testing.expectEqual(@as(usize, 145), entrypoints.COUNT);
}
