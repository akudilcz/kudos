#!/usr/bin/env bash
# Reclaim the physical USB stick after a QEMU run: the guest's usb-host claim
# detaches the host block device, and the host does not always re-probe it on
# release — a sysfs soft-replug (deauthorize, reauthorize) brings it back.
# Exits 0 with /dev/disk/by-label/KUDOSUSB present, 1 if it never reappears.
# Shared by run_model_sweep.sh and shot.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/gpu/env.sh"

STICK=/dev/disk/by-label/KUDOSUSB
if [ ! -e "$STICK" ]; then
    for d in /sys/bus/usb/devices/*/idVendor; do
        v=$(cat "$d" 2>/dev/null); pfile="${d%idVendor}idProduct"
        p=$(cat "$pfile" 2>/dev/null)
        if [ "$v" = "$USB_STICK_VID" ] && [ "$p" = "$USB_STICK_PID" ]; then
            dev="${d%/idVendor}"
            echo 0 | sudo tee "$dev/authorized" >/dev/null; sleep 1
            echo 1 | sudo tee "$dev/authorized" >/dev/null; sleep 4
            break
        fi
    done
fi
[ -e "$STICK" ] || { echo "stick_reclaim: stick did not reappear" >&2; exit 1; }
