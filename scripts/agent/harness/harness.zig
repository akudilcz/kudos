//! Factory build harness for a `.kudos` app. The compile factory writes the
//! agent-generated code to `app.zig` beside this file, copies the repo's
//! `abi.zig` in, and builds this as the root. `_entry` is forced to the front
//! of the image by the linker script (see app.ld) so it sits at byte 0 of the
//! flat blob the loader jumps to. Nothing here reaches outside the image: the
//! app talks to the kernel only through the `Api` pointer it is handed.

const abi = @import("abi.zig");
const app = @import("app.zig");

/// The single exported entry. Placed in `.entry` (first section) and given the C
/// calling convention so the kernel loader can call it by raw address.
export fn _entry(api: *const abi.Api) linksection(".entry") callconv(.c) i32 {
    return app.main(api);
}

// A freestanding image must define its own panic handler; a generated app that
// panics simply reports and returns non-zero rather than pulling in std's
// unwinder. The message is dropped (the app has no std IO); on target the
// containment path (core retire on fault) is the real backstop.
pub const panic = std.debug.FullPanic(struct {
    fn call(_: []const u8, _: ?usize) noreturn {
        while (true) {}
    }
}.call);

const std = @import("std");
