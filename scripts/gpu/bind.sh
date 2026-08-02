#!/bin/sh
# Bind the physical RTX 4090 (10de:2684) + its audio function (10de:22ba) to
# vfio-pci so QEMU can pass the real card through to a kudos guest
# (scripts/vm/run.sh --passthrough). A 4090 cannot be emulated — passthrough is the
# only way QEMU "has a 4090".
#
# !!! THIS DETACHES THE 4090 FROM THE HOST. If it is driving your display, your
# !!! screen/console GOES DARK the moment it binds. Run only when:
# !!!   - you are on SSH from another machine, OR
# !!!   - the host is at multi-user.target with no GPU console you need, OR
# !!!   - a second GPU drives your display.
# !!! Reverse with scripts/gpu/unbind.sh (or reboot).
#
# Both functions of the card share one IOMMU group and MUST move together.
# Grounded in: kernel Documentation/driver-api/vfio.rst; Arch/PCI passthrough.
#
# Run as root.  Usage: sudo scripts/gpu/bind.sh
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

# Refuse to run if a display manager is still up — binding now would kill it.
if systemctl is-active --quiet display-manager 2>/dev/null; then
    echo "REFUSING: a display-manager is active — binding the 4090 now would" >&2
    echo "kill your display. Stop it first (sudo systemctl isolate multi-user.target)" >&2
    echo "or boot to multi-user.target, ideally over SSH. See header." >&2
    exit 1
fi

# The DM service going inactive is NOT the card being free: the GNOME session
# and nvidia-drm release the device nodes ASYNCHRONOUSLY after `isolate`
# returns, and binding vfio-pci while a dying compositor still held a modeset
# hangs the whole HOST — hard enough that only a power cycle recovers it.
# Wait until NOTHING holds the GPU device nodes;
# fail loud if they never free — something is pinning the card, and binding
# under it is how the host dies.
waited=0
while fuser -s /dev/nvidia* /dev/dri/card* /dev/dri/renderD* 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -gt 60 ]; then
        echo "REFUSING: processes still hold the GPU device nodes after 30s:" >&2
        fuser -v /dev/nvidia* /dev/dri/card* /dev/dri/renderD* 2>&1 | sed 's/^/  /' >&2
        exit 1
    fi
    sleep 0.5
done

modprobe vfio-pci

# Tell vfio-pci to claim these device IDs.
echo "$GPU_VGA_ID" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
echo "$GPU_AUD_ID" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true

# Unbind from the current driver (nvidia/nouveau/vfio) and rebind to vfio-pci.
for dev in "$VGA" "$AUD"; do
    if [ -e "/sys/bus/pci/devices/$dev/driver" ]; then
        echo "$dev" > "/sys/bus/pci/devices/$dev/driver/unbind" 2>/dev/null || true
    fi
    echo "vfio-pci" > "/sys/bus/pci/devices/$dev/driver_override"
    echo "$dev" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
done

# VERIFY the bind actually took — the writes above tolerate transient errors, so
# a silent failure here would surface later as an inexplicable QEMU/VFIO error
# (or worse). Fail loud now instead.
for dev in "$VGA" "$AUD"; do
    drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$dev/driver" 2>/dev/null)" 2>/dev/null || echo none)"
    if [ "$drv" != "vfio-pci" ]; then
        echo "FAIL: $dev is bound to '$drv', not vfio-pci — bind did not take" >&2
        exit 1
    fi
done

echo "bound 4090 ($VGA + $AUD) to vfio-pci:"
lspci -nnk -s "$GPU_SLOT" | sed 's/^/  /'
echo "now: scripts/vm/run.sh --passthrough"
