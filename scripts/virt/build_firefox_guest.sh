#!/usr/bin/env bash
# build_firefox_guest.sh — produce the Linux guest that runs a real web browser
# inside a kudos VM window: a kernel with the graphical and input drivers, and
# an Alpine initramfs carrying Mesa's software renderer, a Wayland kiosk
# compositor, and Firefox.
#
# Runs on the host (this laptop / CI), NOT inside kudos, and entirely as a plain
# user — apk installs into the rootfs unprivileged and pack_initramfs.py owns
# root:root ownership and the /dev/console node.
#
# THE WHOLE SYSTEM LIVES IN RAM. A kudos guest has no disk (VIRT-004), so the
# initramfs IS the root filesystem: ~630 MiB unpacked, which Linux frees the
# compressed copy of once it has unpacked. The guest is sized for that in
# guestlist.zig, and the ceiling it must stay under is layout.zig's
# VIRTIO_MMIO_GPA (~3.9 GiB of guest RAM).
#
# HOW A BROWSER DRAWS HERE. There is no virgl and no GPU in the guest: Mesa
# falls back to llvmpipe, its software rasteriser, and the compositor puts the
# result in a virtio-gpu 2D resource that kudos textures into the VM window.
# Every frame is CPU-drawn and then copied once — correct, and slow in the way
# software rendering inside a hypervisor is slow.
#
# Usage: scripts/virt/build_firefox_guest.sh [linux-version]
# Requires: the build_guest.sh kernel toolchain (curl, make, gcc, flex, bison,
# bc, libelf-dev), network access, and ~4 GiB in assets/virt/build/.
set -euo pipefail

LINUX_VERSION="${1:-6.6.52}"
# The Alpine base, pinned exactly as build_ssh_guest.sh pins it: minirootfs
# releases stay downloadable forever, while packages track the branch's current
# index (Alpine deletes superseded .apks) and the SHA256SUMS record says what a
# given build actually produced.
ALPINE_BRANCH="v3.23"
ALPINE_MINIROOTFS_VERSION="3.23.5"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# What the kiosk opens with. The hypervisor bridges the guest's NIC onto the
# machine's wire (VIRT-027), so the default is a real website — the point of
# the exercise is a browser that BROWSES. The self-describing local page is
# still in the image at file:///usr/share/kudos/start.html for runs where the
# wire is deliberately absent.
START_URL="${START_URL:-https://example.com}"

# The scanout the compositor drives. Held at the ivirt scanout ceiling
# (iface/ivirt.zig FB_MAX_W/FB_MAX_H), because the device model refuses a larger
# mode and a guest that asks for one gets no display at all.
FB_W="${FB_W:-1600}"
FB_H="${FB_H:-900}"

# The marker /init prints once the browser has been launched. The QEMU test
# harness watches the serial console for it.
MARKER="KUDOS-FIREFOX-UP"

# How long /init waits for udev's coldplug to finish before starting the
# compositor anyway. Every wait states a budget: a guest whose devices never
# appear must reach its serial shell and say so, not hang in PID 1.
UDEV_SETTLE_S=30

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

CC_STD="gcc -std=gnu11"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$ROOT/assets/virt/firefox"
WORK="$ROOT/assets/virt/build"
ROOTFS="$WORK/firefox-rootfs"

mkdir -p "$OUT" "$WORK"

# --- 1. Kernel: the shared guest fragment, plus what a graphical multi-process
# userland needs. Three groups: the input drivers the browser is driven with,
# the syscall floor musl and a Wayland compositor assume, and networking (idle
# until a NIC bridge connects the guest, and cheap to carry until then).
cat > "$WORK/kudos_firefox_guest.config" <<'EOF'
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
CONFIG_NET=y
CONFIG_UNIX=y
CONFIG_INET=y
CONFIG_PACKET=y
CONFIG_NETDEVICES=y
CONFIG_NET_CORE=y
CONFIG_VIRTIO_NET=y
EOF

cd "$WORK"
KDIR="linux-$LINUX_VERSION"
if [ ! -d "$KDIR" ]; then
    # 130 MiB over a CDN that sometimes drops an HTTP/2 stream mid-transfer:
    # resume rather than restart, retry the transient failures, and force
    # HTTP/1.1, whose framing has no such failure mode. --no-progress-meter
    # because a per-second progress line in a build log is a hundred KiB of
    # noise around the one line that matters.
    echo "build_firefox_guest: fetching linux-$LINUX_VERSION (~130 MiB) ..."
    curl -fL --http1.1 --retry 5 --retry-delay 2 --retry-connrefused \
        --continue-at - --no-progress-meter \
        -o "linux-$LINUX_VERSION.tar.xz" \
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$LINUX_VERSION.tar.xz"
    # Extract to a scratch name and rename: an interrupted tar must not leave a
    # partial tree that a rerun would silently build from.
    rm -rf "$KDIR.extracting"
    mkdir "$KDIR.extracting"
    tar xf "linux-$LINUX_VERSION.tar.xz" --strip-components=1 -C "$KDIR.extracting"
    mv "$KDIR.extracting" "$KDIR"
