//! `vm` — inspect and control the guest virtual machines.
//!
//!   vm            — subsystem status and a line per live guest
//!   vm list       — the bootable images, numbered
//!   vm <n>        — boot image <n> and open its console window
//!   vm stop <id>  — ask the guest in slot <id> to stop
//!
//! The image numbers and the guest slot ids are different namespaces: `vm 1`
//! boots the first IMAGE, while `vm stop 1` stops the guest in the second SLOT.
//! Images are numbered from 1 because slots are numbered from 0 — the same
//! number never means both things.
//!
//! One guest image is embedded into the kernel at build time — `-Dguest=<name>`
//! picks which (the default is the busybox serial console; the list names it).
//! `vm boot` opens a VM window, which is what boots a guest and binds it to that
//! window — so the dock tile and this command take the same path. Several guests
//! run at once, each on its own core with its own window.
//!
//! Closing a window is the ordinary way to shut a guest down and get its memory
//! and its core back. `vm stop` is the scriptable equivalent for the guest alone:
//! the window stays open showing the halted console until it too is closed.

const std = @import("std");
const console = @import("../console.zig");
const virt = @import("../../kernel/virt/virt.zig");
const ivirt = @import("ivirt");

/// Upper bound on guests a single `vm` listing prints — the subsystem's own
/// capacity, so a full machine is always shown in full.
const MAX_LISTED = 8;

/// `vm [<n>|list|status|stop <id>]` — report or control the guest VMs.
/// `vm list` numbers the bootable images (VIRT-020); `vm <n>` boots entry n —
/// 1 is the staged built-in, 2.. fetch over the network (VIRT-019). `boot` is
/// accepted before the number as the long way of saying the same thing.
pub fn run(c: console.Console, args: []const u8) void {
    const cmd = std.mem.trim(u8, args, " \t");
    if (cmd.len == 0 or std.mem.eql(u8, cmd, "status")) {
        printStatus(c);
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "boot")) {
        writeList(c);
    } else if (std.mem.startsWith(u8, cmd, "boot")) {
        bootNumber(c, std.mem.trim(u8, cmd["boot".len..], " \t"));
    } else if (std.mem.startsWith(u8, cmd, "stop")) {
        stop(c, std.mem.trim(u8, cmd["stop".len..], " \t"));
    } else if (isNumber(cmd)) {
        bootNumber(c, cmd);
    } else {
        c.write("usage: kudos vm [<n>|list|status|stop <id>]   (`kudos vm list` numbers the images)\n");
    }
}

/// Whether `s` is a bare image number, so an unrecognised word gets the usage
/// line rather than a complaint about a number the user never typed.
fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// The bootable-image list (VIRT-020), over any sink with `write` — shared
/// with the SMP local variant. Entry 1 is the staged built-in; the rest are
/// the network catalog (virt.images).
pub fn writeList(w: anytype) void {
    w.write("bootable guest images (`vm <n>` boots one):\n");
    var buf: [200]u8 = undefined;
    const first = std.fmt.bufPrint(&buf, "   1  {s} (staged in this image, boots from RAM){s}\n", .{
        virt.stagedName(),
        if (virt.guestStaged()) "" else "  [NOT STAGED]",
    }) catch return;
    w.write(first);
    for (virt.images.CATALOG, 2..) |img, n| {
        // A baked guest costs no download and no network at all, which is the
        // one thing worth knowing before choosing a 256 MB entry.
        const row = if (virt.guestBaked(img.id))
            std.fmt.bufPrint(&buf, "  {d: >2}  {s}  (in this image, {d} MB RAM)\n", .{
                n, img.name, img.ram_mb,
            }) catch continue
        else
            std.fmt.bufPrint(&buf, "  {d: >2}  {s}  (~{d} MB fetch, {d} MB RAM)\n", .{
                n, img.name, img.approx_mb, img.ram_mb,
            }) catch continue;
        w.write(row);
    }
}

/// `vm <n>`: entry 1 boots the built-in synchronously; a catalog entry
/// posts the request to core 0, which fetches the image without blocking
/// anything — its window opens on `fetching` and narrates from there.
fn bootNumber(c: console.Console, arg: []const u8) void {
    const n = std.fmt.parseInt(u8, arg, 10) catch {
        c.write("vm: that is not an image number (see `vm list`)\n");
        return;
    };
    if (n == 1) return boot(c);
    if (virt.images.byNumber(n) == null) {
        c.write("vm: no such image (see `vm list`)\n");
        return;
    }
    if (!ivirt.postBootRequest(n, c.win_id)) {
        c.write("vm: another boot is already in flight — retry in a moment\n");
        return;
    }
    c.write("vm: fetching the image over HTTP — its window opens now and narrates\n");
}

