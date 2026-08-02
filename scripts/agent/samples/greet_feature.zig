//! A feature whose registered command produces output — the shape every
//! agent-generated feature must follow.
//!
//! The `FeatureApi` pointer handed to `register` does NOT outlive the call; a
//! callback that kept the pointer would dangle. The rule (taught to the agent
//! in its improve prompt) is: copy the struct BY VALUE into the feature's own
//! image during `register`; callbacks reach the system through the copy. That
//! is a runtime store, so it stays position-independent.

const abi = @import("abi.zig");

var api_copy: abi.FeatureApi = undefined;

fn greet(_: *anyopaque, args: [*]const u8, args_len: usize) callconv(.c) void {
    const msg = "greetings from a hot-loaded feature";
    api_copy.log(api_copy.ctx, msg.ptr, msg.len);
    if (args_len > 0) {
        const sep = ", ";
        api_copy.log(api_copy.ctx, sep.ptr, sep.len);
        api_copy.log(api_copy.ctx, args, args_len);
    }
    const nl = "\n";
    api_copy.log(api_copy.ctx, nl.ptr, nl.len);
}

pub fn register(api: *const abi.FeatureApi) i32 {
    api_copy = api.*;
    const name = "greet";
    if (!api.register_command(api.ctx, name.ptr, name.len, greet)) return 1;
    const msg = "greet feature ready\n";
    api.log(api.ctx, msg.ptr, msg.len);
    return 0;
}
