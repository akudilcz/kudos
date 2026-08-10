#!/usr/bin/env bash
# build_guest.sh — the one builder for every Linux guest kudos boots. One role,
# one script, one subcommand per image: a new guest is a new function here, not
# a new file. Runs on the host (this laptop / CI), NOT inside kudos, and
# entirely as a plain user — apk installs into a rootfs unprivileged and
# pack_initramfs.py owns the root:root ownership and the /dev/console node.
#
# THE WHOLE SYSTEM LIVES IN RAM. A kudos guest has no disk (VIRT-004), so the
# initramfs IS the root filesystem, and every image is sized for what it unpacks
# to plus what its userland then allocates — the numbers in
# src/kernel/virt/guestlist.zig come from what this script reports at the end.
#
# Usage: scripts/virt/build_guest.sh <image> [linux-version]
#
#   staged     busybox on a serial console. The one image STAGED INTO the kernel
#              binary (assets/virt/, wired by build.zig) rather than fetched, so
#              it is what `vm 1` and `make test-guest-qemu` boot.
#   firefox    the browser: Alpine + Mesa's llvmpipe + a Wayland kiosk + Firefox,
#              drawing into the guest's virtio-gpu scanout.
#   zigserver  the compile factory kudos itself has no compiler for (ARCH-012):
#              Alpine + the pinned Zig toolchain + scripts/agent/factory.py,
#              serving /compile on port 8623.
#   ubuntu     a minimal Ubuntu server: the ubuntu-base rootfs, running from RAM
#              with a root shell on the serial console and apt ready to use.
#
# The three fetched images are served to `vm boot` by scripts/virt/serve_guest.sh
# and named by the catalog in src/kernel/virt/guestlist.zig.
#
# Requires: curl, make, gcc, flex, bison, bc, libelf-dev, cpio, gzip, python3,
# network access, and ~8 GiB in assets/virt/build/.
set -euo pipefail

IMAGE="${1:-}"
LINUX_VERSION="${2:-6.6.52}"

# The Alpine base every non-Ubuntu image is built on: minirootfs releases stay
# downloadable forever, so the version pins exactly, while packages track the
# branch's current index (Alpine deletes superseded .apks) and the SHA256SUMS
# record says what a given build actually produced.
ALPINE_BRANCH="v3.23"
ALPINE_MINIROOTFS_VERSION="3.23.5"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# The Ubuntu base: a release tarball of the server userland with no kernel and
# no init, which is exactly what an initramfs guest wants.
UBUNTU_RELEASE="24.04"
UBUNTU_BASE_VERSION="24.04.4"
UBUNTU_BASE_MIRROR="https://cdimage.ubuntu.com/ubuntu-base/releases"

BUSYBOX_VERSION="1.36.1"
# The interactive shell every image gives a person. Pinned like the rest: a
# guest whose shell changes under it is a guest whose transcripts stop matching.
# Not `BASH_VERSION` — that names THIS script's own interpreter, and a build
# script that overwrites it is one that lies about what is running it.
GUEST_BASH_VERSION="5.2.21"

# GCC 15+ defaults to -std=gnu23, where bool/true/false are keywords; the 6.6.x
# kernel and busybox 1.36 predate C23 and still typedef them, so a stock modern
# toolchain rejects them ("bool cannot be defined via typedef"). Pin the C
# standard to gnu11 for the target and host compilers. Harmless on older GCC
# (which already defaulted to gnu11/gnu17). No package install required.
CC_STD="gcc -std=gnu11"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ASSETS="$ROOT/assets/virt"
WORK="$ASSETS/build"
mkdir -p "$ASSETS" "$WORK"

usage() {
    sed -n '2,30p' "$0" >&2
    exit 2
}

# ── shared machinery ────────────────────────────────────────────────────────
# Everything below is what all four images do the same way. An image function
# supplies only what makes it that image: a kconfig fragment, a rootfs, an init.

# Fetch and unpack the kernel source once per version, into $WORK/$KDIR.
fetch_kernel() {
    KDIR="linux-$LINUX_VERSION"
    [ -d "$WORK/$KDIR" ] && return 0
    # ~130 MiB over a CDN that sometimes drops an HTTP/2 stream mid-transfer:
    # resume rather than restart, retry the transient failures, and force
    # HTTP/1.1, whose framing has no such failure mode. --no-progress-meter
    # because a per-second progress line in a build log is a hundred KiB of
    # noise around the one line that matters.
    echo "build_guest: fetching linux-$LINUX_VERSION (~130 MiB) ..."
    curl -fL --http1.1 --retry 5 --retry-delay 2 --retry-connrefused \
        --continue-at - --no-progress-meter \
        -o "$WORK/linux-$LINUX_VERSION.tar.xz" \
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VERSION.tar.xz"
    # Extract to a scratch name and rename: an interrupted tar must not leave a
    # partial tree that a rerun would silently build from.
    rm -rf "$WORK/$KDIR.extracting"
    mkdir "$WORK/$KDIR.extracting"
    tar xf "$WORK/linux-$LINUX_VERSION.tar.xz" --strip-components=1 -C "$WORK/$KDIR.extracting"
    mv "$WORK/$KDIR.extracting" "$WORK/$KDIR"
}

# build_kernel <fragment-or-empty> <required-CONFIG-names...> — merge the shared
# guest fragment (scripts/virt/guest_kernel.config, one home) with the image's
# own, prove the settings that carry a milestone survived, and build a bzImage
# into $OUT.
build_kernel() {
    local fragment="$1"; shift
    fetch_kernel
    cd "$WORK/$KDIR"
    make tinyconfig
    # shellcheck disable=SC2086 # an absent fragment must expand to no argument
    ./scripts/kconfig/merge_config.sh -m .config "$SCRIPT_DIR/guest_kernel.config" $fragment
    make olddefconfig

    # merge_config only WARNS when an option loses to an unmet dependency, and
    # olddefconfig then silently settles it — a dropped FRAMEBUFFER_CONSOLE
    # would build a kernel that boots fine and never paints. Assert here, so a
    # config regression fails the build instead of the field.
    local opt
    for opt in "$@"; do
        grep -qx "CONFIG_$opt=y" .config || {
            echo "build_guest($IMAGE): CONFIG_$opt did not survive the config merge" >&2
            exit 1
        }
    done

    make CC="$CC_STD" HOSTCC="$CC_STD" -j"$(nproc)" bzImage
    cp arch/x86/boot/bzImage "$OUT/bzImage"
    cd "$WORK"
}

# Fetch the Alpine minirootfs and a static apk to install into it with.
fetch_alpine_base() {
    MINIROOTFS="alpine-minirootfs-$ALPINE_MINIROOTFS_VERSION-x86_64.tar.gz"
    if [ ! -f "$WORK/$MINIROOTFS" ]; then
        curl -fL --no-progress-meter -o "$WORK/$MINIROOTFS" \
            "$ALPINE_MIRROR/$ALPINE_BRANCH/releases/x86_64/$MINIROOTFS"
    fi
    # apk-tools-static: the branch keeps exactly one version and deletes the old
    # one on upgrade, so the current filename is scraped, not pinned.
    [ -x "$WORK/apk.static" ] && return 0
    local apk_tools
    apk_tools="$(curl -fsS "$ALPINE_MIRROR/$ALPINE_BRANCH/main/x86_64/" |
        grep -o 'apk-tools-static-[^"]*\.apk' | sort -u | head -1)"
    [ -n "$apk_tools" ] || {
        echo "build_guest: no apk-tools-static in $ALPINE_BRANCH/main" >&2
        exit 1
    }
    curl -fL --no-progress-meter -o "$WORK/apk-tools-static.apk" \
        "$ALPINE_MIRROR/$ALPINE_BRANCH/main/x86_64/$apk_tools"
    tar xzf "$WORK/apk-tools-static.apk" --warning=no-unknown-keyword \
        -O sbin/apk.static > "$WORK/apk.static.extracting"
    chmod +x "$WORK/apk.static.extracting"
    mv "$WORK/apk.static.extracting" "$WORK/apk.static"
}

# alpine_rootfs <dir> — a clean Alpine root at <dir>.
alpine_rootfs() {
    fetch_alpine_base
    rm -rf "$1"
    mkdir -p "$1"
    # -p: keep the archive's EXACT modes. tar only preserves setuid, setgid and
    # the sticky bit for the superuser unless asked, and this script runs as a
    # plain user — without it every such bit in the distribution is silently
    # dropped, which is not the distribution any more. pack_initramfs.py carries
    # whatever mode is on disk into the archive, so this is where it is decided.
    tar xzpf "$WORK/$MINIROOTFS" -C "$1"
}

# apk_add <rootfs> <package...> — install into a rootfs from outside it.
# --no-scripts because package scripts would need a chroot; nothing these
# packages script matters to a RAM guest (the minirootfs already carries the
# busybox symlink farm the scripts would rebuild).
apk_add() {
    local rootfs="$1"; shift
    "$WORK/apk.static" --root "$rootfs" --arch x86_64 \
        --repository "$ALPINE_MIRROR/$ALPINE_BRANCH/main" \
        --repository "$ALPINE_MIRROR/$ALPINE_BRANCH/community" \
        --no-cache --no-scripts --no-interactive add "$@"
}

