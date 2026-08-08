#!/usr/bin/env bash
# build_ssh_guest.sh — build the "kudos lab Linux" netboot pair: a guest kernel
# with virtio-net, and an Alpine-based initramfs that IS the system — real
# bash, GNU coreutils, udhcpc (busybox) and dropbear sshd. Runs on the host
# (this laptop / CI), NOT inside kudos. Artifacts land in assets/virt/ssh/
# (git-ignored except the checksum record); serve them with
# scripts/virt/serve_guest.sh and boot them with the "kudos lab Linux"
# catalog entry (src/kernel/virt/guestlist.zig); gate any change with
# scripts/virt/test_ssh_guest.sh.
#
# Credentials — the documented lab default: root / kudos, valid on the ttyS0
# getty and over ssh (dropbear allows root password logins by default). This
# is a throwaway RAM guest on a lab network; treat it as such.
#
# The initramfs is immediately useful on the serial console alone (getty on
# ttyS0 — today's kudos guests have no NIC), and the moment the hypervisor
# grows a virtio-net device the same image DHCPs on eth0 and answers ssh: the
# kernel carries CONFIG_VIRTIO_NET and /init starts udhcpc only when eth0
# exists, so a NIC-less boot neither hangs nor spams.
#
# Usage: scripts/virt/build_ssh_guest.sh [linux-version]
# Requires: the build_guest.sh kernel toolchain, plus openssl (password hash)
# and network access. Runs entirely as a plain user: apk installs into the
# rootfs unprivileged, and pack_initramfs.py owns the root:root ownership and
# the /dev/console node in the archive.
set -euo pipefail

LINUX_VERSION="${1:-6.6.52}"
# The Alpine base: minirootfs releases stay downloadable forever, so the
# version pins exactly. Packages come from the branch's current package index,
# which moves within the branch (Alpine deletes superseded .apks), so package
# versions track v3.23 stable rather than pinning — the SHA256SUMS record says
# what a given build actually produced.
ALPINE_BRANCH="v3.23"
ALPINE_MINIROOTFS_VERSION="3.23.5"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ROOT_PASSWORD="kudos"

CC_STD="gcc -std=gnu11"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$ROOT/assets/virt/ssh"
WORK="$ROOT/assets/virt/build"
ROOTFS="$WORK/ssh-rootfs"
MARKER="KUDOS-SSH-GUEST-UP"

mkdir -p "$OUT" "$WORK"

# --- 1. Kernel: the shared guest fragment plus networking. The additions are
# two groups: the virtio-net path itself, and the small-syscall floor a real
# multi-process userland needs that tinyconfig strips (uids for login/sshd,
# ptys for ssh sessions, futexes for musl's locks, ...).
cat > "$WORK/kudos_ssh_guest.config" <<'EOF'
# Networking: virtio-net over MMIO (same cmdline discovery as the gpu slot),
# TCP/IP for dropbear, raw packet sockets for udhcpc, unix sockets for
# userland plumbing.
CONFIG_NET=y
CONFIG_UNIX=y
CONFIG_INET=y
CONFIG_PACKET=y
CONFIG_NETDEVICES=y
CONFIG_NET_CORE=y
CONFIG_VIRTIO_NET=y
# PCI transport too: QEMU 10.x microvm's virtio-mmio probes EINVAL on this
# kernel, so the host smoke test rides plain q35/virtio-pci instead. Under the
# kudos hypervisor there is no PCI bus and these cost a few KiB of dead code;
# the MMIO transport above stays the kudos path.
CONFIG_PCI=y
CONFIG_PCI_MSI=y
CONFIG_VIRTIO_PCI=y
# The multi-process floor tinyconfig removes: real uids (login, sshd
# privilege model), POSIX file locks, pseudo-terminals for ssh sessions,
# futexes and the fd-based event syscalls musl and friends assume, tmpfs
# for /dev/shm.
CONFIG_MULTIUSER=y
CONFIG_FILE_LOCKING=y
CONFIG_UNIX98_PTYS=y
CONFIG_FUTEX=y
CONFIG_EPOLL=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_EVENTFD=y
CONFIG_POSIX_TIMERS=y
CONFIG_PROC_SYSCTL=y
CONFIG_SHMEM=y
CONFIG_TMPFS=y
EOF

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
./scripts/kconfig/merge_config.sh -m .config "$SCRIPT_DIR/guest_kernel.config" "$WORK/kudos_ssh_guest.config"
make olddefconfig

