#!/bin/sh
# Boot a kudos variant in QEMU. Headless by default (monitor
# socket); pass --gui to open a live, interactive QEMU window instead. In every
# mode a QEMU window opens locally. kudos has NO serial port: the boot trace leaves
# the machine over netdebug (UDP :9514) — read it with the netdebug MCP or socat.
# Everything runs in RAM; the ISO is only GRUB's boot medium (no disk driver).
#
# Usage: scripts/vm/run.sh [--auto | --gui | --passthrough] [--smp]
#                          [--no-stick] [--soft-display]
#   --auto         pick by environment: over SSH ($SSH_CONNECTION set) run the
#                  full crash-safe 4090 passthrough (scripts/vm/passthrough.sh
#                  --manage-vfio); locally open the interactive GUI window. This is
#                  what `make start` uses.
#   (default)      single-core kudos.iso, 1 vCPU  -- the simple default path
#   --smp          multi-core  kudos-smp.iso, 4 vCPUs (cores 0..3 -> terminals #0..#3)
#   --passthrough  hand the PHYSICAL RTX 4090 (10de:2684) to the guest via VFIO,
#                  so kudos' M9 GSP bring-up runs against the real card. A 4090
#         CANNOT be emulated — passthrough is the
#                  only way QEMU "has a 4090". REQUIRES the card bound to vfio-pci
#                  first (scripts/gpu/bind.sh) — which DETACHES it from the host
#                  display. Run from a headless/SSH session or with another GPU
#                  driving your screen.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# --auto: choose the run mode from the environment (what `make start` invokes).
#  - Over SSH ($SSH_CONNECTION set): no local display, so run the real 4090 via
#    the full crash-safe passthrough orchestration (binds vfio, resets, runs,
#    unbinds on any exit). That wrapper builds + self-elevates itself, so we hand
#    off entirely and do NOT fall through to the QEMU invocation below.
#  - Locally: rewrite --auto to --gui and continue (interactive window), keeping
#    any other args (e.g. --smp) intact.
# Resolved here, before anything else. Only meaningful as the sole mode flag.
case " $* " in
    *" --auto "*)
        if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]; then
            echo "run.sh --auto: SSH session detected -> full 4090 passthrough" >&2
            # Forward every arg except --auto (e.g. --smp) so the passthrough path
            # boots the same variant the caller asked for.
            passargs=""
            for a in "$@"; do
                [ "$a" = "--auto" ] && continue
                passargs="$passargs $a"
            done
            # shellcheck disable=SC2086  # deliberate word-split of the rebuilt list
            exec scripts/vm/passthrough.sh --manage-vfio $passargs
        fi
        echo "run.sh --auto: local session -> interactive GUI window" >&2
        # Rebuild the arg list with --auto replaced by --gui, then re-exec. A
        # passthrough-only `--build-opts VALUE` pair is meaningless here — drop
        # both tokens.
        newargs=""
        skip_next=""
        for a in "$@"; do
            if [ -n "$skip_next" ]; then skip_next=""; continue; fi
            case "$a" in
                --auto) a="--gui" ;;
                --build-opts) skip_next="1"; continue ;;
            esac
            newargs="$newargs $a"
        done
        # Build the image this window can actually SHOW. There is no GPU inside
        # QEMU (the 4090 reaches a guest only by passthrough, which is the other
        # branch), and a default image publishes no draw device without one — it
        # renders to a black screen. -Dsoft-display is the build whose rasteriser
        # delivers into the firmware framebuffer, so the local window is always
        # built from it. The SSH branch builds its own image in passthrough.sh;
        # this is the same guarantee for the branch that does not go there.
        smp_iso=""
        case " $newargs " in *" --smp "*) smp_iso="-smp" ;; esac
        # The compiler guest rides IN the image when its pair is built
        # (assets/virt/zigserver/): `kudos vm 3` then boots with no image
        # server and no fetch, so a fresh window compiles out of the box.
        # Without the pair the flag is skipped, not failed — the shell and
        # the catalog's HTTP path still work.
        bake=""
        [ -f assets/virt/zigserver/bzImage ] && [ -f assets/virt/zigserver/initramfs.cpio.gz ] \
            && bake="-Dbake=zigserver"
        zig build "iso$smp_iso" -Dsoft-display $bake \
            -p "${BUILD_DIR:-build}" --cache-dir "${BUILD_DIR:-build}/.zig-cache"
        # shellcheck disable=SC2086  # deliberate word-split of the rebuilt list
        exec "$0" $newargs
        ;;