# Build a static busybox once, into $BUSYBOX — the shell and the DHCP client for
# the images whose own base carries neither.
build_busybox() {
    BUSYBOX="$WORK/busybox-$BUSYBOX_VERSION/busybox"
    [ -x "$BUSYBOX" ] && return 0
    cd "$WORK"
    local bdir="busybox-$BUSYBOX_VERSION"
    if [ ! -d "$bdir" ]; then
        curl -fL --no-progress-meter -O "https://busybox.net/downloads/$bdir.tar.bz2"
        rm -rf "$bdir.extracting"
        mkdir "$bdir.extracting"
        tar xf "$bdir.tar.bz2" --strip-components=1 -C "$bdir.extracting"
        mv "$bdir.extracting" "$bdir"
    fi
    cd "$bdir"
    make defconfig
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    # The `tc` (traffic-control) applet references CBQ structures deleted from
    # modern kernel headers (tc_cbq_lssopt et al.); it will not compile against a
    # current host toolchain and no guest here needs it.
    sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config
    make oldconfig < /dev/null
    make CC="$CC_STD" HOSTCC="$CC_STD" -j"$(nproc)"
    cd "$WORK"
}

# Build a static bash once, into $BASH_BIN — the interactive shell EVERY image
# gives a person, so a guest shell has history, tab completion and the editing
# keys muscle memory expects. The package-managed images install their own
# (apk/apt); this build is for the images whose base has no package manager at
# all, where the alternative is busybox ash.
#
# Static for the same reason busybox is: one file, no loader and no libraries to
# carry, so it drops into an initramfs that holds nothing else.
build_bash() {
    BASH_BIN="$WORK/bash-$GUEST_BASH_VERSION/bash"
    [ -x "$BASH_BIN" ] && return 0
    cd "$WORK"
    local bdir="bash-$GUEST_BASH_VERSION"
    if [ ! -d "$bdir" ]; then
        curl -fL --no-progress-meter -O "https://ftp.gnu.org/gnu/bash/$bdir.tar.gz"
        rm -rf "$bdir.extracting"
        mkdir "$bdir.extracting"
        tar xf "$bdir.tar.gz" --strip-components=1 -C "$bdir.extracting"
        mv "$bdir.extracting" "$bdir"
    fi
    cd "$bdir"
    # --without-bash-malloc: bash's own allocator assumes a layout a static
    # glibc does not give it, and the symptom is a shell that aborts on its
    # first command rather than one that fails to build.
    ./configure --enable-static-link --without-bash-malloc CC="$CC_STD" >/dev/null
    make -j"$(nproc)" >/dev/null
    cd "$WORK"
}

# usable_root <rootfs> [shell] — make root an account a person can actually get
# into, and give it bash.
#
# Alpine's minirootfs and Ubuntu's base both ship root LOCKED: a `*` in the
# password field, which no password can ever hash to. An image whose console is
# a getty then presents a login prompt that CANNOT be answered — not by a blank
# password, not by any password — so the guest has no way in at all, and the
# symptom is indistinguishable from a guest with no shell.
#
# These are throwaway RAM guests: no disk, no persistence, nothing to protect. A
# login nobody can answer protects nothing and costs the shell.
usable_root() {
    local rootfs="$1" shell="${2:-/bin/bash}"
    sed -i 's|^root:[^:]*:|root::|' "$rootfs/etc/shadow"
    # Field 7 of the passwd line is the login shell; rewrite that one field
    # rather than the whole line, so the home directory and gecos stay whatever
    # the distribution set them to.
    awk -F: -v OFS=: -v sh="$shell" '$1 == "root" { $7 = sh } { print }' \
        "$rootfs/etc/passwd" > "$rootfs/etc/passwd.new"
    mv "$rootfs/etc/passwd.new" "$rootfs/etc/passwd"
}

# write_udhcpc_script <rootfs> — the lease callback, shipped at a path the image
# owns so network setup does not depend on which busybox packaging shipped (or
# dropped) a default script. busybox exports $interface/$ip/$mask (a prefix
# length)/$router/$dns around each call.
write_udhcpc_script() {
    mkdir -p "$1/etc/kudos"
    cat > "$1/etc/kudos/udhcpc.script" <<'EOF'
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
    chmod +x "$1/etc/kudos/udhcpc.script"
}

# pack_and_record <rootfs> — the archive and the one committed record of what a
# build produced. pack_initramfs.py owns root:root ownership, the sorted walk
# and the /dev/console node no unprivileged build tree can carry.
pack_and_record() {
    python3 "$SCRIPT_DIR/pack_initramfs.py" "$1" "$OUT/initramfs.cpio.gz"
    cd "$OUT"
    sha256sum bzImage initramfs.cpio.gz > SHA256SUMS
    local unpacked_mb packed_mb
    unpacked_mb=$(du -sm "$1" | cut -f1)
    packed_mb=$(du -m initramfs.cpio.gz | cut -f1)
    echo
    echo "build_guest($IMAGE): built in $OUT"
    echo "  bzImage           $(du -h bzImage | cut -f1)"
    echo "  initramfs.cpio.gz ${packed_mb} MiB packed, ${unpacked_mb} MiB unpacked"
    echo "  the guest needs RAM for the unpacked tree plus its userland's own"
    echo "  working set — guestlist.zig sizes the catalog entry from these."
}

# write_net_fragment — the kconfig every NETWORKED guest is built with, on top of
# the shared guest_kernel.config. One fragment for all three because the set is
# PROVEN under the kudos device model: an image built with less has been seen to
# probe its virtio transports and fail (-EINVAL, "failed to find virt queues"),
# which costs a whole guest boot to discover. Options a particular userland does
# not use cost a few KiB of dead code; a guest with no display and no network
# costs the run.
write_net_fragment() {
    cat > "$WORK/kudos_net_guest.config" <<'FRAGEOF'
# Input: the two virtio-input devices kudos gives every guest (kernel/virt/
# layout.zig wires the keyboard and tablet slots), read through evdev, which is
# the only interface libinput knows.
CONFIG_INPUT=y
CONFIG_INPUT_EVDEV=y
CONFIG_VIRTIO_INPUT=y
# The multi-process floor tinyconfig strips: futexes and the fd-based event
# syscalls musl and the compositor assume, unix sockets (the Wayland protocol
# IS a unix socket), shared memory (every Wayland buffer), ptys, real uids.
CONFIG_MULTIUSER=y
CONFIG_FILE_LOCKING=y
CONFIG_UNIX98_PTYS=y
CONFIG_FUTEX=y
CONFIG_EPOLL=y
# udev watches for device changes with inotify and refuses to start without it,
# and udev is what tells a compositor which display devices exist.
CONFIG_INOTIFY_USER=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_EVENTFD=y
CONFIG_POSIX_TIMERS=y
CONFIG_PROC_SYSCTL=y
CONFIG_SYSVIPC=y
CONFIG_SHMEM=y
CONFIG_TMPFS=y
CONFIG_AIO=y
CONFIG_ADVISE_SYSCALLS=y
CONFIG_MEMBARRIER=y
# DRM's mode-setting half: the compositor drives the scanout through KMS, not
# through the framebuffer console the staged guest is content with.
CONFIG_DRM_KMS_HELPER=y
# Networking, for the browsing this image exists to do once a bridge connects
# the guest's adapter to the wire.
# The PCI transport is carried alongside the MMIO one so the SAME pair boots
# under stock QEMU (q35 + virtio-net-pci), which is where scripts/virt/
# test_guest.sh proves an image before a kudos boot is spent on it. QEMU's
# microvm machine is the mmio-only alternative and its virtio has been seen to
# stall this kernel; under kudos there is no PCI bus at all, so this costs a few
# KiB of code nothing probes.
CONFIG_PCI=y
CONFIG_PCI_MSI=y
CONFIG_VIRTIO_PCI=y
CONFIG_NET=y
CONFIG_UNIX=y
CONFIG_INET=y
CONFIG_PACKET=y
CONFIG_NETDEVICES=y
CONFIG_NET_CORE=y
CONFIG_VIRTIO_NET=y
# ACPI, so this kernel can read the tables kudos builds (kernel/virt/acpi.zig)
# and find its processors. It does NOT get this guest an I/O APIC: kudos models
# the 8259 pair and nothing else, and its MADT says so, which is why every kudos
# guest command line carries `acpi=off` (kernel/virt/layout.zig, NO_IOAPIC) —
# an ACPI-enabled Linux that finds no I/O APIC can route no device interrupt at
# all, and every virtio device then fails to probe. Keeping the option on means
# the same image still boots on a machine that HAS one; the command line is
# where the decision belongs, because that is where kudos states its own truth.
CONFIG_ACPI=y
FRAGEOF
}

