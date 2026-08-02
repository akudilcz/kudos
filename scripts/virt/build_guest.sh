#!/usr/bin/env bash
# build_guest.sh — produce the minimal Linux guest artifacts kudos boots:
# a tiny 64-bit bzImage with an 8250 serial console and a busybox initramfs.
# Runs on the host (this laptop / CI), NOT inside kudos. The artifacts land in
# assets/virt/ (git-ignored except the checksum record).
#
# The guest is deliberately minimal: it must boot with only the devices kudos
# emulates (16550 serial, x2APIC, virtio-gpu over MMIO; no ACPI/PCI/disk). The
# initramfs prints the marker KUDOS-GUEST-UP and execs a shell on the serial
# console, while kernel messages also land on the framebuffer console the
# hypervisor composites into the VM window.
#
# Usage: scripts/virt/build_guest.sh [linux-version]
# Requires: curl, make, gcc, flex, bison, bc, libelf-dev, cpio, gzip
# (the stock kernel/busybox build toolchain), network access, ~2 GiB in
# assets/virt/build/.
set -euo pipefail

LINUX_VERSION="${1:-6.6.52}"
BUSYBOX_VERSION="1.36.1"

# GCC 15+ defaults to -std=gnu23, where bool/true/false are keywords; the 6.6.x
# kernel and busybox 1.36 predate C23 and still typedef them, so a stock modern
# toolchain rejects them ("bool cannot be defined via typedef"). Pin the C
# standard to gnu11 for the target and host compilers. Harmless on older GCC
# (which already defaulted to gnu11/gnu17). No package install required.
CC_STD="gcc -std=gnu11"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$ROOT/assets/virt"
WORK="$OUT/build"
mkdir -p "$OUT" "$WORK"

MARKER="KUDOS-GUEST-UP"

# --- 1. Fetch + build the kernel. The config fragment shared by every kudos
# guest kernel lives in scripts/virt/guest_kernel.config (one home; the ssh
# guest build merges the same file plus its networking additions).
cd "$WORK"
KDIR="linux-$LINUX_VERSION"
if [ ! -d "$KDIR" ]; then
    curl -fLO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VERSION.tar.xz"
    # Extract to a scratch name and rename: an interrupted tar must not leave a
    # partial tree that a rerun would silently build from.
    rm -rf "$KDIR.extracting"
    mkdir "$KDIR.extracting"
    tar xf "linux-$LINUX_VERSION.tar.xz" --strip-components=1 -C "$KDIR.extracting"
    mv "$KDIR.extracting" "$KDIR"
fi
cd "$KDIR"
make tinyconfig
./scripts/kconfig/merge_config.sh -m .config "$SCRIPT_DIR/guest_kernel.config"
make olddefconfig

# merge_config only WARNS when an option loses to an unmet dependency, and
# olddefconfig then silently settles it — a dropped FRAMEBUFFER_CONSOLE would
# build a kernel that boots fine and never paints. Assert the settings that
# carry a milestone, so a config regression fails the build instead of the eye.
for opt in VIRTIO_MMIO VIRTIO_MMIO_CMDLINE_DEVICES DRM_VIRTIO_GPU \
           DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE SERIAL_8250_CONSOLE; do
    grep -qx "CONFIG_$opt=y" .config || {
        echo "build_guest: CONFIG_$opt did not survive the config merge" >&2
        exit 1
    }
done

make CC="$CC_STD" HOSTCC="$CC_STD" -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$OUT/bzImage"

# --- 2. Build a static busybox and a cpio.gz initramfs.
cd "$WORK"
BDIR="busybox-$BUSYBOX_VERSION"
if [ ! -d "$BDIR" ]; then
    curl -fLO "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2"
    rm -rf "$BDIR.extracting"
    mkdir "$BDIR.extracting"
    tar xf "busybox-$BUSYBOX_VERSION.tar.bz2" --strip-components=1 -C "$BDIR.extracting"
    mv "$BDIR.extracting" "$BDIR"
fi
cd "$BDIR"
make defconfig
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
# The `tc` (traffic-control) applet references CBQ structures deleted from modern
# kernel headers (tc_cbq_lssopt et al.); it will not compile against a current
# host toolchain and the guest shell does not need it. Drop it. The guest has no
# network at all — kudos emulates only serial + x2APIC — so this loses nothing.
sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config
make oldconfig < /dev/null
make CC="$CC_STD" HOSTCC="$CC_STD" -j"$(nproc)"

INITRD="$WORK/initramfs"
rm -rf "$INITRD"
mkdir -p "$INITRD"/{bin,sbin,proc,sys,dev}
cp busybox "$INITRD/bin/busybox"
for applet in sh mount ls cat echo; do ln -sf busybox "$INITRD/bin/$applet"; done

# The archive carries no device nodes — building those needs root, and this
# script must run as a plain user. So init claims its console ITSELF, once
# devtmpfs has provided one: the kernel hands PID 1 no stdin/stdout when
# /dev/console is absent at exec time, and everything the guest prints after
# that (including the marker below) would otherwise go nowhere at all.
cat > "$INITRD/init" <<EOF
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
exec </dev/console >/dev/console 2>&1
echo "$MARKER"
exec /bin/sh
EOF
chmod +x "$INITRD/init"

cd "$INITRD"
find . | cpio -o -H newc | gzip -9 > "$OUT/initramfs.cpio.gz"

# --- 3. Record the exact checksums this build produced (the one committed
# record of which artifacts a tree was tested against).
cd "$OUT"
sha256sum bzImage initramfs.cpio.gz > SHA256SUMS
echo "Guest artifacts written to $OUT:"
cat SHA256SUMS