esac

# All build/generated artifacts live under $BUILD_DIR (default build/; single
# source) — the ISOs and their staging dirs included.
BUILD_DIR="${BUILD_DIR:-build}"

# Card identity comes from the one shared definition.
. scripts/gpu/env.sh

# Variant + display selection. Bare = single-core; --smp boots the SMP image
# with 4 vCPUs so AP bring-up and per-core terminal pinning are exercised.
ISO="$BUILD_DIR/kudos.iso"
SMP="1"
# Headless display: a VNC server (no client needs to connect) rather than
# `-display none`. QEMU 10.2 stops refreshing the framebuffer surface under
# `-display none`, so `screendump` returns an all-black frame even though the
# guest is rendering correctly (verified: the guest's framebuffer memory holds
# the right pixels; only the captured surface is stale). A VNC backend keeps the
# scanout surface live so screenshots work. Bound to localhost, no password.
DISPLAY_ARG="vnc=127.0.0.1:0"
# Pointer device differs by display mode:
#  - GUI: usb-TABLET (absolute). It maps the host pointer 1:1 with no grab and no
#    speed/sensitivity issues. A relative usb-mouse here feels slow and can't
#    reach the far corners (1 USB count = 1 px, plus QEMU/Wayland relative-motion
#    quirks), so it is NOT attached in the GUI — one pointer only, else they fight.
#  - headless: usb-MOUSE (relative), which QMP injection drives in tests and which
#    matches the real-hardware boot-mouse path.
POINTER="usb-mouse"
# VFIO passthrough of the physical 4090. Both PCI functions of the card
# (01:00.0 VGA + 01:00.1 audio) share one IOMMU group and MUST pass through
# together. Empty unless --passthrough is given.
PASSTHROUGH=""
# The emulated QEMU VGA device makes the passed-through 4090's GSP PMU fault during
# init (verified by A/B test: nouveau itself fails identically — 42 PMU error
# prints, Xid 62, INIT_DONE res:0x55 — the moment a `-device VGA` is added, and
# succeeds without it). So under --passthrough we drop the VGA device entirely and
# boot kudos headless; the GPU subsystem is the display path being
# brought up. Non-passthrough runs keep the emulated VGA for the framebuffer.
VGA="-device VGA,vgamem_mb=32,xres=2560,yres=1440"
# The screen size a CPU rasteriser can actually drive: 1280x800 is a third of the
# 2560x1440 default's pixel count, and is the size the desktop's own host-rendered
# screenshot test uses. Taken by --gui and --soft-display alike.
SOFT_VGA="-device VGA,vgamem_mb=32,xres=1280,yres=800"
# --no-tail: exec QEMU directly instead of backgrounding it under a live
# background wrapper. The caller (passthrough.sh, the integration harness) owns
# QEMU's lifetime and runs its own netdebug capture, so the extra
# tail + wrapper shell would only get in the way (and, orphaned, could leak the
# VM). Explicit flag — no env-var back channel.
NO_TAIL=""
# --no-stick / --require-stick: boot without the USB stick, or refuse to boot
# without it. See the stick block below.
NO_STICK=""
REQUIRE_STICK=""
for arg in "$@"; do
    case "$arg" in
        # --gui is the interactive window, and everything it can show is drawn by
        # the CPU (no GPU reaches a guest except by passthrough, which has its own
        # display), so it takes the soft-display geometry too — a window built at
        # the 2560x1440 default would ask the rasteriser for 3.7 Mpixel a frame.
        --gui) DISPLAY_ARG="gtk,gl=off,zoom-to-fit=on"; VGA="$SOFT_VGA"; POINTER="usb-tablet" ;;
        --no-tail) NO_TAIL="1" ;;
        # --soft-display: the same geometry for a HEADLESS soft-rasteriser run.
        --soft-display) VGA="$SOFT_VGA"; POINTER="usb-tablet" ;;
        # SMP_CORES env overrides the vCPU count (like MEM_GB): the default 4
        # exercises AP bring-up; the kernel itself accepts up to acpi.MAX_CPUS.
        --smp) ISO="$BUILD_DIR/kudos-smp.iso"; SMP="${SMP_CORES:-4}" ;;
        --passthrough)
            # x-vga=on makes the passed-through 4090 the legacy-VGA owner, and is
            # REQUIRED: the card's GSP PMU faults during init (Xid 62, INIT_DONE
            # res:0x55) whenever another VGA device competes for that ownership.
            # Paired with -vga none (set below) so no emulated primary VGA exists to
            # compete. Only an emulated *VGA* breaks GSP init — the emulated e1000
            # attached below does not — so netdebug still reaches the host from a
            # passthrough run. boot2_passthrough.py asserts the result (GSP_INIT_DONE).
            # Emulated e1000 on a TAP netdev so kudos' netdebug broadcast
            # (0.0.0.0 -> 255.255.255.255:9514) reaches the host MCP on :9514:
            # slirp/-net none never delivers a guest broadcast to a host socket, but
            # a tap is a real L2 endpoint on the host kernel's stack, which
            # decapsulates the frame and hands the UDP payload to the MCP's plain
            # :9514 socket. The tap
            # (kudoslog) is created/torn down by passthrough.sh; script=no keeps QEMU
            # from touching host config (it runs as root here). netdebug.zig and the
            # MCP server are unchanged.
            PASSTHROUGH="-netdev tap,id=netdebug0,ifname=kudoslog,script=no,downscript=no -device e1000,netdev=netdebug0 -device vfio-pci,host=$GPU_VGA_SLOT,multifunction=on,x-vga=on -device vfio-pci,host=$GPU_AUD_SLOT"
            # Host keyboard + mouse straight into the guest (interactive kudos
            # desktop on the GPU monitors). input-linux GRABS the host devices
            # for the run (double-Ctrl toggles the grab); events route to the
            # emulated USB HID devices, which kudos' xhci/HID stack handles.
            # Pass the PHYSICAL input devices into the guest (usb-host): kudos
            # enumerates the real G Pro mouse + Keychron keyboard — identical
            # descriptors to a bare-metal boot, but with a netdebug capture, so
            # enumeration bugs are debuggable here and the fix carries over.
            # The host loses the devices for the run (they return on exit).
            PASSTHROUGH="$PASSTHROUGH -device usb-host,bus=xhci.0,vendorid=0x046d,productid=0xc088"
            PASSTHROUGH="$PASSTHROUGH -device usb-host,bus=xhci.0,vendorid=0x3434,productid=0xd030"
            VGA="-vga none"
            ;;
        --no-stick) NO_STICK=1 ;;
        --require-stick) REQUIRE_STICK=1 ;;
        *) echo "usage: $0 [--gui] [--smp] [--passthrough] [--no-tail] [--no-stick] [--require-stick] [--soft-display]" >&2; exit 2 ;;
    esac