# The settings that carry a milestone, asserted after the merge for every
# networked image: merge_config only WARNS when an option loses to an unmet
# dependency and olddefconfig then silently settles it.
NET_GUEST_ASSERTS="VIRTIO_MMIO VIRTIO_MMIO_CMDLINE_DEVICES DRM_VIRTIO_GPU \
    SERIAL_8250_CONSOLE VIRTIO_INPUT INPUT_EVDEV UNIX SHMEM TMPFS \
    FUTEX MULTIUSER UNIX98_PTYS VIRTIO_NET INET ACPI X86_IO_APIC"

# ── staged: the built-in busybox guest ──────────────────────────────────────
# Deliberately minimal: it must boot with only the devices kudos emulates (16550
# serial, x2APIC, virtio-gpu over MMIO; no ACPI/PCI/disk). Its initramfs prints
# the marker and execs a shell on the serial console, while kernel messages also
# land on the framebuffer console the hypervisor composites into the VM window.
image_staged() {
    OUT="$ASSETS"
    local marker="KUDOS-GUEST-UP"

    build_kernel "" VIRTIO_MMIO VIRTIO_MMIO_CMDLINE_DEVICES DRM_VIRTIO_GPU \
        DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE SERIAL_8250_CONSOLE

    build_busybox
    build_bash
    local initrd="$WORK/initramfs"
    rm -rf "$initrd"
    mkdir -p "$initrd"/{bin,sbin,proc,sys,dev}
    cp "$BUSYBOX" "$initrd/bin/busybox"
    local applet
    for applet in sh mount ls cat echo; do ln -sf busybox "$initrd/bin/$applet"; done
    # busybox supplies the applets; bash is what a person is given to type at.
    # /bin/sh stays busybox ash — init's own script runs under it, and a shell
    # for scripts and a shell for people are two different jobs.
    cp "$BASH_BIN" "$initrd/bin/bash"

    # The guest's half of the hypervisor's contracts (guestcheck.c), in the image
    # that boots in seconds rather than only in the one that takes four minutes:
    # every contract it tests — a feature that executes, a vector register that
    # survives an exit, a page written then made executable then written again —
    # is one whose breakage presents as a segfault somewhere else entirely.
    # Statically linked, so it needs nothing this initramfs does not have.
    $CC_STD -static -O1 -o "$initrd/bin/guestcheck" "$SCRIPT_DIR/guestcheck.c"

    # The archive carries no device nodes — building those needs root, and this
    # script must run as a plain user. So init claims its console ITSELF, once
    # devtmpfs has provided one: the kernel hands PID 1 no stdin/stdout when
    # /dev/console is absent at exec time, and everything the guest prints after
    # that (including the marker below) would otherwise go nowhere at all.
    cat > "$initrd/init" <<EOF
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
exec </dev/console >/dev/console 2>&1
echo "$marker"
# The contracts, stated on the console of the guest that boots fastest: this is
# the cheapest place any of them can be found broken, and a hypervisor that
# breaks one breaks it for every guest, not only this one.
/bin/guestcheck
exec /bin/bash --login
EOF
    chmod +x "$initrd/init"

    # Packed with cpio rather than pack_initramfs.py: this is the archive that
    # gets staged INTO the kernel binary and gated by `make test-guest-qemu`, and
    # it wants no device nodes at all (see the init above).
    cd "$initrd"
    find . | cpio -o -H newc | gzip -9 > "$ASSETS/initramfs.cpio.gz"
    cd "$ASSETS"
    sha256sum bzImage initramfs.cpio.gz > SHA256SUMS
    echo "build_guest(staged): artifacts written to $ASSETS:"
    cat SHA256SUMS
}

