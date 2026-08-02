#!/bin/sh
# Reverse scripts/gpu/bind.sh: release the RTX 4090 + audio function from
# vfio-pci and let the host's normal driver (nvidia/nouveau) reclaim them, so the
# card drives the host display again. Run after a passthrough QEMU session exits.
#
# A reboot also fully resets this; this script avoids the reboot when the host's
# graphics stack can re-grab the card live.
#
# Run as root.  Usage: sudo scripts/gpu/unbind.sh
set -e

# Card identity comes from the one shared definition.
. "$(dirname "$0")/env.sh"
gpu_require_card || exit 1
VGA="$GPU_VGA_BDF"
AUD="$GPU_AUD_BDF"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (sudo $0)" >&2
    exit 1
fi

# Serialize (un)binds of THIS card. Two concurrent resets of the same device is
# one way to manufacture the PCIe reset_lock↔device_lock AB-BA deadlock
# (the PCIe-port-service deadlock); the recurring trigger was a
# passthrough.sh cleanup unbind overlapping a `make stop` restore. A per-device
# lock makes that impossible by construction. Blocks (not -n) so a legitimately
# serialized second caller waits rather than erroring — but never two at once.
exec 9>/run/lock/kudos-vfio-01_00.lock
flock 9

# Current driver of a PCI function, or empty if driverless. Must gate on the
# symlink EXISTING: `readlink -f` on an absent .../driver link resolves the
# literal path and basename yields the bogus string "driver", which would make the
# detach loop below act on a driverless card.
cur_drv() { [ -L "/sys/bus/pci/devices/$1/driver" ] && basename "$(readlink -f "/sys/bus/pci/devices/$1/driver")"; }

# CRITICAL — never FLR a card that a LIVE driver is still bound to. The FLR resets
# the device out from under nvidia mid-RPC: the very next GSP_RM_CONTROL times out
# (Xid 119), the driver declares "GPU Reset Required" (Xid 154) and hangs its
# modeset kthread in nv_drm_atomic_commit (Flip event timeout) → the card wedges
# and only a reboot recovers. This is the reproducible `make stop`-wedges-the-GPU
# bug. It happens whenever nvidia has re-grabbed the card between a
# `make start` exit and this unbind. So: FIRST detach every function from whatever
# driver holds it (nvidia OR vfio-pci) and clear the override, THEN reset the now-
# quiescent, driverless card. Order is unbind-all → FLR → rebind.
for dev in "$VGA" "$AUD"; do
    d="$(cur_drv "$dev")"
    if [ -n "$d" ]; then
        echo "detaching $dev from '$d' before reset…"
        echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind" 2>/dev/null || true
    fi
    echo "" > "/sys/bus/pci/devices/$dev/driver_override"
done
# Let the driver's ->remove() settle (nvidia tears down its device state) before
# the reset, so the FLR lands on a fully released device.
sleep 1

# Reset the now-driverless card before handing it to the host. kudos does a clean
# GSP teardown only on a typed `shutdown`; a passthrough run ended by killing QEMU
# leaves GSP-RM resident and the display engine live, so nvidia would inherit a
# dirty card (nvidia-smi: "No supported GPUs were found"). A Function-Level Reset
# on the released device clears that residual state. FLR does NOT clear a genuine
# silicon wedge — only a host power-off does.
if [ -e "/sys/bus/pci/devices/$VGA/reset" ]; then
    echo "resetting 4090 (FLR) before release…"
    echo 1 > "/sys/bus/pci/devices/$VGA/reset" 2>/dev/null && echo "  FLR issued" || echo "  FLR failed (continuing)"
else
    echo "  no sysfs reset node — skipping FLR (card may need a power-off if wedged)"
fi

# Now REBIND the native driver. Clearing driver_override only makes the device
# ELIGIBLE — nothing binds it. `echo 1 > .../rescan` does NOT help: rescan only
# probes ABSENT devices, and these nodes still exist, so it is a no-op for them —
# the card is left driverless (nvidia-smi: "No supported GPUs were found"). Two
# robust triggers, escalating:
#   1. drivers_probe — ask the kernel to match a driver to the (present) device.
#      Asynchronous match, so it avoids the synchronous `.../drivers/nvidia/bind`
#      write that runs GPU init inside the write and has hung unkillably post-FLR
#      (see health.sh).
#   2. if that doesn't take, REMOVE the node + rescan the bus: nvidia auto-binds
#      on device *appearance* (the reliable path when a stale node blocks a match).
# Then verify each function landed on a real driver and say so loudly.
bound() { [ -L "/sys/bus/pci/devices/$1/driver" ]; }

for dev in "$VGA" "$AUD"; do
    bound "$dev" && continue
    echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
done
sleep 2

if ! bound "$VGA"; then
    echo "vfio-unbind: drivers_probe did not bind — removing + rescanning the bus…"
    # Remove children (audio) before the VGA function, then one bus rescan.
    for dev in "$AUD" "$VGA"; do
        [ -e "/sys/bus/pci/devices/$dev/remove" ] && echo 1 > "/sys/bus/pci/devices/$dev/remove" 2>/dev/null || true
    done
    sleep 1
    echo 1 > /sys/bus/pci/rescan
    sleep 3
fi

echo "released 4090 from vfio-pci; current binding:"
lspci -nnk -s "$GPU_SLOT" | sed 's/^/  /'

# Verify + fail loud: a driverless card means the desktop will NOT come back.
if bound "$VGA"; then
    echo "vfio-unbind: OK — $GPU_VGA_SLOT now on '$(cur_drv "$VGA")'"
else
    echo "vfio-unbind: WARNING — $GPU_VGA_SLOT is STILL DRIVERLESS after probe+rescan." >&2
    echo "  The host GUI will not return. Try:  sudo modprobe -r nvidia_drm nvidia_modeset nvidia && sudo modprobe nvidia_drm" >&2
    echo "  or reboot the machine. (A genuine silicon wedge needs a full power-off.)" >&2
fi
echo "if the host GUI does not return, reboot or: sudo systemctl isolate graphical.target"
