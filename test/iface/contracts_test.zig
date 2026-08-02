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

test "every interface contract compiles under the host build (ARCH-003; contract-only modules, ARCH-002)" {}