# ── firefox: the browser image ──────────────────────────────────────────────
# There is no virgl and no GPU in the guest: Mesa falls back to llvmpipe, its
# software rasteriser, and the compositor puts the result in a virtio-gpu 2D
# resource that kudos textures into the VM window. Every frame is CPU-drawn and
# then copied once — correct, and slow in the way software rendering inside a
# hypervisor is slow.
image_firefox() {
    OUT="$ASSETS/firefox"
    ROOTFS="$WORK/firefox-rootfs"
    mkdir -p "$OUT"

# What the kiosk opens with. The hypervisor bridges the guest's NIC onto the
# machine's wire (VIRT-027), so the default is a real website — the point of
# the exercise is a browser that BROWSES. The self-describing local page is
# still in the image at file:///usr/share/kudos/start.html for runs where the
# wire is deliberately absent.
START_URL="${START_URL:-https://en.wikipedia.org/wiki/Operating_system}"

# The scanout the compositor drives. Held at the ivirt scanout ceiling
# (iface/ivirt.zig FB_MAX_W/FB_MAX_H), because the device model refuses a larger
# mode and a guest that asks for one gets no display at all.
FB_W="${FB_W:-1600}"
FB_H="${FB_H:-900}"

# Whether the compositor starts the browser itself. The kiosk image wants it to;
# a development run usually does not, because the browser then races anything
# started by hand and every experiment costs a full rebuild instead of a line at
# the guest's own shell. With AUTOSTART=0 the guest still comes up all the way —
# compositor running, network up, probes reported — and stops at a shell with
# `kiosk-firefox` waiting to be typed.
AUTOSTART="${AUTOSTART:-1}"
if [ "$AUTOSTART" = "1" ]; then
    AUTOLAUNCH_SECTION="
[autolaunch]
path=/usr/bin/kiosk-firefox
"
else
    AUTOLAUNCH_SECTION=""
fi

# The marker /init prints once the browser has been launched. The QEMU test
# harness watches the serial console for it.
MARKER="KUDOS-FIREFOX-UP"

# How long /init waits for udev's coldplug to finish before starting the
# compositor anyway. Every wait states a budget: a guest whose devices never
# appear must reach its serial shell and say so, not hang in PID 1.
UDEV_SETTLE_S=30

# How long /init waits for the DHCP lease before starting the compositor anyway.
# The browser resolves its start URL once, at launch, so a lease that lands after
# it has given up costs a whole boot to notice and looks exactly like a broken
# bridge. Waiting first makes the lease a precondition rather than a race. The
# budget is generous because a guest that comes up before the bridge does is the
# case it exists for; when it expires the browser still starts, and says it is
# offline, which is a true and diagnosable answer.
DHCP_WAIT_S=30

# How long the userspace stress probe runs before the compositor starts. It
# exists to answer one question early and cheaply — does this guest execute
# ordinary forks and threads correctly? — because everything above it is built
# on the answer, and a browser is a slow and ambiguous way to ask. Seconds, not
# minutes: a CPU-state fault shows up immediately or not at all.
STRESS_S=15

# How long the control Wayland client is given to prove it can hold a buffer
# before the browser replaces it. A client that cannot get one fails on its
# first frame, so this only has to outlast a compositor round trip.
CONTROL_S=5

# How long the death watch waits for the browser to appear before concluding it
# never did. It has to outlast the control client above plus a browser's own
# start-up on a software rasteriser, which is unhurried.
BROWSER_START_S=60

# How often /init checks that the compositor and the browser are both still
# alive. Every wait states a budget: a few seconds is fast enough that the death
# report names the failure while its log lines are still on screen, and slow
# enough to cost a guest with a software rasteriser nothing.
WATCH_INTERVAL_S=5

# How many of those checks pass between routine memory reports. A trend is what
# distinguishes a guest that is merely tight from one that is being consumed.
MEMORY_EVERY_CHECKS=6

# How long /init lets the compositor talk before printing its device report.
# Long enough for wlroots' backend start-up, short enough that a stuck guest is
# still diagnosed within one look at the window.
REPORT_DELAY_S=6

# How many driver log lines the report carries. The VM window shows one
# screenful, so this is chosen to leave the earlier report lines visible.
DMESG_TAIL_LINES=6

# Where the report folds a long driver line. The VM window wraps rather than
# truncates, but a line folded to the console's own width stays readable
# instead of breaking mid-word at whatever the window happens to be.
CONSOLE_COLS=56

# The kernel-command-line token that carries a script for the guest to run
# (see run_cmdline_script in /init). Named once here because the guest reads it
# and every caller writes it, and a token spelled two ways is a script that
# silently never runs.
RUN_TOKEN="kudos.run"

# Kernel: the shared guest fragment, plus what a graphical multi-process
# userland needs. Three groups: the input drivers the browser is driven with,
# the syscall floor musl and a Wayland compositor assume, and networking.
# --- 1. Kernel: the shared guest fragment, plus what a graphical multi-process
# userland needs. Three groups: the input drivers the browser is driven with,
# the syscall floor musl and a Wayland compositor assume, and networking (idle
# until a NIC bridge connects the guest, and cheap to carry until then).
write_net_fragment
# shellcheck disable=SC2086 # the assert list is a deliberate word-split
build_kernel "$WORK/kudos_net_guest.config" $NET_GUEST_ASSERTS

alpine_rootfs "$ROOTFS"


# The browser and everything under it:
#   mesa-dri-gallium + mesa-egl/gbm — llvmpipe, the software GL this guest has
#                                     instead of a GPU
#   weston + weston-backend-drm     — the Wayland compositor, run as a kiosk
#                                     (kiosk-shell ships in the main package).
#                                     Chosen over the wlroots kiosks: cage
#                                     asserts in wlr_xdg_surface_schedule_
#                                     configure when Firefox negotiates its
#                                     decoration mode before the surface's
#                                     initial commit, and dies taking the
#                                     browser's display with it.
#   xkeyboard-config                — the XKB keymap data weston compiles its
#                                     keymap from; absence is fatal at startup
#   seatd                           — the seat/device broker libinput goes
#                                     through for /dev/input and /dev/dri
#   eudev                           — devtmpfs creates the device NODES, but a
#                                     compositor does not enumerate /dev: it
#                                     asks libudev, which answers only from a
#                                     database a running udevd populates. With
#                                     no udevd there are zero KMS devices to
#                                     find and the compositor sees no GPU.
#   font-dejavu                     — a browser with no font renders nothing
#   adwaita-icon-theme              — GTK resolves its stock icons through an
#                                     icon theme; with none, loading one is a
#                                     failed assertion and GTK aborts the
#                                     process rather than drawing without it
#   librsvg                         — those icons are SVG, and the pixbuf
#                                     loader that decodes SVG lives here. GTK's
#                                     own built-in Adwaita resources are SVG
#                                     too, so this is needed even for the
#                                     theme no package provides.
#   gsettings-desktop-schemas       — GTK reads its settings from GSettings and
#                                     treats a missing schema as fatal
#   dbus                            — Firefox expects a session bus; without one
#                                     it retries and logs on every service
#   firefox-esr                     — the point of the exercise
#   weston-clients                  — the CONTROL. A browser is the worst
#                                     possible first Wayland client to debug
#                                     with: when it fails to paint, the fault
#                                     could be the virtual GPU, the compositor,
#                                     the buffer path, or the browser. A tiny
#                                     known-good client that only allocates a
#                                     shared-memory buffer and draws into it
#                                     splits that four ways into one, and its
#                                     liveness is the whole assertion.
#   stress-ng                       — the other control, for the layer below:
#                                     fork, threads and CPU state exercised
#                                     hard, from userspace, in seconds. A guest
#                                     whose processes die at low addresses is
#                                     either running a browser bug or a
#                                     hypervisor bug, and this is what tells
#                                     the two apart without waiting on a
#                                     browser to boot.
# --no-scripts because package scripts want a chroot the build does not have;
# the minirootfs already carries the busybox symlink farm they would rebuild,
# and the caches they warm (fonts, icons) are rebuilt at first use instead.
"$WORK/apk.static" --root "$ROOTFS" --arch x86_64 \
    --repository "$ALPINE_MIRROR/$ALPINE_BRANCH/main" \
    --repository "$ALPINE_MIRROR/$ALPINE_BRANCH/community" \
    --no-cache --no-scripts --no-interactive \
    add bash mesa-dri-gallium mesa-egl mesa-gbm weston weston-backend-drm \
        weston-clients xkeyboard-config seatd eudev font-dejavu \
        adwaita-icon-theme librsvg gsettings-desktop-schemas dbus firefox-esr \
        stress-ng

echo "kudos-firefox" > "$ROOTFS/etc/hostname"
usable_root "$ROOTFS"

# The guest conformance probe (guestcheck.c). Built here rather than shipped as
# a package because it is ours and it is the guest's half of the contracts the
# hypervisor makes: every CPUID feature it advertises can be executed, and a
# page can be written, sealed executable, and run. Statically linked so it
# depends on nothing in the image and can be dropped into any guest rootfs,
# whatever libc it has.
$CC_STD -static -O1 -o "$ROOTFS/usr/bin/guestcheck" "$SCRIPT_DIR/guestcheck.c"

# The page the kiosk opens with when nothing external is reachable. It states
# what it is proving, so a screenshot of it is self-describing.
mkdir -p "$ROOTFS/usr/share/kudos"
cat > "$ROOTFS/usr/share/kudos/start.html" <<EOF
<!doctype html>
<title>Firefox on kudos</title>
<style>
  body { background:#0a0d10; color:#e6edf3; font:16px/1.6 system-ui,sans-serif;
         margin:0; display:grid; place-items:center; height:100vh; }
  main { max-width:44rem; padding:2rem; }
  h1 { font-size:2rem; margin:0 0 .5rem; }
  p { color:#9fb0c0; }
  code { color:#7ee787; }
</style>
<main>
  <h1>Firefox, rendering inside kudos</h1>
  <p>This page is drawn by Firefox in a Linux guest, on Mesa's <code>llvmpipe</code>
     software renderer, into a virtio-gpu scanout that the kudos hypervisor
     composites into a VM window on the desktop.</p>
  <p>Guest: Alpine $ALPINE_MINIROOTFS_VERSION, Linux $LINUX_VERSION, ${FB_W}x${FB_H}, entirely in RAM.</p>
</main>
EOF

# What udhcpc runs at each lease event. Busybox looks here by default; the
# minirootfs ships no script at all, and udhcpc without one acquires a lease
# and then configures NOTHING — an interface that looks up with no address.
mkdir -p "$ROOTFS/usr/share/udhcpc"
cat > "$ROOTFS/usr/share/udhcpc/default.script" <<'EOF'
#!/bin/sh
# udhcpc lease hook: put the offered address, route and resolver into effect.
case "$1" in
bound|renew)
    ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
    [ -n "${router:-}" ] && route add default gw ${router%% *} "$interface"
    [ -n "${dns:-}" ] && {
        : > /etc/resolv.conf
        for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
    }
    ;;
deconfig)
    ifconfig "$interface" 0.0.0.0
    ;;
esac
EOF
chmod +x "$ROOTFS/usr/share/udhcpc/default.script"

# Weston's kiosk configuration. kiosk-shell fullscreens every client on the one
# output; autolaunch makes weston itself start (and re-export WAYLAND_DISPLAY
# to) the browser, so there is no socket-name handshake to get wrong. The
# pixman renderer keeps compositing on plain CPU pixels — the GL renderer would
# stack llvmpipe under the compositor as well as under the browser for nothing.
mkdir -p "$ROOTFS/etc/xdg/weston"
cat > "$ROOTFS/etc/xdg/weston/weston.ini" <<EOF
[core]
shell=kiosk-shell.so
renderer=pixman
idle-time=0
$AUTOLAUNCH_SECTION
[shell]
locking=false
EOF

# The one client the kiosk exists to run. Weston's autolaunch takes a bare
# executable path, no arguments — this script is the arguments. No --window-size:
# kiosk-shell fullscreens the window to the scanout regardless, and Firefox
# reads a bare "W,H" token as a URL and navigates to it instead of the page.
cat > "$ROOTFS/usr/bin/kiosk-firefox" <<EOF
#!/bin/sh
# Started by weston's [autolaunch] with WAYLAND_DISPLAY already set.

# The control, before the browser. weston-simple-shm does exactly one thing:
# allocate a shared-memory buffer, attach it to a surface, and keep drawing.
# That is the whole path a browser needs and the whole path that is in doubt,
# with none of a browser's own complexity on top — so if it lives, the virtual
# GPU, the compositor and the buffer path are all proven, and a browser that
# then fails has failed for reasons of its own. Its liveness IS the assertion;
# a client that cannot get a buffer exits at once.
weston-simple-shm > /tmp/control.log 2>&1 &
CONTROL_PID=\$!
sleep ${CONTROL_S}
if kill -0 \$CONTROL_PID 2>/dev/null; then
    echo "kudos-guest: CONTROL-CLIENT-ALIVE — shm buffer path works" > /dev/console
else
    echo "kudos-guest: CONTROL-CLIENT-DIED — the fault is below the browser" > /dev/console
    tail -5 /tmp/control.log > /dev/console
fi
kill \$CONTROL_PID 2>/dev/null

# A stock browser, as plainly as it can be started. --kiosk is not here on
# purpose: the compositor's kiosk-shell already fullscreens every client, so the
# flag adds nothing but a second, less-travelled path through the browser's own
# UI. --no-sandbox stays because it is not a preference — this kernel has no
# user namespaces for the sandbox to build on, and the isolation that matters
# here is the virtual machine around the whole guest.
exec dbus-run-session firefox-esr \\
    --no-remote --no-sandbox \\
    --profile /root/.mozilla/firefox/kudos \\
    "$START_URL"
EOF
chmod +x "$ROOTFS/usr/bin/kiosk-firefox"

# The browser's profile settings. ONE line, because this guest is meant to run
# a stock browser: every pref beyond what the hardware makes true is a setting
# that has to be carried, explained, and re-justified for the next application.
# There is no GPU here, so software rendering is not a workaround — it is the
# machine — and naming it only skips a probe that would reach the same answer.
mkdir -p "$ROOTFS/usr/share/kudos"
cat > "$ROOTFS/usr/share/kudos/user.js" <<'EOF'
user_pref("gfx.webrender.software", true);
EOF

# /init — the whole of userspace start-up for this image.
#
# An initramfs gets PID 1 and nothing else: no service manager, no login, no
# getty. Everything a distribution's init would have done that this guest
# actually needs is here, in order, and each step says so on the serial console
# so a guest that dies half-way names the step it died in rather than going
# quiet.
cat > "$ROOTFS/init" <<EOF
#!/bin/sh
# PID 1 for the kudos Firefox guest. Fails loud: every step announces itself on
# the console kudos mirrors into the VM window's status area.
set -u
say() { echo "kudos-guest: \$*" > /dev/console; }

mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev
mkdir -p /dev/pts /dev/shm /tmp /run
# A directory mkdir creates is 0755 and root-owned; /tmp and /dev/shm are
# STICKY AND WORLD-WRITABLE on every real system, and things quietly assume it.
# apt is the one that names the assumption out loud: it drops to the `_apt` user
# to fetch, cannot then write /tmp/apt.conf.XXXXXX, so signature checking never
# runs and every repository reports itself unsigned.
chmod 1777 /tmp /dev/shm
mount -t devpts none /dev/pts
mount -t tmpfs  none /dev/shm
mount -t tmpfs  none /tmp
mount -t tmpfs  none /run
say "filesystems mounted"

# udev. devtmpfs already made the device nodes, so this is not about /dev: it is
# about the DATABASE under /run/udev. A compositor never looks in /dev — it asks
# libudev what display and input devices exist, and libudev answers only for
# devices a running udevd has processed. Without this the guest has a perfectly
# good /dev/dri/card0 that wlroots cannot see, and it stops at "Waiting for a
# KMS device to become available" with nothing wrong that any log names.
# The settle is what makes the wait bounded: the compositor starts after the
# coldplug it depends on has finished, not hopefully alongside it.
udevd --daemon
udevadm trigger --type=subsystems
udevadm trigger --type=devices
udevadm settle --timeout=${UDEV_SETTLE_S}
say "udev coldplug complete"

# The display and input topology, as the guest itself sees it. This is the
# evidence for every "the browser never appeared" question, so it reports what
# IS there rather than only complaining about what is not: a missing card0, a
# card0 with no connector, and a connector reading "disconnected" are three
# different faults with three different fixes, and only the first of them is
# visible from a device node's existence.
#
# It runs LAST, immediately before the console shell, because the VM window
# shows a screenful and does not scroll: a report printed early is a report
# nobody can read by the time it matters.
report_devices() {
    say "drm nodes: \$(ls /dev/dri 2>/dev/null | tr '\\n' ' ')"
    say "drm sysfs: \$(ls /sys/class/drm 2>/dev/null | tr '\\n' ' ')"
    for st in /sys/class/drm/*/status; do
        [ -r "\$st" ] || continue
        say "connector \$(basename \$(dirname \$st)): \$(cat \$st)"
    done
    say "input nodes: \$(ls /dev/input 2>/dev/null | tr '\\n' ' ')"
    say "virtio devices: \$(ls /sys/bus/virtio/devices 2>/dev/null | tr '\\n' ' ')"
    say "eth0: \$(ifconfig eth0 2>/dev/null | grep 'inet addr' | tr -s ' ')"
    say "resolv: \$(cat /etc/resolv.conf 2>/dev/null | tr '\\n' ' ')"
    # The kernel's own account of the drivers this image depends on. A device
    # that is discovered but refuses to bind says why here and nowhere else,
    # so the driver's errors get their own section rather than competing for
    # the tail with the routine registration chatter.
    dmesg | grep -iE 'virtio|drm|gpu' | grep -viE 'error' |
        tail -${DMESG_TAIL_LINES} | fold -w ${CONSOLE_COLS} | while read -r l; do
        say "dmesg: \$l"
    done
    dmesg | grep -E '\\*ERROR\\*|error' | tail -${DMESG_TAIL_LINES} |
        fold -w ${CONSOLE_COLS} | while read -r l; do
        say "err: \$l"
    done
    # A trailer, so the last real line is not flush against the bottom of a
    # window that shows one screenful: without it the wrapped remainder of the
    # most important line in the report is the part nobody can read.
    say "--- end of device report ---"
    say ""
    say ""
}

# A script handed to this guest on the kernel command line, as
# ${RUN_TOKEN}=<base64>. Base64 because a kernel command line is separated by
# whitespace and a shell script is full of it: encoding sidesteps quoting
# entirely, at both ends, and a token with no spaces in it cannot be split by
# anything between here and the guest.
#
# This is how a guest is driven by a machine instead of by a person typing at
# its console. Typing is the slower half of every guest investigation and the
# unreliable half: a keystroke goes to whichever window has focus, and a
# transcript that does not say which window that was is not evidence. A script
# named on the command line runs in the guest by construction, and its output
# and exit status come back on the serial console with markers around them, so
# a caller reading nothing but the serial stream knows exactly what happened.
#
# It runs after the whole machine is up and before the console shell, so a
# script sees the same guest a person at that shell would, and a guest given no
# script behaves exactly as it did before.
run_cmdline_script() {
    enc=\$(tr ' ' '\\n' < /proc/cmdline | sed -n 's/^${RUN_TOKEN}=//p')
    [ -n "\$enc" ] || return 0
    if ! echo "\$enc" | base64 -d > /tmp/kudos-run.enc 2>/dev/null; then
        say "KUDOS-RUN-UNDECODABLE — ${RUN_TOKEN}= is not base64"
        return 0
    fi
    # Gzipped if it decompresses, plain text if it does not. Linux accepts
    # about two kilobytes of command line and base64 costs a third on top of
    # what it encodes, so compressing is what keeps a useful script inside the
    # budget — and accepting both means the caller never has to say which.
    if ! gzip -dc /tmp/kudos-run.enc > /tmp/kudos-run.sh 2>/dev/null; then
        cp /tmp/kudos-run.enc /tmp/kudos-run.sh
    fi
    chmod +x /tmp/kudos-run.sh
    say "KUDOS-RUN-BEGIN"
    # Streamed line by line, not collected and printed at the end: a script
    # that takes minutes must show it is alive while it runs, and one that
    # hangs must show where. The exit status goes through a file because a
    # pipeline reports the status of its LAST stage, which here is the loop
    # that prints — it would report success for a script that died.
    { /tmp/kudos-run.sh 2>&1; echo \$? > /tmp/kudos-run.rc; } |
        fold -w ${CONSOLE_COLS} | while read -r l; do say "run: \$l"; done
    say "KUDOS-RUN-EXIT=\$(cat /tmp/kudos-run.rc 2>/dev/null || echo unknown)"
}

# The CPU this guest believes it has. A hypervisor's CPUID is a promise, and a
# guest takes it literally: a library that sees a vector extension advertised
# emits it, and a process that then faults leaves no trace naming the feature.
# So the promise is printed where the faults are read.
report_cpu() {
    say "cpu: \$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | tr -s ' ')"
    say "cores: \$(grep -c ^processor /proc/cpuinfo)"
    say "feat: \$(grep -m1 ^flags /proc/cpuinfo | tr ' ' '\\n' |
        grep -xE 'avx|avx2|avx512f|xsave|xsaveopt|fsgsbase|sse4_2|aes|rdrand|rdseed|pcid|smep|smap|erms|fma' |
        tr '\\n' ' ')"
}

# Is the machine this guest was promised the machine it got? Every CPUID
# feature is executed, and a page is written, sealed executable and run — the
# just-in-time compiler's cycle, which every browser depends on. This is the
# check that turns a whole class of hypervisor bug from "some application dies
# somewhere, in a different library each time" into one line naming the
# contract that was broken.
run_cpu_conformance() {
    guestcheck > /tmp/guestcheck.log 2>&1
    rc=\$?
    while read -r l; do say "\$l"; done < /tmp/guestcheck.log
    [ \$rc -eq 0 ] || say "guestcheck: a guest contract is broken — fix the hypervisor, not the app"
}

# Does this guest execute ordinary userspace correctly? Fork storms and thread
# churn are what a browser does constantly and what a hypervisor gets wrong
# subtly: a mishandled segment base or saved register leaves a fresh process
# dereferencing a low address, which reads as a null-pointer bug in whichever
# library happened to run first. Asking directly, before the browser, turns a
# three-minute ambiguous failure into a fifteen-second verdict.
run_stress_probe() {
    stress-ng --fork 4 --pthread 4 --timeout ${STRESS_S}s --metrics-brief \\
        > /tmp/stress.log 2>&1
    rc=\$?
    if [ \$rc -eq 0 ]; then
        say "stress: PASS — fork and thread churn survived ${STRESS_S}s"
    else
        say "stress: FAIL rc=\$rc — this guest miscomputes below the browser"
        grep -iE 'fail|error|signal' /tmp/stress.log | tail -4 |
            fold -w ${CONSOLE_COLS} | while read -r l; do say "stress: \$l"; done
    fi
}

# Can this image decode the icons its toolkit will ask for? GTK does not
# degrade when it cannot: it asserts and aborts the process, and the message
# blames an image format rather than the missing loader. The browser then dies
# before painting with no line that names a cause — which is exactly how this
# cost a day. Asking at boot turns it into one line, before anything depends
# on the answer.
report_icons() {
    say "icons: cache \$(wc -c < "\${GDK_PIXBUF_MODULE_FILE:-/dev/null}" 2>/dev/null || echo 0) bytes, svg loader \$(ls /usr/lib/gdk-pixbuf-2.0/*/loaders/ 2>/dev/null | grep -c svg)"
    if gdk-pixbuf-query-loaders 2>/dev/null | grep -q 'image/svg'; then
        say "icons: svg decodable"
    else
        say "icons: NO SVG LOADER — GTK will abort on its first icon"
    fi
}