done

# GTK (gl=off) renders the framebuffer correctly under Wayland. zoom-to-fit=on
# lets you freely resize the window: GTK scales the guest framebuffer to fill it,
# so the display is as large (or small) as you drag it — the readable-on-a-big-
# monitor path. Unlike SDL's fullscreen surface (which rescales the usb-tablet's
# absolute coords by window size and flings the cursor into a corner), GTK keeps
# the absolute-pointer mapping correct under its own scaling, so the tablet stays
# 1:1 regardless of zoom.
#
# The kernel requests the firmware's NATIVE mode (width=0/height=0 in its
# multiboot2 header, src/kernel/boot/boot.asm). Under QEMU that resolves to the VGA device's
# advertised mode: we give it vgamem_mb=32 (1440p32 is ~14.7 MB, so 16 is the
# floor; 32 is headroom) and xres/yres=2560x1440 so its EDID advertises 1440p as
# the native ceiling, which the kernel then receives. GTK scales that to the
# window. bare `-vga std` can't set xres/yres.

# Passthrough needs KVM (/dev/kvm) + VFIO, both root-owned on a stock host. Rather
# than fail with an opaque "Could not access KVM kernel module: Permission denied",
# self-elevate via sudo (preserving the invoking user in SUDO_USER so we can hand
# Non-passthrough runs stay unprivileged.
if [ -n "$PASSTHROUGH" ] && [ "$(id -u)" -ne 0 ]; then
    echo "run.sh --passthrough needs root (KVM + VFIO); re-running under sudo…" >&2
    exec sudo SUDO_USER="$(id -un)" "$0" "$@"
fi

# Passthrough with a firmware-less ISO boots to "GSP firmware not staged; skipping
# boot" and never reaches the display path — a silent dead end. Fail loud instead,
# with the one command that fixes it.
if [ -n "$PASSTHROUGH" ] && ! grep -q "module2 /boot/fw/gsp_rm.bin" "$BUILD_DIR/isodir-kudos/boot/grub/grub.cfg" 2>/dev/null; then
    echo "ERROR: $ISO has no GSP firmware staged — passthrough would boot to a dead end." >&2
    echo "  Rebuild with firmware (auto-detects /lib/firmware/nvidia/ad102/gsp):" >&2
    echo "    zig build iso" >&2
    echo "  or point at a specific tree:  GSP_FW_DIR=/path/to/gsp zig build iso" >&2
    exit 1
