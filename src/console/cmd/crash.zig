//! `crash` — deliberately panic on THIS core (test-hooks builds only): the
//! fault-containment regression trigger (KRN-006/AGT-009). On an application core
//! the panic parks the core and the desktop closes its window; the machine
//! survives. Never compiled into a shipping image.

const Out = @import("../out.zig").Out;

/// `crash` — panic the calling core, on purpose.
pub fn run(out: Out, args: []const u8) void {
    _ = args;
    out.str("crash: panicking this core (fault-containment test)\n");
    @panic("deliberate crash command (test-hooks)");
}