# What the guest has left, and whether the kernel has killed anything for it.
# The first suspect whenever a browser dies here: this guest's whole system is
# in RAM (VIRT-004), so the tmpfs root is charged against the same budget the
# browser allocates from, and the two together are what the hypervisor sized.
report_memory() {
    say "mem \$1: \$(free -m | sed -n '2p' | tr -s ' ')"
    dmesg | grep -iE 'out of memory|oom-kill|killed process' | tail -3 |
        fold -w ${CONSOLE_COLS} | while read -r l; do
        say "oom: \$l"
    done
}

# The caches a package manager's install scripts normally build. This image is
# assembled unprivileged with --no-scripts, so NONE of them exist, and each one
# is load-bearing rather than an optimisation. They must run in the guest
# because each interrogates the very libraries and files it indexes.
#
# Nothing here is allowed to fail quietly. Every one of these was a silenced
# `2>/dev/null` before, and the one that was simply MISSING from the list —
# update-mime-database — is what killed the browser: without a compiled MIME
# database gdk-pixbuf cannot identify a file's type, reports "Unrecognized
# image file format" for a perfectly good icon, and GTK responds to a failed
# icon load by aborting the process. The browser died before painting, and the
# only clue was a warning that named the mime database in passing.
build_cache() {
    label=\$1; artifact=\$2
    shift 2
    if "\$@" > /tmp/cache.log 2>&1; then
        if [ -z "\$artifact" ] || [ -e "\$artifact" ]; then
            say "cache: \$label ok"
        else
            say "cache: \$label RAN BUT PRODUCED NOTHING at \$artifact"
        fi
    else
        say "cache: \$label FAILED rc=\$?"
        tail -2 /tmp/cache.log | fold -w ${CONSOLE_COLS} | while read -r l; do
            say "cache: \$l"
        done
    fi
}

