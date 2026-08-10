//! The guest-image catalog: every Linux a `vm boot <n>` can put in a VM window
//! (spec VIRT-019/VIRT-020). Entry 1 is always the built-in busybox guest
//! staged into the kernel image (gueststage.zig); the entries here are 2..N,
//! fetched over plain HTTP into guest RAM at boot time: an entry's whole root
//! arrives as an initramfs (VIRT-004), not on the disk it also has (VIRT-037),
//! because a fetched pair is a kernel and a filesystem and nothing has yet put
//! anything on that disk.
//!
//! Pure data + index math, host-tested. URLs are plain HTTP because the
//! background fetch path (inet.fetchBackground) does not speak TLS yet; every
//! URL here answered 200 with the listed size when the entry was added — a
//! moved mirror fails the fetch loudly, and the fix is this table.
//!
//! Every entry is an image this repo builds (scripts/virt/build_guest.sh) and
//! serves (scripts/virt/serve_guest.sh), so the sizes below are what a build
//! produced rather than what a mirror advertises.

/// One bootable network image: both halves of a Linux netboot pair, the RAM
/// its userland needs, and what to tell the user while ~`approx_mb` downloads.
pub const Image = struct {
    /// Short name shown by `vm boot` and used as the window title.
    name: []const u8,
    /// What builds this image and where it is served from: the
    /// `scripts/virt/build_guest.sh <id>` subcommand, which is also the
    /// directory segment in both URLs below and the name a build stages it
    /// under (`-Dbake=<id>`). One word, three uses, so a guest that is built,
    /// served and baked cannot be three slightly different things.
    id: []const u8,
    /// The bzImage half (VIRT-003 boots it via the Linux/x86 64-bit protocol).
    kernel_url: []const u8,
    /// The initramfs half — the guest's entire root filesystem (VIRT-004).
    initramfs_url: []const u8,
    /// Guest RAM. Netboot installers unpack their initrd into a tmpfs and
    /// need several times its compressed size.
    ram_mb: u32,
    /// Rough total download, for the listing (the fetch reports exact bytes).
    approx_mb: u32,
    /// The kernel command line. Serial (ttyS0) is named LAST so it stays
    /// /dev/console for the guest's shell/installer UI — that is the console
    /// mirrored into the VM window; tty0 (the virtio-gpu scanout, VIRT-013)
    /// shows whatever the guest's framebuffer console renders.
    cmdline: []const u8,
};

const layout = @import("layout.zig");

/// The virtio devices a catalog guest is wired to, as the discovery arguments
/// the guest needs to find them: there is no PCI bus and no device tree in a
/// kudos guest, so a device nobody names is a device nobody sees. The list has
/// one home (layout.WIRED_DEVICES), shared with the staged guest's command line.
const DEVICES = layout.WIRED_DEVICES ++ " " ++ layout.NO_IOAPIC;

/// VM-exit dieting, appended to every catalog cmdline: each flag stops the
/// guest banging on a device we emulate one trap at a time. Under a NESTED
/// hypervisor an exit costs ~10x bare metal, so probe storms dominate boot.
///  - no_timer_check: skip the PIT/IOAPIC cross-check against our virtual wire
///  - tsc=reliable:   drop the clocksource watchdog's periodic cross-timer reads
///  - i8042.*:        stop probing the PS/2 controller we do not emulate
///  - mitigations=off: sidechannel mitigations amplify exit cost; it's a lab
///  - nokaslr:         a hung guest's RIP then maps straight to its vmlinux —
///                     the progress trace is only diagnosable with stable text
///  - earlyprintk:     a panic BEFORE console_init still reaches ttyS0 — the
///                     difference between a silent guest and one that names
///                     its own boot failure in the VM window
const EXIT_DIET = "no_timer_check tsc=reliable i8042.noaux i8042.nomux i8042.dumbkbd mitigations=off nokaslr earlyprintk=serial,ttyS0,115200";

