//! A minimal hand-written .kudos FEATURE, used to test the feature build path
//! (kind = feature, entry `register`). It registers a shell command and logs.

const abi = @import("abi.zig");

fn cmd(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}

pub fn register(api: *const abi.FeatureApi) i32 {
    const name = "hello";
    _ = api.register_command(api.ctx, name.ptr, name.len, cmd);
    const msg = "hello feature registered\n";
    api.log(api.ctx, msg.ptr, msg.len);
    return 0;
}