# The MIME database: gdk-pixbuf asks it what a file IS before choosing a loader.
build_cache mime /usr/share/mime/mime.cache update-mime-database /usr/share/mime
# The pixbuf loaders, including the SVG one librsvg ships (spelled
# libpixbufloader_svg.so, with an underscore, unlike every built-in loader).
build_cache pixbuf "" gdk-pixbuf-query-loaders --update-cache
PIXBUF_CACHE=\$(find /usr/lib/gdk-pixbuf-2.0 -name loaders.cache 2>/dev/null | head -1)
# Name it explicitly rather than trusting the path compiled into the library.
[ -n "\$PIXBUF_CACHE" ] && export GDK_PIXBUF_MODULE_FILE="\$PIXBUF_CACHE"
# GTK reads its settings from GSettings and treats a missing schema as fatal.
build_cache schemas /usr/share/glib-2.0/schemas/gschemas.compiled \
    glib-compile-schemas /usr/share/glib-2.0/schemas
# A browser with no font cache renders nothing.
build_cache fonts "" fc-cache -f
# The icon theme index. GTK works without it by scanning directories, so this is
# the one entry here that is genuinely an optimisation.
for theme in /usr/share/icons/*/; do
    [ -f "\$theme/index.theme" ] && build_cache "icons \$(basename "\$theme")" "" \
        gtk-update-icon-cache -q -t -f "\$theme"
done

# dbus identifies the machine by this file and logs an error on every
# connection when it is missing; nothing persists here, so fresh each boot.
dbus-uuidgen > /etc/machine-id
cp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || {
    mkdir -p /var/lib/dbus && cp /etc/machine-id /var/lib/dbus/machine-id
}
say "asset caches built"

# Mesa: there is no GPU here, so the software rasteriser is not a fallback to
# be discovered, it is the configuration.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export XDG_RUNTIME_DIR=/run/user
export MOZ_ENABLE_WAYLAND=1
# A crash must announce itself on the console, not open a reporter window. The
# reporter is a second GTK program started at the worst possible moment, and
# when it fails it buries the failure that summoned it.
export MOZ_CRASHREPORTER_DISABLE=1
mkdir -p "\$XDG_RUNTIME_DIR"
chmod 700 "\$XDG_RUNTIME_DIR"

# The wire. The hypervisor bridges this NIC onto the machine's LAN, where a
# DHCP server answers — QEMU's slirp on the laptop, the real router on lemon.
# Backgrounded with a bounded retry so a guest with no bridge still boots to
# its browser (which then says, correctly, that it is offline); -b keeps
# retrying in the background once granted, covering a bridge that comes up
# after the guest does.
ip link set eth0 up 2>/dev/null || ifconfig eth0 up
udhcpc -i eth0 -b -t 10 -T 2 > /dev/console 2>&1 &
say "dhcp requested on eth0"

# seatd brokers /dev/input and /dev/dri for the compositor.
seatd -g root &
sleep 1
export LIBSEAT_BACKEND=seatd
say "seatd started"

# Firefox's own sandbox needs user namespaces and a process model this image
# does not have; the isolation that matters here is the virtual machine around
# it (weston autolaunches the browser — /usr/bin/kiosk-firefox — with a fresh
# profile, because nothing persists anyway).
mkdir -p /root/.mozilla/firefox/kudos
cp /usr/share/kudos/user.js /root/.mozilla/firefox/kudos/user.js

# Wait for the lease before the browser exists. Firefox resolves its start URL
# once, at launch; a lease that lands a second later leaves a network-error page
# on screen for a bridge that works, which is a whole boot cycle to tell apart
# from a bridge that does not. The wait is bounded and both outcomes are stated:
# the address it got, or that it is starting offline.
guest_ip() { ifconfig eth0 2>/dev/null | sed -n 's/.*inet addr:\\([0-9.]*\\).*/\\1/p'; }
waited=0
while [ -z "\$(guest_ip)" ] && [ \$waited -lt ${DHCP_WAIT_S} ]; do
    sleep 1
    waited=\$((waited + 1))
done
if [ -n "\$(guest_ip)" ]; then
    say "dhcp: eth0 is \$(guest_ip) after \${waited}s, dns \$(sed -n 's/^nameserver //p' /etc/resolv.conf | tr '\\n' ' ')"
else
    say "dhcp: NO LEASE after ${DHCP_WAIT_S}s — the browser starts offline"
fi

report_cpu
run_cpu_conformance
report_icons
report_memory "before the browser"
run_stress_probe

say "starting weston kiosk + firefox on ${FB_W}x${FB_H}"
# The compositor+browser log goes to a FILE first so nothing is lost to a
# console that folds and truncates, and is then STREAMED off the machine line by
# line. Streaming rather than dumping on exit, because the failure this image
# actually has does not exit the compositor: the browser's child processes die
# while weston lives on showing their last frame, and a report conditioned on
# the compositor exiting never fires at all.
weston --backend=drm-backend.so > /tmp/kiosk.log 2>&1 &
KIOSK_PID=\$!

say "$MARKER"

# With no autolaunch this guest exists to be driven by hand: say so, once, in
# the place the person driving it is already looking.
if [ "${AUTOSTART}" != "1" ]; then
    say "no autostart — run  kiosk-firefox  at this shell to start the browser"
fi

(
    tail -f /tmp/kiosk.log 2>/dev/null | fold -w ${CONSOLE_COLS} |
        while read -r l; do say "kiosk: \$l"; done
) &

# The death watch, over both processes that can end the picture. The compositor
# exiting and the browser exiting are different faults with different fixes, and
# each names itself; memory is reported at every check that matters because an
# exhausted guest does not announce a shortage — its allocations fail and its
# libraries dereference the failure, which reads as a null-pointer bug in
# whatever library happened to ask for memory first.
[ "${AUTOSTART}" = "1" ] && (
    # Wait for the browser to EXIST before watching for it to vanish. The
    # compositor runs the control client first and takes a moment to launch
    # anything at all, so a watch that starts counting immediately reports a
    # death that has not happened — which is worse than no report, because it
    # is read as evidence. "Never started" and "started, then died" are
    # different faults and each says so.
    appeared=0
    waited=0
    while [ \$waited -lt ${BROWSER_START_S} ]; do
        sleep 1
        waited=\$((waited + 1))
        if pgrep firefox-esr >/dev/null 2>&1; then appeared=1; break; fi
    done
    if [ \$appeared -eq 0 ]; then
        say "BROWSER-NEVER-STARTED within ${BROWSER_START_S}s"
        report_memory "browser never started"
    else
        say "browser up after \${waited}s"
        checks=0
        while true; do
            sleep ${WATCH_INTERVAL_S}
            checks=\$((checks + 1))
            if ! kill -0 \$KIOSK_PID 2>/dev/null; then
                say "KIOSK-EXITED after \$((checks * ${WATCH_INTERVAL_S}))s"
                report_memory "at compositor exit"
                break
            fi
            if ! pgrep firefox-esr >/dev/null 2>&1; then
                say "BROWSER-GONE after \$((checks * ${WATCH_INTERVAL_S}))s of running"
                report_memory "at browser exit"
                break
            fi
            [ \$((checks % ${MEMORY_EVERY_CHECKS})) -eq 0 ] && report_memory "browser up"
        done
    fi
) &

