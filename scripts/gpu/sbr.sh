#!/bin/sh
# Last-resort recovery for a GSP-wedged RTX 4090 (Xid 62 / RmInitAdapter failed
# 0x62): a PCIe SECONDARY BUS RESET (SBR / "hot reset") via the card's UPSTREAM
# BRIDGE. This is STRONGER than the Function-Level Reset scripts/gpu/unbind.sh issues on
# the device itself — when kudos leaves the GSP microcontroller halted on a dirty
# exit, an FLR often cannot clear it but an SBR sometimes can, WITHOUT a host
# power-off. Grounded in: alexforencich.com/wiki/en/pcie/hot-reset-linux,
# NVIDIA Xid catalog (Xid 62 = GSP/PMU halt).
#
# HONEST CAVEAT: a genuinely halted GSP sometimes clears ONLY with a full PSU
# power-drop (not a reboot — power must actually drop). SBR is the documented
# "try this before rebooting" step; if it does not recover the card, power-cycle.
#
# WHAT IT DOES (all functions of the card move together — one IOMMU group):
#   1. stop the display-manager (it must let go of the 4090)
#   2. detach + remove both PCI functions
#   3. toggle the upstream bridge's Secondary Bus Reset bit (BRIDGE_CONTROL 0x40)
#   4. rescan the bus so nvidia re-binds on device appearance
#   5. report whether the card came back (nvidia-smi)
#
# Run as root.  Usage: sudo scripts/gpu/sbr.sh
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

# The device must exist to reset it.
if [ ! -e "/sys/bus/pci/devices/$VGA" ]; then
    echo "gpu-sbr: $VGA not present — nothing to reset" >&2
    exit 1
fi

# Find the UPSTREAM BRIDGE port (the SBR is issued on the bridge, not the device):
# the device's parent in the sysfs PCI topology.
PORT="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$VGA")")")"
case "$PORT" in
    0000:*) : ;; # looks like a PCI address
    *)
        echo "gpu-sbr: could not resolve upstream bridge for $VGA (got '$PORT')" >&2
        exit 1
        ;;
esac
echo "gpu-sbr: 4090 $VGA is behind bridge $PORT"

# 1. Stop the display-manager so nothing is scanning out of the card during reset.
if systemctl is-active --quiet display-manager 2>/dev/null; then
    echo "gpu-sbr: stopping display-manager…"
    systemctl isolate multi-user.target
fi

# 2. Detach both functions from whatever driver holds them, then remove the nodes
#    (SBR requires the attached drivers gone; children/audio first, then VGA).
for dev in "$AUD" "$VGA"; do
    if [ -e "/sys/bus/pci/devices/$dev/driver" ]; then
        echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind" 2>/dev/null || true
    fi
    echo "" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true
done
for dev in "$AUD" "$VGA"; do
    if [ -e "/sys/bus/pci/devices/$dev/remove" ]; then
        echo "gpu-sbr: removing $dev"
        echo 1 > "/sys/bus/pci/devices/$dev/remove" 2>/dev/null || true
    fi
done
sleep 1

# 3. Secondary Bus Reset on the bridge: set BRIDGE_CONTROL bit 0x40, brief hold,
#    then restore the saved value. This resets everything below the bridge (our
#    single-card IOMMU group).
BC="$(setpci -s "$PORT" BRIDGE_CONTROL)"
echo "gpu-sbr: BRIDGE_CONTROL was 0x$BC — asserting Secondary Bus Reset…"
setpci -s "$PORT" BRIDGE_CONTROL="$(printf '%04x' $(( 0x$BC | 0x40 )))"
sleep 0.05
setpci -s "$PORT" BRIDGE_CONTROL="$BC"
echo "gpu-sbr: reset deasserted; waiting for the link to retrain…"
sleep 1

# 4. Re-enumerate so nvidia binds on device appearance.
echo "gpu-sbr: rescanning the PCI bus…"
echo 1 > /sys/bus/pci/rescan
sleep 3

# 5. Report.
echo "gpu-sbr: binding now:"
lspci -nnk -s "$GPU_SLOT" | sed 's/^/  /'

if command -v nvidia-smi >/dev/null 2>&1; then
    echo "gpu-sbr: nvidia-smi readout —"
    if nvidia-smi >/dev/null 2>&1; then
        nvidia-smi | sed 's/^/  /'
        echo "gpu-sbr: SUCCESS — the 4090 is back. Restore the desktop: sudo systemctl isolate graphical.target"
        exit 0
    else
        echo "  nvidia-smi still cannot see the card." >&2
        echo "gpu-sbr: SBR did NOT clear the wedge. This is a genuinely halted GSP" >&2
        echo "  (Xid 62) — only a full host POWER-OFF (power must drop; a reboot is not" >&2
        echo "  enough) will recover it." >&2
        exit 2
    fi
fi
echo "gpu-sbr: (nvidia-smi not installed — check the binding above by hand)"
