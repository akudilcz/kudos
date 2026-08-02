//! The guest-image catalog: every Linux a `vm boot <n>` can put in a VM window
//! (spec VIRT-019/VIRT-020). Entry 1 is always the built-in busybox guest
//! staged into the kernel image (gueststage.zig); the entries here are 2..N,
//! fetched over plain HTTP into guest RAM at boot time — the guest still sees
//! no storage device (VIRT-004), its whole root arrives as an initramfs.
//!
//! Pure data + index math, host-tested. URLs are plain HTTP because the
//! background fetch path (inet.fetchBackground) does not speak TLS yet; every
//! URL here answered 200 with the listed size when the entry was added — a
//! moved mirror fails the fetch loudly, and the fix is this table.

/// One bootable network image: both halves of a Linux netboot pair, the RAM
/// its userland needs, and what to tell the user while ~`approx_mb` downloads.
pub const Image = struct {
    /// Short name shown by `vm boot` and used as the window title.
    name: []const u8,
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
/// kudos guest, so a device nobody names is a device nobody sees. Same
/// generator the staged guest's command line uses (virt.STAGED_CMDLINE), so
/// "which slots are wired" keeps one home.
const DEVICES = layout.cmdlineArg(.gpu) ++ " " ++ layout.cmdlineArg(.net);

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

/// Entries 2..N of the catalog (entry 1 is the staged built-in, which lives in
/// gueststage.zig, not here). Ordered smallest download first; every URL must
/// answer 200 with the listed size. The one exception to both
/// rules is the last entry, the locally served lab image: its URL answers only
/// while the operator's HTTP server runs, and it sits last regardless of size
/// so the always-on mirror entries keep stable numbers.
///
/// EVERY ENTRY MUST REACH A USERSPACE THE USER CAN DO SOMETHING WITH. That rules
/// out a whole class of otherwise obvious images: a kudos guest gets a serial
/// console, a virtio-gpu scanout, and a virtio-net card whose frames reach no
/// wire until a bridge connects — and no disk at all (VIRT-004) — so an
/// initramfs that is only a first stage has nowhere to fetch its second stage
/// from. Alpine's netboot pair is the example worth remembering:
/// its kernel boots perfectly and its init runs, then stops at "Mounting boot
/// media: failed" because the system itself lives in a squashfs the initramfs
/// expects to find on a disk or a mirror. Nothing in the hypervisor can fix that,
/// and shipping it would be shipping a broken menu entry.
///
/// What is left divides in two, and the names say which is which:
///   - "runs from RAM": the initramfs IS the system. A shell, and a usable one.
///   - "installer": the initramfs is a complete installer, which comes up and is
///     interactive. It cannot complete an install with no disk and no network,
///     but reaching its menus exercises a real distribution kernel end to end.
pub const CATALOG = [_]Image{
    .{
        .name = "TinyCore 14 (x86_64 shell, runs from RAM)",
        .kernel_url = "http://tinycorelinux.net/14.x/x86_64/release/distribution_files/vmlinuz64",
        .initramfs_url = "http://tinycorelinux.net/14.x/x86_64/release/distribution_files/corepure64.gz",
        .ram_mb = 512,
        .approx_mb = 19,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        .name = "TinyCore 15 (x86_64 shell, runs from RAM)",
        .kernel_url = "http://tinycorelinux.net/15.x/x86_64/release/distribution_files/vmlinuz64",
        .initramfs_url = "http://tinycorelinux.net/15.x/x86_64/release/distribution_files/corepure64.gz",
        .ram_mb = 512,
        .approx_mb = 20,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        .name = "TinyCore 16 (x86_64 shell, runs from RAM)",
        .kernel_url = "http://tinycorelinux.net/16.x/x86_64/release/distribution_files/vmlinuz64",
        .initramfs_url = "http://tinycorelinux.net/16.x/x86_64/release/distribution_files/corepure64.gz",
        .ram_mb = 768,
        .approx_mb = 23,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        .name = "Debian 10 installer (Linux 4.19)",
        .kernel_url = "http://archive.debian.org/debian/dists/buster/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux",
        .initramfs_url = "http://archive.debian.org/debian/dists/buster/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz",
        .ram_mb = 768,
        .approx_mb = 35,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        .name = "Debian 11 installer (Linux 5.10)",
        .kernel_url = "http://deb.debian.org/debian/dists/bullseye/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux",
        .initramfs_url = "http://deb.debian.org/debian/dists/bullseye/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz",
        .ram_mb = 768,
        .approx_mb = 36,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        .name = "Debian 12 installer (Linux 6.1)",
        .kernel_url = "http://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux",
        .initramfs_url = "http://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz",
        .ram_mb = 1024,
        .approx_mb = 49,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        .name = "Ubuntu 18.04 installer (Linux 4.15)",
        .kernel_url = "http://archive.ubuntu.com/ubuntu/dists/bionic/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64/linux",
        .initramfs_url = "http://archive.ubuntu.com/ubuntu/dists/bionic/main/installer-amd64/current/images/netboot/ubuntu-installer/amd64/initrd.gz",
        .ram_mb = 1024,
        .approx_mb = 52,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        .name = "Ubuntu 20.04 installer (Linux 5.4)",
        .kernel_url = "http://archive.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64/linux",
        .initramfs_url = "http://archive.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64/initrd.gz",
        .ram_mb = 1024,
        .approx_mb = 64,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    .{
        .name = "Debian 13 installer (Linux 6.12)",
        .kernel_url = "http://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux",
        .initramfs_url = "http://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz",
        .ram_mb = 1536,
        .approx_mb = 51,
        .cmdline = "console=tty0 console=ttyS0 " ++ DEVICES ++ " " ++ EXIT_DIET,
    },
    // The lab image this repo builds itself (scripts/virt/build_ssh_guest.sh):
    // Alpine-based, the initramfs IS the system — bash, GNU coreutils, udhcpc
    // and dropbear sshd, root/kudos on the ttyS0 getty. Useful on the serial
    // console alone today, and ready to DHCP + answer ssh the moment the
    // hypervisor grows a virtio-net device. Served by the operator
    // (scripts/virt/serve_ssh_guest.sh): 10.0.2.2 is QEMU slirp's address for
    // the host, right whenever kudos itself runs under QEMU on the machine
    // that serves the pair; kudos on real hardware (lemon) needs the serving
    // machine's LAN address here instead — edit, rebuild, reflash.
    .{
        .name = "kudos lab Linux (bash + sshd, runs from RAM)",
        .kernel_url = "http://10.0.2.2:8000/bzImage",
        .initramfs_url = "http://10.0.2.2:8000/initramfs.cpio.gz",
        .ram_mb = 512,
        .approx_mb = 14,
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