/// Open a VM window, which boots the guest and binds it to that window. Every
/// failure is reported here — a boot that cannot start says why rather than
/// leaving an empty window or hanging.
fn boot(c: console.Console) void {
    c.spawnApp(.vm) catch |err| {
        switch (err) {
            error.NotStaged => c.write("vm: no guest image staged in this build\n"),
            error.NotAvailable => c.write("vm: VT-x not available on this CPU\n"),
            error.StartFailed => {
                c.write("vm: VT-x is present but the guest would not start: ");
                c.write(virt.lastStartError());
                c.put('\n');
                const detail = virt.lastStartDetail();
                if (detail.len != 0) {
                    c.write("  ");
                    c.write(detail);
                    c.put('\n');
                }
            },
            error.NoVmSlot => c.write("vm: all VM slots are in use (close a VM window first)\n"),
            error.GuestRamExhausted => c.write("vm: not enough free RAM for the guest (close a VM first)\n"),
            else => {
                c.write("vm: boot failed: ");
                c.write(@errorName(err));
                c.put('\n');
            },
        }
        return;
    };
    c.write("vm: booting a guest (see its window)\n");
}

/// `vm stop <id>` — ask one guest to stop. It halts at its next VM exit and its
/// own core reclaims its memory; its window stays open on the halted console.
fn stop(c: console.Console, arg: []const u8) void {
    writeStop(c, arg);
}

fn printStatus(c: console.Console) void {
    writeStatus(c);
}

/// The `vm stop` body over any sink with `write([]const u8)`.
pub fn writeStop(w: anytype, arg: []const u8) void {
    if (arg.len == 0) {
        w.write("usage: kudos vm stop <id>   (see `kudos vm` for the slot ids)\n");
        return;
    }
    const id = std.fmt.parseInt(usize, arg, 10) catch {
        w.write("vm: stop needs a numeric VM id\n");
        return;
    };
    if (!virt.stoppable(id)) {
        w.write("vm: no running guest with that id\n");
        return;
    }
    virt.requestStop(id);
    w.write("vm: stop requested\n");
}

/// The `vm status` body over any sink with `write([]const u8)`.
pub fn writeStatus(w: anytype) void {
    const s = virt.status();
    if (!s.available) {
        w.write("vm: VT-x not available on this CPU\n");
        return;
    }
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "vm: VT-x present | EPT 2MiB={s} 1GiB={s} | guests {d}/{d}\n", .{
        yn(s.ept_2m),
        yn(s.ept_1g),
        s.in_use,
        s.capacity,
    }) catch return;
    w.write(line);

    var guests: [MAX_LISTED]virt.GuestInfo = undefined;
    const n = virt.snapshot(&guests);
    if (n == 0) {
        w.write("  (no guests; `vm boot` starts one)\n");
        return;
    }
    for (guests[0..n]) |g| {
        // A guest that has not started yet has no core: its vCPU task has been
        // placed but has not bound itself. Say so rather than naming core 0,
        // which is an ordinary core like any other (ARCH-016).
        // `serial` is total guest console bytes (drops in parentheses when any):
        // a "running" guest with exits 0 or serial 0 never actually executed —
        // the tell that separates a dead guest from a quiet one.
        var drop_buf: [48]u8 = undefined;
        const row = if (g.core) |c|
            std.fmt.bufPrint(&buf, "  vm {d}  core {d}  {s}{s}  exits {d}  serial {d}{s}\n", .{
                g.id,       c,      @tagName(g.state), if (g.stopping) " (stopping)" else "",
                g.exits,    ivirt.writtenTx(g.id),     dropNote(&drop_buf, g.id),
            }) catch continue
        else
            std.fmt.bufPrint(&buf, "  vm {d}  core -   {s}{s}  exits {d}  serial {d}{s}\n", .{
                g.id,       @tagName(g.state),         if (g.stopping) " (stopping)" else "",
                g.exits,    ivirt.writtenTx(g.id),     dropNote(&drop_buf, g.id),
            }) catch continue;
        w.write(row);
    }
}

fn yn(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

/// The status row's drop note: empty while nothing has been lost, else the
/// counts — console bytes the window failed to drain (tx) and keystrokes the
/// guest failed to read (rx). Losses are never silent (ivirt counts them);
/// this is where they surface.
fn dropNote(buf: []u8, id: ivirt.Id) []const u8 {
    const tx = ivirt.droppedTx(id);
    const rx = ivirt.droppedRx(id);
    if (tx == 0 and rx == 0) return "";
    return std.fmt.bufPrint(buf, " (dropped tx {d} rx {d})", .{ tx, rx }) catch "";
}