# Let the compositor's own start-up chatter land first, so the report is the
# last thing on a console that shows one screenful and does not scroll.
sleep ${REPORT_DELAY_S}
report_devices

# Anything the caller asked this boot to do, on a machine that is now fully up.
run_cmdline_script

# PID 1 must not exit, and the shell it holds open is what is left to diagnose
# with when the picture is wrong — so put it WHERE THE WINDOW IS LOOKING. This
# guest paints a real framebuffer, and kudos shows a guest's scanout once it
# does; a shell on the serial console alone is then running somewhere nobody can
# see. Keystrokes reach both the serial port and the virtio keyboard, so the
# framebuffer console is one a person can see AND type at. bash rather than
# busybox ash because this is a shell for a PERSON — history, tab completion and
# the editing keys are what make a guest investigable at all.
#
# setsid -c gives it the tty as its CONTROLLING terminal, which job control
# needs; without it bash says so on every start.
KUDOS_SHELL_TTY=/dev/tty1
[ -c "\$KUDOS_SHELL_TTY" ] || KUDOS_SHELL_TTY=/dev/console
# This image's setsid is busybox's, not util-linux's, and whether it takes -c
# depends on how that busybox was configured. Ask it once rather than assume:
# a shell that fails to start is a guest with no shell, which is the whole bug
# being fixed here.
KUDOS_SETSID=
setsid -c true 2>/dev/null && KUDOS_SETSID="setsid -c"
echo "kudos-guest: shell on \$KUDOS_SHELL_TTY" > /dev/console
while true; do
    \$KUDOS_SETSID /bin/bash --login <"\$KUDOS_SHELL_TTY" >"\$KUDOS_SHELL_TTY" 2>&1
    echo "kudos-guest: shell exited — starting another" > /dev/console
done
EOF
chmod +x "$ROOTFS/init"


    pack_and_record "$ROOTFS"
}

# ── zigserver: the compile factory as a guest ───────────────────────────────
# kudos carries no compiler (ARCH-012): the agent writes Zig and POSTs it to a
# factory that compiles it off-target into a .kudos image. This guest IS that
# factory — the same scripts/agent/factory.py the host runs, on the same pinned
# Zig, reached over the bridge (VIRT-027) at the address its lease gives it. Set
# `factory=<guest-ip>:8623` in AI.CFG and the loop closes inside one machine.
image_zigserver() {
    OUT="$ASSETS/zigserver"
    ROOTFS="$WORK/zigserver-rootfs"
    mkdir -p "$OUT"

    local marker="KUDOS-ZIGSERVER-UP"
    # The port the factory serves /compile on, spelled once here and once in the
    # kudos-side default; a port spelled two ways is a factory nobody reaches.
    local factory_port=8623
    # What one compile is allowed here, against the host default of 30s. This
    # guest holds its whole filesystem in a tmpfs and its first compile builds
    # compiler_rt from nothing, which measures at over a minute; a budget that
    # cuts that off reports "compile timed out" for source that is perfectly
    # good, which is the most misleading answer the factory can give.
    local build_timeout_s=180
    # The toolchain version, taken from the installer that pins it rather than
    # restated: the guest must compile with exactly the Zig this repo builds
    # with, or a module that builds on the host fails in the guest and nothing
    # says why.
    local zig_version
    zig_version="$(grep -m1 '^ZIG_VERSION=' "$ROOT/scripts/setup.sh" | cut -d= -f2)"
    [ -n "$zig_version" ] || {
        echo "build_guest(zigserver): scripts/setup.sh no longer states ZIG_VERSION" >&2
        exit 1
    }

    # Kernel: the shared guest fragment plus a network stack and the syscall
    # floor a multi-process Python service needs. ACPI comes with the same
    # reason as the browser image, and with the same caveat: kudos runs these
    # guests with `acpi=off` because it models no I/O APIC (see write_net_fragment).
    write_net_fragment
    # shellcheck disable=SC2086 # the assert list is a deliberate word-split
    build_kernel "$WORK/kudos_net_guest.config" $NET_GUEST_ASSERTS

    alpine_rootfs "$ROOTFS"
    # python3 runs the factory; binutils is the readelf it proves position
    # independence with; the Zig toolchain arrives below, not from a package,
    # because the version has to match this repo's exactly.
    apk_add "$ROOTFS" python3 binutils bash

    # This image's console is a getty, so root must be an account login will
    # actually open — Alpine ships it locked.
    usable_root "$ROOTFS"

    # The pinned toolchain, pruned to what a freestanding build actually reads.
    # The C and C++ support trees are more than half of a Zig install and none
    # of them is opened by a `-target x86_64-freestanding` compile: dropping
    # them halves the image the guest has to hold in RAM.
    local zig_tarball="zig-x86_64-linux-$zig_version.tar.xz"
    if [ ! -d "$WORK/zig-$zig_version" ]; then
        echo "build_guest(zigserver): fetching zig $zig_version ..."
        curl -fL --no-progress-meter -o "$WORK/$zig_tarball" \
            "https://ziglang.org/download/$zig_version/$zig_tarball"
        rm -rf "$WORK/zig-$zig_version.extracting"
        mkdir "$WORK/zig-$zig_version.extracting"
        tar xf "$WORK/$zig_tarball" --strip-components=1 -C "$WORK/zig-$zig_version.extracting"
        mv "$WORK/zig-$zig_version.extracting" "$WORK/zig-$zig_version"
    fi
    mkdir -p "$ROOTFS/opt/zig"
    cp "$WORK/zig-$zig_version/zig" "$ROOTFS/opt/zig/zig"
    cp -r "$WORK/zig-$zig_version/lib" "$ROOTFS/opt/zig/lib"
    rm -rf "$ROOTFS/opt/zig/lib"/{libc,libcxx,libcxxabi,libtsan,libunwind,include,docs}

    # The factory and the two things it reads: the harness it links every module
    # against, and the ABI header definition it stamps from. abi.zig is COPIED,
    # not restated — the factory parses the kernel's own file, so guest and
    # kernel cannot disagree about the format of a .kudos (ARCH-012). The paths
    # mirror the repo because factory.py finds abi.zig relative to itself.
    mkdir -p "$ROOTFS/kudos/scripts/agent" "$ROOTFS/kudos/src/kernel/loader"
    cp "$ROOT/scripts/agent/factory.py" "$ROOTFS/kudos/scripts/agent/factory.py"
    cp -r "$ROOT/scripts/agent/harness" "$ROOTFS/kudos/scripts/agent/harness"
    cp -r "$ROOT/scripts/agent/samples" "$ROOTFS/kudos/scripts/agent/samples"
    cp "$ROOT/src/kernel/loader/abi.zig" "$ROOTFS/kudos/src/kernel/loader/abi.zig"

    echo "kudos-zigserver" > "$ROOTFS/etc/hostname"
    printf 'console\nttyS0\ntty0\ntty1\n' > "$ROOTFS/etc/securetty"
    cat > "$ROOTFS/etc/motd" <<EOF
kudos zig compiler server — Alpine $ALPINE_MINIROOTFS_VERSION base, zig $zig_version, runs from RAM.
The factory serves /compile on port $factory_port; agent sources land in /workspace.
EOF

    write_udhcpc_script "$ROOTFS"

    # PID 1: mount, get an address, start the factory, then hand off to busybox
    # init for the respawning gettys. The factory is started under a supervisor
    # loop rather than once: a service that dies silently is a guest that looks
    # up and answers nothing, which is the hardest failure here to diagnose.
    cat > "$ROOTFS/init" <<EOF
#!/bin/sh
# kudos zig-server guest init (PID 1). The initramfs is the whole system;
# nothing is pivoted or persisted.
export PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm /run /workspace /tmp
chmod 1777 /tmp /dev/shm # sticky + world-writable, as every real system has them
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /dev/shm || mount -t tmpfs tmpfs /dev/shm
exec </dev/console >/dev/console 2>&1
hostname -F /etc/hostname
ip link set lo up

# Zig writes a build cache; point it somewhere bounded and say so, because in a
# RAM guest a cache is memory the compiler is taking from the compiler.
export ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache
export ZIG=/opt/zig/zig
export FACTORY_BUILD_TIMEOUT_S=$build_timeout_s

# The address is the whole point of this guest: without a lease nobody can POST
# to it, so the address is REPORTED, not assumed, and its absence is stated.
if [ -e /sys/class/net/eth0 ]; then
    udhcpc -i eth0 -b -s /etc/kudos/udhcpc.script
    n=0
    while [ \$n -lt 30 ]; do
        addr=\$(ip -4 -o addr show eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1)
        [ -n "\$addr" ] && break
        n=\$((n + 1))
        sleep 1
    done
    if [ -n "\$addr" ]; then
        echo "zigserver: listening on http://\$addr:$factory_port/compile"
        echo "zigserver: set  factory=\$addr:$factory_port  in AI.CFG"
    else
        echo "zigserver: no DHCP lease after 30s — the factory is up on port $factory_port,"
        echo "zigserver: but nothing can reach it until this guest has an address"
    fi
else
    echo "zigserver: no eth0 — this guest has no network adapter, so the factory"
    echo "zigserver: it runs can only be reached from inside the guest"
fi

# Supervise: a factory that exits takes the agent's only compiler with it, so
# say so on the console and start it again.
(
    while true; do
        python3 /kudos/scripts/agent/factory.py serve \\
            --host 0.0.0.0 --port $factory_port --workspace /workspace
        echo "zigserver: the factory exited (\$?) — restarting in 2s"
        sleep 2
    done
) &

# Warm the build cache with a compile of the sample app. The first compile after
# boot builds compiler_rt and half of std from source and takes over a minute;
# every one after it takes seconds. Doing that here means the wait lands where
# nobody is waiting, instead of on whoever asks first — and the console says
# when the compiler is actually quick, which is a thing worth knowing.
(
    if python3 /kudos/scripts/agent/factory.py compile \\
        /kudos/scripts/agent/samples/hello.zig -o /tmp/warm.kudos >/dev/null 2>&1; then
        echo "zigserver: build cache warm at \$(cut -d' ' -f1 /proc/uptime)s — compiles are quick from here"
    else
        echo "zigserver: the warm-up compile FAILED. The factory is up, but the"
        echo "zigserver: toolchain is not compiling; try it by hand with"
        echo "zigserver: python3 /kudos/scripts/agent/factory.py compile \\\\"
        echo "zigserver:     /kudos/scripts/agent/samples/hello.zig -o /tmp/t.kudos"
    fi
) &

echo "$marker"
exec /sbin/init
EOF
    chmod +x "$ROOTFS/init"

    cat > "$ROOTFS/etc/inittab" <<'EOF'
# busybox init: /init already did one-time setup; init only owns the consoles.
#
# A SHELL, not a getty. getty exists to hold a line open until someone logs in,
# and login exists to ask for a password — neither of which a throwaway RAM
# guest with no password has any use for. What it cost was the shell itself:
# getty needs the terminal to behave like a terminal before it will hand over,
# so on a console that is a mirrored serial port there was no prompt at all,
# only a getty respawning against a line it could not settle. Running the shell
# directly needs nothing from the line but bytes in and bytes out.
ttyS0::respawn:/bin/bash --login
tty1::respawn:/bin/bash --login
::ctrlaltdel:/sbin/reboot
::restart:/sbin/init
EOF

    pack_and_record "$ROOTFS"
}

