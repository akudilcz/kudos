//! A minimal hand-written .kudos app used to test the factory, loader, and
//! runner without involving the LLM. It prints a line and returns 0.

const abi = @import("abi.zig");

fn say(api: *const abi.Api, s: []const u8) void {
    api.print(api.ctx, s.ptr, s.len);
}

pub fn main(api: *const abi.Api) i32 {
    say(api, "hello from a .kudos app\n");
    return 0;
}
