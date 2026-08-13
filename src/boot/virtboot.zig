//! Guest boot requests: the service that turns a typed `kudos vm [n]` into a
//! running guest — hosted in the terminal that asked (adoption), or in a fresh
//! window when none did.
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
const lifecycle = @import("../ui/desktop/lifecycle.zig");
const pump = @import("pump.zig");

/// An adoption waiting for its terminal to go idle: the `kudos vm N` that asked
/// is often still inside the command worker when the request is taken. Bounded —
/// past the budget the guest gets its own window rather than never appearing.
var pending_adopt: ?struct { win_id: u32, id: ivirt.Id, tries: u32 } = null;
const ADOPT_TRIES_MAX: u32 = 600; // ~10 s of service steps

/// Serve the pending adoption, if any; true while it is still waiting.
fn serveAdoption() bool {
    const p = &(pending_adopt orelse return false);
    const d = pump.desktop;
    switch (lifecycle.adoptVmWindow(d, p.win_id, p.id)) {
        .done => pending_adopt = null,
        .gone => {
            d.spawnVmWindow(p.id) catch virt.windowClosed(p.id);
            pending_adopt = null;
        },
        .busy => {
            p.tries += 1;
            if (p.tries >= ADOPT_TRIES_MAX) {
                d.spawnVmWindow(p.id) catch virt.windowClosed(p.id);
                pending_adopt = null;
            } else return true;
        },
    }
    return false;
}

/// Give an ADOPTED window whose guest ended its shell back. One per step: the
/// swap edits the app list under this loop's feet.
fn restoreEndedGuests() void {
    const d = pump.desktop;
    for (d.apps.items, 0..) |a, i| {
        if (a != .vm or !a.vm.adopted) continue;
        const st = ivirt.state(a.vm.id);
        if (st != .halted and st != .failed and st != .absent) continue;
        const id = a.vm.id;
        lifecycle.restoreTerminalWindow(d, i);
        virt.windowClosed(id);
        return;
    }
}

/// Perform one pending boot request, then advance any netboot image fetch.
///
/// The staged built-in (image 1) builds synchronously and keeps its own window
/// — it is the scheduling diagnostic the boot suites type at. A catalog image
/// starts an HTTP fetch (a job the same loop pumps) and is ADOPTED by the
/// terminal that asked; its narration lands there from the first serviced
/// step. The guest's vCPU is spawned as an ordinary task placed on whichever
/// core is free (VIRT-021), so no core is named on this path.
pub fn step() void {
    // Windows that closed since the last pass: stop the guest and drop the
    // window's hold on its slot. The app posts the fact through the contract
    // (it must not name the hypervisor); this is where it is acted on.
    while (ivirt.takeWindowClosed()) |id| virt.windowClosed(id);
    if (serveAdoption()) {
        virt.pumpNetboot();
        return; // that boot owns the cell until it has a window
    }
    restoreEndedGuests();
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
            if (req.adopt_win != 0) {
                pending_adopt = .{ .win_id = req.adopt_win, .id = id, .tries = 0 };
                _ = serveAdoption();
            } else d.spawnVmWindow(id) catch |e| {
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