/// The catalog: the four guests kudos boots, in list order (entry 1 is the
/// staged built-in busybox guest, which lives in gueststage.zig, not here).
/// Each is BUILT BY THIS REPO — `scripts/virt/build_guest.sh <image>` — and
/// served by `scripts/virt/serve_guest.sh`, so an entry answers only while the
/// operator's server runs. That is the trade the list is deliberately making:
/// a public mirror is always up and gives a guest nobody here designed, while
/// these are built for this hypervisor and each does a job.
///
/// EVERY ENTRY MUST REACH A USERSPACE THE USER CAN DO SOMETHING WITH. That rules
/// out a whole class of otherwise obvious images: a kudos guest gets a serial
/// console, a virtio-gpu scanout, a virtio-net card whose frames reach the wire
/// through the bridge (VIRT-027), and a blank disk (VIRT-037) — so an initramfs
/// that is only a first stage still has nowhere to fetch its second stage from:
/// the disk exists but nothing has installed anything onto it. Alpine's own netboot pair is the example worth remembering: its kernel
/// boots perfectly and its init runs, then stops at "Mounting boot media:
/// failed" because the system lives in a squashfs it expects to find on a disk
/// or a mirror. Nothing in the hypervisor can fix that, and shipping it would be
/// shipping a broken menu entry. In every entry here the initramfs IS the
/// system, which is why the RAM figures are large: the guest holds its whole
/// root filesystem in tmpfs before its userland allocates a byte.
///
/// The host address is 10.0.2.2, QEMU slirp's address for the machine kudos
/// runs on — right whenever kudos itself runs under QEMU on the machine that
/// serves the images. kudos on real hardware (lemon) needs the serving
/// machine's LAN address here instead: edit, rebuild, reflash.
pub const CATALOG = [_]Image{
    .{
        // The browser. There is no virgl and no GPU in the guest, so Mesa falls
        // back to llvmpipe and the Wayland kiosk puts every CPU-drawn frame in a
        // virtio-gpu resource kudos textures into the VM window. Its RAM is the
        // one figure measured rather than guessed: the initramfs unpacks to
        // ~720 MiB of root filesystem in tmpfs, and Firefox's own working set
        // with a page loaded is about the same again.
        .name = "Linux + Firefox (Wayland kiosk on llvmpipe, runs from RAM)",
        .id = "firefox",
        .kernel_url = "http://10.0.2.2:8000/firefox/bzImage",
        .initramfs_url = "http://10.0.2.2:8000/firefox/initramfs.cpio.gz",
        .ram_mb = 3072,
        .approx_mb = 353,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        // The compiler kudos does not carry (ARCH-012). This guest runs the same
        // scripts/agent/factory.py the host runs, on the same pinned Zig, and
        // compiles agent-written source into a .kudos app THIS kernel loads and
        // runs — so the write-compile-run loop closes inside one machine with no
        // host in it. It prints the address to point AI.CFG's `factory=` at as
        // soon as its lease lands.
        .name = "Linux + zig compiler server (kudos .kudos factory on :8623)",
        .id = "zigserver",
        .kernel_url = "http://10.0.2.2:8000/zigserver/bzImage",
        .initramfs_url = "http://10.0.2.2:8000/zigserver/initramfs.cpio.gz",
        .ram_mb = 3072,
        .approx_mb = 176,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        // A stock Ubuntu server userland with apt, for the times the answer is
        // "install it and see". Nothing persists a reboot and every install
        // lands in RAM, which is the whole character of this entry.
        .name = "Ubuntu Server (minimal, runs from RAM)",
        .id = "ubuntu",
        .kernel_url = "http://10.0.2.2:8000/ubuntu/bzImage",
        .initramfs_url = "http://10.0.2.2:8000/ubuntu/initramfs.cpio.gz",
        .ram_mb = 2048,
        .approx_mb = 169,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        // The same Ubuntu userland with a graphical session on it: XFCE on Xorg,
        // software-rendered, painting into the guest's virtio-gpu scanout, with
        // a terminal, a file manager and Chrome.
        //
        // The RAM figure is the one to read twice. The tree unpacks to ~1 GiB
        // and lives in tmpfs before a single application starts, so a third of
        // this is spent before the desktop appears and the rest is the whole
        // budget a browser has to work in. It is also the largest thing the
        // fetch path carries: the response is reserved whole and contiguously
        // (tcp.reserveRecv), which is why the kernel arena is a gigabyte
        // (kernel/memory/heap.zig) rather than the half it used to be.
        .name = "Ubuntu desktop (XFCE on Xorg, software-rendered, runs from RAM)",
        .id = "desktop",
        .kernel_url = "http://10.0.2.2:8000/desktop/bzImage",
        .initramfs_url = "http://10.0.2.2:8000/desktop/initramfs.cpio.gz",
        .ram_mb = 4000,
        .approx_mb = 481,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
};

/// How many entries `vm boot` lists: the staged built-in plus this catalog.
pub const COUNT: usize = 1 + CATALOG.len;

/// The catalog image behind list number `n` (1-based, as `vm boot <n>` takes
/// it), or null for n == 1 (the staged built-in) and for numbers off the list.
pub fn byNumber(n: usize) ?*const Image {
    if (n < 2 or n > COUNT) return null;
    return &CATALOG[n - 2];
}
