//! A hand-written .kudos app that deliberately faults, used ONLY to test
//! on-target containment (a fault retires the app's core and closes its window,
//! spec AGT-009 / KRN-006). It compiles to a valid .kudos; it is never executed
//! on the host — the host has no per-core containment, so running it there
//! would simply crash the driver.

const abi = @import("abi.zig");

pub fn main(api: *const abi.Api) i32 {
    _ = api;
    // A wild write to an unmapped (but canonical, non-zero) address: it compiles
    // cleanly and faults at run time, which on target retires the app's core.
    const p: *volatile u8 = @ptrFromInt(0x0000_dead_0000);
    p.* = 1;
    return 0;
}