fi

# Clear the previous run's sockets. A passthrough run creates them as ROOT, so a run
# that wedged or was killed hard can leave a stale root-owned socket a later non-root
# actor cannot rm — QEMU then fails to bind. Remove robustly: rm as ourselves, and
# escalate to sudo if it is root-owned.
for f in /tmp/mon.sock /tmp/qmp.sock; do
    [ -e "$f" ] || continue
    rm -f "$f" 2>/dev/null && continue
    sudo rm -f "$f" 2>/dev/null && continue
    echo "run.sh: cannot remove stale $f even with sudo — clear it and retry:" >&2
    echo "        sudo rm -f $f" >&2
    exit 1
done
# Input is USB HID over xHCI, matching the real target (which has no PS/2). This
# exercises the src/drivers/usb/xhci.zig enumeration + HID path on every run instead of
# silently falling back to QEMU's default PS/2 devices.
#
# -smp gives the SMP kernel its Application Processors; the single-core kernel
# boots fine with -smp 1 (only the BSP runs) so the flag is always passed.
# 64 GiB of guest RAM: enough to exercise the PMM's full managed range (it now
# manages up to 64 GiB, src/kernel/memory/pmm.zig MAX_ADDR) and to give the GSP/GPU DMA
# path real headroom. boot.asm identity-maps 512 GiB via 1 GiB pages, so all of
# it is addressable. The real target has 128 GiB.
# Peripherals (NIC + USB HID) are dropped under --passthrough to keep the machine
# minimal (matching the nouveau test harness). Non-passthrough runs keep them.
# N0_HOSTFWD (optional, e.g. ",hostfwd=udp:127.0.0.1:9515-:9515") appends port
# forwards to the slirp NIC — the first NIC, the one kudos' net stack binds — so
# a harness on the host can reach an in-guest UDP service (boot-3's KMR1
# injection). Empty by default: the QEMU arguments are unchanged unless set.
PERIPH="-netdev user,id=n0${N0_HOSTFWD:-} -device e1000,netdev=n0 -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device $POINTER,bus=xhci.0"
MACHINE=""
# THE stick: the physical 1 TB device (gpu/env.sh USB_STICK_VID/PID), passed
# through whole via usb-host on EVERY run — no emulated image, no generator.
# Every boot exercises the full real chain: xhci bulk + BOT probe + capacity
# whitelist + GPT/FAT32 → /usbdisk, against real flash. QEMU claims the device
# whole, so it must not be mounted on the host: try a polite unmount (GNOME
# auto-remounts it whenever the desktop is up), then fail loud if it is still
# held — a mounted stick yields EBUSY in QEMU and a confusing enumeration
# failure in kudos.
#
# A machine with no stick still runs kudos. The stick lives in the GPU target, so
# a developer machine has none, and a run that only needs the kernel (the desktop,
# a guest VM, a shell command, a netdebug trace) must not be impossible there:
# with no stick present the boot proceeds WITHOUT one. kudos itself already
# tolerates the absence — it mounts no /usbdisk and says so — but the loss is real
# and is stated on every such run: no /usbdisk, no boot-log ring, no on-device
# screenshots, and none of the USB mass-storage path is exercised.
#
# --no-stick asks for that boot explicitly (skipping the probe entirely), and
# --require-stick is its opposite: the stick is MANDATORY and its absence is an
# error. Every suite that ASSERTS against the stick's contents passes
# --require-stick, so a missing stick fails that suite loudly instead of quietly
# costing it the coverage it exists to provide.
stick_mounted() {
    [ -n "$(lsblk -no MOUNTPOINT /dev/disk/by-label/KUDOSUSB 2>/dev/null)" ]
}
no_stick_notice() {
    echo "run.sh: booting with NO /usbdisk (no boot-log ring, no stick captures," >&2
    echo "        and the USB mass-storage path is not exercised on this run)" >&2
}
NO_STICK="${NO_STICK:-}"
if [ -z "$NO_STICK" ] && stick_mounted; then
    udisksctl unmount -b /dev/disk/by-label/KUDOSUSB >/dev/null 2>&1 || true
