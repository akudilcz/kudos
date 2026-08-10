//! The interface layer compiles under the host build (ARCH-003). Every
//! contract in src/iface/ is imported here by module name, so a contract only
//! the kernel toolchain can compile fails this suite's BUILD — the compile is
//! the assertion; the test declaration below only makes the suite runnable.
//! The kernel half of the guarantee is the kernel image itself: the same
//! modules are wired into both kernel variants. Completeness — no src/iface
//! file missing from this sweep — is enforced by scripts/tests/layering.sh.

comptime {
    _ = @import("iaccel");
    _ = @import("iblockdev");
    _ = @import("idevices");
    _ = @import("idisplay");
    _ = @import("idraw");
    _ = @import("idesk");
    _ = @import("ifilesys");
    _ = @import("ilog");
    _ = @import("imouse");
    _ = @import("inet");
    _ = @import("ipci");
    _ = @import("ipresent");
    _ = @import("iramdisk");
    _ = @import("ivirt");
    _ = @import("iwindow");
}

const std = @import("std");

test "every interface contract compiles and declares a contract (ARCH-003)" {
    // The COMPILE above is the real assertion — a contract only the kernel
    // toolchain can build fails this suite before any test runs. This body adds
    // the one thing the compile cannot catch: a contract that still compiles
    // because it has been emptied. A seam with no declarations is not a narrow
    // interface, it is a file, and every implementation of it would still pass.
    //
    // It also stops this test being an empty body, which reads as coverage in
    // every listing and can never fail. `reqtrace.sh` now refuses that shape.
    inline for (.{
        @import("iaccel"),    @import("iblockdev"), @import("idevices"),
        @import("idesk"),     @import("idisplay"),  @import("idraw"),
        @import("ifilesys"),
        @import("ilog"),      @import("imouse"),    @import("inet"),
        @import("ipci"),      @import("ipresent"),  @import("iramdisk"),
        @import("ivirt"),     @import("iwindow"),
    }) |contract| {
        try std.testing.expect(@typeInfo(contract).@"struct".decls.len > 0);
    }
}