fi
cd "$KDIR"
make tinyconfig
./scripts/kconfig/merge_config.sh -m .config "$SCRIPT_DIR/guest_kernel.config" "$WORK/kudos_firefox_guest.config"
make olddefconfig

# merge_config only WARNS when an option loses to an unmet dependency, and
# olddefconfig then silently settles it. Assert the settings that carry a
# milestone, so a config regression fails the build instead of the field.
for opt in VIRTIO_MMIO VIRTIO_MMIO_CMDLINE_DEVICES DRM_VIRTIO_GPU \
           SERIAL_8250_CONSOLE VIRTIO_INPUT INPUT_EVDEV UNIX SHMEM TMPFS \
           FUTEX MULTIUSER UNIX98_PTYS VIRTIO_NET INET; do
    grep -qx "CONFIG_$opt=y" .config || {
        echo "build_firefox_guest: CONFIG_$opt did not survive the config merge" >&2
        exit 1
    }
done

make CC="$CC_STD" HOSTCC="$CC_STD" -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$OUT/bzImage"

# --- 2. The Alpine base and a static apk to install into it with.
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
        echo "build_firefox_guest: no apk-tools-static in $ALPINE_BRANCH/main" >&2
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
# --no-scripts because package scripts want a chroot the build does not have;
# the minirootfs already carries the busybox symlink farm they would rebuild,
# and the caches they warm (fonts, icons) are rebuilt at first use instead.
"$WORK/apk.static" --root "$ROOTFS" --arch x86_64 \
    --repository "$ALPINE_MIRROR/$ALPINE_BRANCH/main" \
    --repository "$ALPINE_MIRROR/$ALPINE_BRANCH/community" \
    --no-cache --no-scripts --no-interactive \
    add mesa-dri-gallium mesa-egl mesa-gbm weston weston-backend-drm \
        xkeyboard-config seatd eudev font-dejavu \
        adwaita-icon-theme librsvg gsettings-desktop-schemas dbus firefox-esr

echo "kudos-firefox" > "$ROOTFS/etc/hostname"

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

[autolaunch]
path=/usr/bin/kiosk-firefox

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
exec dbus-run-session firefox-esr \\
    --no-remote --no-sandbox --kiosk \\
    --profile /root/.mozilla/firefox/kudos \\
    "$START_URL"
EOF
chmod +x "$ROOTFS/usr/bin/kiosk-firefox"

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

# The caches a package manager's install scripts normally build. This image is
# assembled unprivileged, with --no-scripts, so none of them exist — and each
# one is load-bearing rather than an optimisation: GTK aborts on an icon it
# cannot decode, and the loader that decodes it is found only through this
# cache. They are cheap, they are idempotent, and they must run in the guest
# because each one interrogates the very libraries it indexes.
gdk-pixbuf-query-loaders --update-cache 2>/dev/null
glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null
fc-cache -f 2>/dev/null
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
say "starting weston kiosk + firefox on ${FB_W}x${FB_H}"
# The compositor+browser log goes to a FILE, not the console: the console
# mirror folds and truncates, and the line that names a browser exit is
# routinely longer than one mirrored line. The watcher below owns reporting.
weston --backend=drm-backend.so > /tmp/kiosk.log 2>&1 &
KIOSK_PID=\$!

say "$MARKER"

# The death report. If the compositor exits, the last screenful of its log IS
# the diagnosis, and this is the only path that gets it off the machine. A
# subshell cannot wait on init's child, so it polls: liveness every couple of
# seconds is plenty for a death report.
(
    while kill -0 \$KIOSK_PID 2>/dev/null; do sleep 2; done
    say "KIOSK-EXITED"
    tail -40 /tmp/kiosk.log | fold -w ${CONSOLE_COLS} | while read -r l; do
        say "kiosk: \$l"
    done
    say "--- end of kiosk log ---"
) &

# Let the compositor's own start-up chatter land first, so the report is the
# last thing on a console that shows one screenful and does not scroll.
sleep ${REPORT_DELAY_S}
report_devices

# PID 1 must not exit: a shell on the serial console is what is left to
# diagnose with when the picture is wrong.
exec /bin/sh
EOF
chmod +x "$ROOTFS/init"

# --- 4. Pack. pack_initramfs.py owns root:root ownership, the sorted walk and
# the /dev/console node no unprivileged build tree can carry.
python3 "$SCRIPT_DIR/pack_initramfs.py" "$ROOTFS" "$OUT/initramfs.cpio.gz"

cd "$OUT"
sha256sum bzImage initramfs.cpio.gz > SHA256SUMS
UNPACKED_MB=$(du -sm "$ROOTFS" | cut -f1)
PACKED_MB=$(du -m initramfs.cpio.gz | cut -f1)
echo
echo "build_firefox_guest: built in $OUT"
echo "  bzImage           $(du -h bzImage | cut -f1)"
echo "  initramfs.cpio.gz ${PACKED_MB} MiB packed, ${UNPACKED_MB} MiB unpacked"
echo "  the guest needs RAM for the unpacked tree plus the browser's own"
echo "  working set — guestlist.zig sizes the catalog entry accordingly."
