#!/bin/sh
# "Put my machine back to normal" — the recovery button (`make stop`). Undoes a
# passthrough session and returns the desktop machine to its ordinary state:
#   1. kill any stuck kudos QEMU + free the vfio group (kill-qemu.sh).
#   2. release the 4090 from vfio-pci back to the nvidia driver (scripts/gpu/unbind.sh,
#      which FLRs the card first).
#   3. if the card still cannot init (GSP wedged — Xid 62 after a dirty kudos
#      exit; nvidia-smi fails), ESCALATE to a PCIe Secondary Bus Reset via the
#      upstream bridge (scripts/gpu/sbr.sh) — stronger than the device FLR. This is the
#      last software step before a power-off.
#   4. restart the display-manager so the Linux desktop returns on the 4090's
#      monitors (the desktop runs ON the 4090; `make start` stopped it to pass the
#      card through).
#
# Safe to run anytime and idempotent: if nothing is stuck it is a no-op; if the DM
# is already up it stays up. Use it after `make start` when you are done, or to
# recover if a passthrough run crashed and left the card on vfio / the monitors
# blank.
#
# Run as root.  Usage: sudo scripts/gpu/restore.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (sudo $0)" >&2
    exit 1
fi

echo "restore: stopping any kudos QEMU + freeing the vfio group…"
scripts/vm/kill-qemu.sh || true

# Stop the display-manager BEFORE releasing the card. If nvidia has re-grabbed the
# 4090 and X/Wayland is scanning out of it, vfio-unbind's driver-detach + FLR would
# race a live modeset — nvidia hangs in nv_drm_atomic_commit and wedges the card
# (the PCIe-port-service deadlock / FLR-on-live-driver). Stopping the DM
# first makes the card idle so the detach+reset is clean. Idempotent: a no-op if
# the DM is already down (the usual case straight after a `make start`). The DM is
# restarted at the end once the card is healthy again.
if systemctl is-active --quiet display-manager 2>/dev/null; then
    echo "restore: stopping display-manager so the card is idle before reset…"
    systemctl isolate multi-user.target
    sleep 1
fi

echo "restore: releasing the 4090 back to nvidia…"
scripts/gpu/unbind.sh || true

# Verify the card actually initializes. A GSP wedge (Xid 62 from a dirty kudos
# exit) survives the FLR vfio-unbind does: the driver binds but nvidia-smi fails.
# In that case escalate to a Secondary Bus Reset (stronger) before giving up.
if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
        echo "restore: 4090 healthy (nvidia-smi OK)"
    else
        echo "restore: 4090 bound but NOT initializing (likely GSP wedge / Xid 62) —"
        echo "restore: escalating to a PCIe Secondary Bus Reset…"
        scripts/gpu/sbr.sh || true
        # gpu-sbr stops the DM; whether it succeeded or not, step 4 below brings
        # the desktop back if the card recovered. If gpu-sbr also failed, only a
        # host power-off will clear it (it says so on its own).
        if nvidia-smi >/dev/null 2>&1; then
            echo "restore: recovered via SBR (nvidia-smi OK)"
        else
            echo "restore: SBR did not recover the card — a full host POWER-OFF is" >&2
            echo "restore: required (power must drop; a reboot is not enough)." >&2
        fi
    fi
fi

echo "restore: restarting the display-manager (Linux desktop returns)…"
systemctl isolate graphical.target

echo "restore: done — the desktop should be back on the 4090's monitors."