# ── ubuntu: a minimal server userland ───────────────────────────────────────
# The ubuntu-base tarball is the server rootfs with no kernel and no init, which
# is exactly what an initramfs guest wants. It carries no DHCP client and no
# getty worth the name, so a static busybox supplies both — everything else is
# stock Ubuntu, apt included, ready to install into RAM once the bridge gives
# this guest a route.
image_ubuntu() {
    OUT="$ASSETS/ubuntu"
    ROOTFS="$WORK/ubuntu-rootfs"
    mkdir -p "$OUT"

    local marker="KUDOS-UBUNTU-UP"

    # The same kernel shape as the zig server: a network stack and the syscall
    # floor a glibc userland assumes.
    write_net_fragment
    # shellcheck disable=SC2086 # the assert list is a deliberate word-split
    build_kernel "$WORK/kudos_net_guest.config" $NET_GUEST_ASSERTS

    local base_tarball="ubuntu-base-$UBUNTU_BASE_VERSION-base-amd64.tar.gz"
    if [ ! -f "$WORK/$base_tarball" ]; then
        echo "build_guest(ubuntu): fetching $base_tarball ..."
        curl -fL --no-progress-meter -o "$WORK/$base_tarball" \
            "$UBUNTU_BASE_MIRROR/$UBUNTU_RELEASE/release/$base_tarball"
    fi
    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"
    # -p for the same reason as the Alpine base: without it a plain-user extract
    # drops every setuid bit Ubuntu ships (su, sudo, mount, passwd, ping …) and
    # the sticky bit on /tmp and /var/tmp, and the result is not Ubuntu server.
    tar xzpf "$WORK/$base_tarball" -C "$ROOTFS"

    # busybox: the DHCP client and the link configuration ubuntu-base has
    # neither of — it ships no dhcp client at all, and no iproute2, so without
    # these the adapter never even comes up. Installed under its own name with
    # only the applets this image calls linked, so nothing shadows Ubuntu's own
    # coreutils.
    build_busybox
    cp "$BUSYBOX" "$ROOTFS/bin/busybox"
    local applet
    for applet in udhcpc ip; do ln -sf busybox "$ROOTFS/bin/$applet"; done

    # The guest's half of the hypervisor's contracts, in the image with a REAL
    # dynamically-linked userland: the staged image proves them for static
    # binaries only, and a loader that relocates and re-protects its pages
    # exercises paths a static binary never reaches.
    $CC_STD -static -O1 -o "$ROOTFS/usr/bin/guestcheck" "$SCRIPT_DIR/guestcheck.c"

    echo "kudos-ubuntu" > "$ROOTFS/etc/hostname"
    usable_root "$ROOTFS"
    cat > "$ROOTFS/etc/motd" <<EOF
Ubuntu $UBUNTU_RELEASE server (minimal) — runs entirely from RAM, nothing persists a reboot.
apt works once this guest has a lease; installs land in RAM, so watch what you fetch.
EOF

    write_udhcpc_script "$ROOTFS"

    cat > "$ROOTFS/init" <<EOF
#!/bin/sh
# kudos minimal-Ubuntu guest init (PID 1). The initramfs is the whole system;
# nothing is pivoted or persisted.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm /run /tmp
# 1777, not mkdir's 0755: apt fetches as the `_apt` user and cannot otherwise
# write /tmp/apt.conf.XXXXXX, which makes signature checking fail and every
# repository report itself unsigned — "apt update" then refuses the lot.
chmod 1777 /tmp /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /dev/shm 2>/dev/null
# The SERIAL LINE BY NAME, not /dev/console. kudos mirrors ttyS0 into the VM
# window AND into the netdebug trace, which is the only copy of a guest's output
# that survives the window scrolling, the guest wedging, or nobody watching.
# /dev/console is whichever console the kernel decided was preferred, and when
# that decision goes the other way the userland's half of the boot is simply
# gone while the kernel's printk still arrives — indistinguishable from an init
# that never ran.
KUDOS_CON=/dev/ttyS0
[ -c "\$KUDOS_CON" ] || KUDOS_CON=/dev/console
exec <"\$KUDOS_CON" >"\$KUDOS_CON" 2>&1
hostname -F /etc/hostname
ip link set lo up 2>/dev/null

# The adapter is brought up HERE rather than left to the lease callback: with
# the link down every udhcpc socket open fails immediately, and its retry loop
# then spins on the console instead of backgrounding — a guest that never
# reaches its own login prompt because of a network it does not need. -t bounds
# the foreground attempts for the same reason: every wait states a budget.
if [ -e /sys/class/net/eth0 ]; then
    ip link set eth0 up
    udhcpc -i eth0 -b -t 3 -s /etc/kudos/udhcpc.script || true
fi

cat /etc/motd
echo "$marker"
/usr/bin/guestcheck

# The interactive shell goes WHERE THE WINDOW IS LOOKING. kudos shows a guest's
# framebuffer once the guest has painted one, and it feeds keystrokes to both the
# serial port and the virtio keyboard — so a shell on the framebuffer console is
# one a person can see AND type at, while the boot narration above stays on the
# serial line, which is the copy the netdebug trace keeps. A shell on the serial
# port alone is invisible the moment the guest brings up its display, which reads
# as a guest that never started one.
#
# setsid -c gives the shell the tty as its CONTROLLING terminal, which is what
# job control needs; without it bash says so on every start.
KUDOS_SHELL_TTY=/dev/tty1
[ -c "\$KUDOS_SHELL_TTY" ] || KUDOS_SHELL_TTY="\$KUDOS_CON"
echo "ubuntu: shell on \$KUDOS_SHELL_TTY"
# PID 1 must not exit: respawn the login shell instead, so a user who types
# exit gets another prompt rather than a kernel panic.
while true; do
    setsid -c /bin/bash --login <"\$KUDOS_SHELL_TTY" >"\$KUDOS_SHELL_TTY" 2>&1
    echo "ubuntu: shell exited — starting another"
done
EOF
    chmod +x "$ROOTFS/init"

    pack_and_record "$ROOTFS"
}

case "$IMAGE" in
staged) image_staged ;;
firefox) image_firefox ;;
zigserver) image_zigserver ;;
ubuntu) image_ubuntu ;;
*) usage ;;
esac