# merge_config only WARNS when an option loses to an unmet dependency, and
# olddefconfig then silently settles it. Assert the settings that carry a
# milestone, so a config regression fails the build instead of the field.
for opt in VIRTIO_MMIO VIRTIO_MMIO_CMDLINE_DEVICES DRM_VIRTIO_GPU \
           DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE SERIAL_8250_CONSOLE \
           VIRTIO_NET VIRTIO_PCI INET PACKET UNIX98_PTYS MULTIUSER FUTEX; do
    grep -qx "CONFIG_$opt=y" .config || {
        echo "build_ssh_guest: CONFIG_$opt did not survive the config merge" >&2
        exit 1
    }
done

make CC="$CC_STD" HOSTCC="$CC_STD" -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$OUT/bzImage"

# --- 2. Fetch the Alpine base and a static apk to install into it with.
cd "$WORK"
MINIROOTFS="alpine-minirootfs-$ALPINE_MINIROOTFS_VERSION-x86_64.tar.gz"
if [ ! -f "$MINIROOTFS" ]; then
    curl -fLO "$ALPINE_MIRROR/$ALPINE_BRANCH/releases/x86_64/$MINIROOTFS"
fi
# apk-tools-static: the branch keeps exactly one version and deletes the old
# one on upgrade, so the current filename is scraped, not pinned.
if [ ! -x "$WORK/apk.static" ]; then
    APK_TOOLS_APK="$(curl -fsS "$ALPINE_MIRROR/$ALPINE_BRANCH/main/x86_64/" |
        grep -o 'apk-tools-static-[^"]*\.apk' | sort -u | head -1)"
    [ -n "$APK_TOOLS_APK" ] || {
        echo "build_ssh_guest: no apk-tools-static in $ALPINE_BRANCH/main" >&2
        exit 1
    }
    curl -fL "$ALPINE_MIRROR/$ALPINE_BRANCH/main/x86_64/$APK_TOOLS_APK" -o apk-tools-static.apk
    tar xzf apk-tools-static.apk --warning=no-unknown-keyword -O sbin/apk.static > apk.static.extracting
    chmod +x apk.static.extracting
    mv apk.static.extracting apk.static
fi

# --- 3. Assemble the rootfs.
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar xzf "$WORK/$MINIROOTFS" -C "$ROOTFS"

# The system on top of the base: real bash and GNU coreutils for humans,
# dropbear for ssh. udhcpc is already there (busybox). --no-scripts because
# package scripts would need a chroot; nothing these packages script matters
# to a RAM guest (the minirootfs already carries the busybox symlink farm the
# scripts would rebuild).
"$WORK/apk.static" --root "$ROOTFS" --arch x86_64 \
    --repository "$ALPINE_MIRROR/$ALPINE_BRANCH/main" \
    --no-cache --no-scripts --no-interactive \
    add bash coreutils dropbear

echo "kudos-lab" > "$ROOTFS/etc/hostname"

# root / $ROOT_PASSWORD, hashed with a fixed salt so rebuilding does not churn
# the archive; login shell is the bash this image exists to carry.
HASH="$(openssl passwd -6 -salt kudoslab "$ROOT_PASSWORD")"
sed -i "s|^root:[^:]*:|root:$HASH:|" "$ROOTFS/etc/shadow"
sed -i "s|^\(root:.*:\)/bin/a\?sh$|\1/bin/bash|" "$ROOTFS/etc/passwd"
grep -q '^root:.*:/bin/bash$' "$ROOTFS/etc/passwd" || {
    echo "build_ssh_guest: root shell edit missed — Alpine passwd layout changed?" >&2
    exit 1
}
# dropbear refuses any account whose shell is not in /etc/shells
# (svr-auth's getusershell() walk) — register the bash we just switched to.
grep -q '^/bin/bash$' "$ROOTFS/etc/shells" || echo /bin/bash >> "$ROOTFS/etc/shells"