fi
if [ -n "$NO_STICK" ]; then
    no_stick_notice
    USBDISK=""
elif stick_mounted; then
    echo "run.sh: the USB stick (label KUDOSUSB) is MOUNTED and would not unmount —" >&2
    echo "  close whatever is using it, or: udisksctl unmount -b /dev/disk/by-label/KUDOSUSB" >&2
    exit 1
elif lsusb -d "$USB_STICK_VID:$USB_STICK_PID" >/dev/null 2>&1; then
    USBDISK="-device usb-host,bus=xhci.0,vendorid=0x$USB_STICK_VID,productid=0x$USB_STICK_PID"
elif [ -n "$REQUIRE_STICK" ]; then
    echo "run.sh: the USB stick ($USB_STICK_VID:$USB_STICK_PID) is not plugged in, and this run" >&2
    echo "  REQUIRES it (--require-stick): the suite asserts against its contents." >&2
    exit 1
else
    echo "run.sh: no USB stick ($USB_STICK_VID:$USB_STICK_PID) on this machine." >&2
    no_stick_notice
    USBDISK=""
fi
PERIPH="$PERIPH $USBDISK"
if [ -n "$PASSTHROUGH" ]; then
    # Keep USB HID (controller + kbd + mouse) for the interactive GPU desktop; the
    # e1000-on-tap NIC comes from $PASSTHROUGH (for netdebug). There is no emulated
    # VGA — the one device PROVEN to break the 4090's GSP init. Input reaches these
    # devices via the input-linux host-evdev grab configured above.
    PERIPH="-device qemu-xhci,id=xhci $USBDISK"
    # graphics=off tells QEMU/SeaBIOS there is no display, suppressing the legacy
    # VGA setup that otherwise competes with the passed-through 4090 for legacy-VGA
    # ownership and makes its GSP PMU fault during init.
    MACHINE="-machine pc,graphics=off"
fi

# -boot order=d: ALWAYS boot the ISO. Without it SeaBIOS tries the emulated
# usb-storage stick first (no bootloader there) and the guest never boots.
EXTRA_NETDEV="${EXTRA_NETDEV:-}"
# Guest RAM, sized from the HOST's RAM so the same command works on a 128 GB
# target and a 16 GB laptop: half of physical, clamped to [8, 64]. The ceiling is
# what the PMM manages (64 GiB, src/kernel/memory/pmm.zig MAX_ADDR) and the floor
# is the least kudos boots in; half leaves the host its own working set, since
# QEMU's RAM is demand-faulted and a desktop kudos touches only a fraction of it.
# MEM_GB overrides for a run that wants a specific size.
host_gb="$(awk '/^MemTotal:/ {printf "%d", $2/1048576}' /proc/meminfo)"
auto_gb=$((host_gb / 2))
[ "$auto_gb" -gt 64 ] && auto_gb=64
[ "$auto_gb" -lt 8 ] && auto_gb=8
MEM_GB="${MEM_GB:-$auto_gb}"
QEMU="qemu-system-x86_64 \
    -cdrom $ISO \
    -boot order=d \
    -m ${MEM_GB}G \
    -smp $SMP \
    -enable-kvm \
    -cpu host \
    $MACHINE \
    $VGA \
    $PERIPH \
    $PASSTHROUGH \
    -display $DISPLAY_ARG \
    $EXTRA_NETDEV \
    -monitor unix:/tmp/mon.sock,server,nowait \
    -qmp unix:/tmp/qmp.sock,server,nowait \
    -no-reboot -no-shutdown"

if [ -n "$NO_TAIL" ]; then
    # shellcheck disable=SC2086  # deliberate word-split of the assembled arg list
    exec $QEMU
fi

# QEMU runs in the BACKGROUND (not exec'd) so this shell can install a trap and
# `wait` on it — that way a signal to run.sh (e.g. the integration harness's kill, or Ctrl-C)
# interrupts the wait and runs cleanup, tearing down BOTH QEMU and the tail. If we
# exec'd or foregrounded QEMU, a kill of run.sh would orphan the QEMU child.
# One cleanup for every exit path: kill QEMU + the live tail, and on an elevated
QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "run.sh: kudos has no serial port — read the boot trace over netdebug (UDP :9514):"
echo "        the netdebug MCP, or:  socat -u udp-recv:9514 -"
# shellcheck disable=SC2086  # deliberate word-split of the assembled arg list
$QEMU &
QEMU_PID=$!
wait "$QEMU_PID"

