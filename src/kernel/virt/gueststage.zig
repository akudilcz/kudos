//! The Linux guest image staged into this build. The scripts/virt/build_*.sh
//! family each produce a 64-bit bzImage and an initramfs under assets/virt/
//! (git-ignored, optional); `-Dguest=<name>` picks which pair is staged, and
//! the kernel embeds the chosen one here via @embedFile — the
//! same mechanism seedRamdisk uses for teapot.glb, minus the ramdisk heap copy,
//! since only the VM boot path consumes these ~2 MiB and duplicating them into
//! the ramdisk would double the cost. When no guest was staged, the build wires
//! empty blobs (build.zig) and `staged()` reports false so `vm boot` says so.
//!
//! This is the one home of "which guest this build ships"; both the run path
//! (virt.bootStaged) and the reachability test (test/kernel/virt/gueststage_test.zig) read
//! the image through it, so the artifact the tree ships and the artifact the
//! loader accepts cannot drift.

const bzimage = @import("bzimage.zig");
const layout = @import("layout.zig");
const buildinfo = @import("buildinfo");

/// The staged kernel image (Linux/x86 bzImage). Empty when none was staged.
const guest_bzimage = @embedFile("guest_bzimage");
/// The staged root filesystem (gzip-compressed cpio initramfs). Empty when none.
const guest_initramfs = @embedFile("guest_initramfs");

/// The staged guest's name — the `-Dguest=<name>` the build was given, or the
/// default busybox pair. Recorded at build time beside the blobs it names, so
/// what the `vm boot` list calls entry 1 cannot drift from what was staged.
pub fn name() []const u8 {
    return buildinfo.staged_guest;
}

/// The staged bzImage bytes, to hand to the loader (virt/linuxload.zig).
pub fn bzImage() []const u8 {
    return guest_bzimage;
}

/// The staged initramfs bytes, placed high in guest RAM by the loader.
pub fn initramfs() []const u8 {
    return guest_initramfs;
}

/// The parsed boot header of the staged bzImage, or null when none is staged or
/// the bytes do not parse — the load parameters (protocol version, load address,
/// init_size) read through the same parser the loader uses, so what the tree
/// ships and what the loader accepts cannot drift. `staged` is built on it.
pub fn header() ?bzimage.BzInfo {
    if (guest_bzimage.len == 0) return null;
    return bzimage.parse(guest_bzimage) catch null;
}

/// Whether a bootable guest is staged: both blobs present AND the bzImage parses
/// as a 64-bit Linux boot image. A truncated, wrong-arch, or absent image reads
/// as "not staged", so `vm boot` reports it rather than handing the loader an
/// image it will reject deeper in.
pub fn staged() bool {
    if (guest_initramfs.len == 0) return false;
    const h = header() orelse return false;
    return h.xlf_kernel_64;
}

/// How much RAM the staged guest needs, derived from the image itself rather
/// than fixed for one of them: a busybox initramfs and a browser initramfs
/// differ by two orders of magnitude, and a guest given a constant sized for the
/// smaller one dies unpacking its own root filesystem.
///
/// Two terms, both about the initramfs, because a kudos guest has no disk
/// (VIRT-004) and its whole system lives in RAM:
///   - the tmpfs it unpacks INTO. A gzipped cpio of a real userland lands near
///     UNPACK_RATIO times its packed size (measured on the Firefox image:
///     662 MiB from 236 MiB).
///   - room for that userland to RUN in — heap, page cache, a browser's own
///     working set. A browser is the demanding case and its working set is not
///     proportional to its rootfs at all: several processes, each with a
///     software rasteriser's buffers for a whole scanout. Sized so the measured
///     Firefox image gets its tmpfs and about two GiB on top of it, because a
///     guest that runs out does not report a shortage — its allocations fail and
///     its libraries dereference the failure, which reads as a null-pointer bug
///     in whatever library happened to ask.
/// A floor keeps the small guests exactly where they were.
pub fn ramBytes() u64 {
    const packed_len = initramfs().len;
    const rootfs = packed_len * UNPACK_RATIO;
    return @min(layout.MAX_RAM_BYTES, @max(MIN_RAM_BYTES, rootfs * RUNTIME_MULTIPLE));
}

/// Bytes a gzipped cpio initramfs unpacks to, per byte packed.
const UNPACK_RATIO: usize = 3;
/// Total RAM per byte of unpacked root filesystem: the tree itself plus the room
/// its userland needs to run. A browser's own working set dominates and is not
/// proportional to the tree at all, so this is set for the demanding case; the
/// browser image lands above the ceiling and takes all of it.
const RUNTIME_MULTIPLE: usize = 6;
/// The floor, which is what every guest smaller than a browser gets: a busybox
/// initramfs boot fits comfortably in 128 MiB and several such guests stay far
/// inside the frame allocator's budget.
const MIN_RAM_BYTES: u64 = 128 * 1024 * 1024;