# The consoles a root login is allowed on (busybox login consults this).
printf 'console\nttyS0\ntty0\ntty1\n' > "$ROOTFS/etc/securetty"

cat > "$ROOTFS/etc/motd" <<EOF
kudos lab Linux — Alpine $ALPINE_MINIROOTFS_VERSION base, runs entirely from RAM.
Login: root / $ROOT_PASSWORD (serial getty and ssh). Nothing persists a reboot.
EOF

# udhcpc's lease callback: ours, shipped at a path this image owns, so the
# network setup does not depend on which busybox packaging shipped (or
# dropped) a default script. busybox exports $interface/$ip/$mask (mask is
# the prefix length)/$router/$dns around each call.
mkdir -p "$ROOTFS/etc/kudos"
cat > "$ROOTFS/etc/kudos/udhcpc.script" <<'EOF'
#!/bin/sh
# busybox udhcpc callback: apply (or clear) the lease on $interface.
case "$1" in
deconfig)
    ip addr flush dev "$interface"
    ip link set "$interface" up
    ;;
bound | renew)
    ip addr flush dev "$interface"
    ip addr add "$ip/$mask" dev "$interface"
    if [ -n "${router:-}" ]; then
        ip route add default via "${router%% *}" dev "$interface" 2>/dev/null
    fi
    if [ -n "${dns:-}" ]; then
        for d in $dns; do echo "nameserver $d"; done > /etc/resolv.conf
    fi
    ;;
esac
EOF
chmod +x "$ROOTFS/etc/kudos/udhcpc.script"

# PID 1: mount the API filesystems, bring the network up if a NIC exists,
# start sshd, then hand off to busybox init for the respawning gettys.
cat > "$ROOTFS/init" <<EOF
#!/bin/sh
# kudos lab guest init (PID 1). The initramfs is the whole system; nothing is
# pivoted or persisted.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm /run
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /dev/shm || mount -t tmpfs tmpfs /dev/shm
exec </dev/console >/dev/console 2>&1
hostname -F /etc/hostname
ip link set lo up

# DHCP only when the NIC exists: today's kudos guests have none (VIRT-004), and
# an absent eth0 must cost nothing — no hang, no retry spam. -b backgrounds
# udhcpc after the first miss and keeps trying quietly once a NIC does appear.
if [ -e /sys/class/net/eth0 ]; then
    udhcpc -i eth0 -b -s /etc/kudos/udhcpc.script
fi

# dropbear: -R generates the host keys on first connection, into /etc/dropbear
# on this RAM root — fresh keys every boot, nothing persisted, so ssh clients
# should expect the host key to change (the smoke test passes
# StrictHostKeyChecking=no for exactly that reason).
dropbear -R

echo "$MARKER"
# busybox init: the respawning gettys (/etc/inittab) on the serial console —
# ttyS0 is /dev/console under kudos — and on tty1, the virtio-gpu scanout.
exec /sbin/init
EOF
chmod +x "$ROOTFS/init"

cat > "$ROOTFS/etc/inittab" <<'EOF'
# busybox init: /init already did one-time setup; init only owns the gettys.
ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
tty1::respawn:/sbin/getty 38400 tty1
::ctrlaltdel:/sbin/reboot
::restart:/sbin/init
EOF

# --- 4. Pack (reproducibly: root:root, sorted, mtime 0, /dev/console node).
python3 "$SCRIPT_DIR/pack_initramfs.py" "$ROOTFS" "$OUT/initramfs.cpio.gz"

# --- 5. Record the exact checksums this build produced (the one committed
# record of which artifacts a tree was tested against).
cd "$OUT"
sha256sum bzImage initramfs.cpio.gz > SHA256SUMS
echo "ssh guest artifacts written to $OUT:"
ls -l bzImage initramfs.cpio.gz
cat SHA256SUMS
