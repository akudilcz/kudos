//! Factory build harness for a `.kudos` feature. Same shape as the app harness
//! but the entry takes a `FeatureApi` and calls the generated `register`, which
//! installs the feature into the running kernel and returns.

const abi = @import("abi.zig");
const app = @import("app.zig");

export fn _entry(api: *const abi.FeatureApi) linksection(".entry") callconv(.c) i32 {
    return app.register(api);
}

pub const panic = std.debug.FullPanic(struct {
    fn call(_: []const u8, _: ?usize) noreturn {
        while (true) {}
    }
}.call);

const std = @import("std");
