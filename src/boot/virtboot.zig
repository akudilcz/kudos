//! Guest boot requests: the service that turns a typed `vm boot [n]` into a
//! running guest with a console window.
//!
//! It lives in `boot/` because it is the one step that spans three groups at
//! once — the ivirt request mailbox, the hypervisor, and the desktop's window
//! list — and the apex is the only group allowed to know all three. A terminal
//! posts the request from its own core; the system task (the single owner of
//! windows and VM slots) performs it here.
//!
//! This step used to live inline in `systemLoop` only, which is why a `vm boot`
//! typed on a native GPU boot queued forever: that loop never runs there. It is
//! a row in the service table now, so both steady loops perform it.

const klog = @import("../kernel/debug/klog.zig");
const ivirt = @import("ivirt");
const virt = @import("../kernel/virt/virt.zig");
const pump = @import("pump.zig");

/// Perform one pending boot request, then advance any netboot image fetch.
///
/// The staged built-in (image 1) builds synchronously; a catalog image starts
/// an HTTP fetch — a job the same loop pumps — and its window opens on
/// `.fetching`. The guest's vCPU is spawned as an ordinary task placed on
/// whichever core is free (VIRT-021), so no core is named on this path.
pub fn step() void {
    // Windows that closed since the last pass: stop the guest and drop the
    // window's hold on its slot. The app posts the fact through the contract
    // (it must not name the hypervisor); this is where it is acted on.
    while (ivirt.takeWindowClosed()) |id| virt.windowClosed(id);
    if (ivirt.takeBootRequest()) |req| {
        const d = pump.desktop;
        if (req.image <= 1) {
            d.spawnApp(.vm) catch |e| {
                virt.setStartError(@errorName(e));
                klog.puts("virt: vm boot failed: ");
                klog.puts(@errorName(e));
                klog.puts("\n");
            };
        } else if (virt.netbootBegin(req.image)) |id| {
            d.spawnVmWindow(id) catch |e| {
                virt.windowClosed(id);
                klog.puts("virt: vm image window failed: ");
                klog.puts(@errorName(e));
                klog.puts("\n");
            };
        } else |e| {
            virt.setStartError(@errorName(e));
            klog.puts("virt: vm image boot failed: ");
            klog.puts(@errorName(e));
            klog.puts("\n");
        }
    }
    virt.pumpNetboot();
}
