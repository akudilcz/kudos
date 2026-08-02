#!/bin/sh
# Single source of truth for the passthrough GPU's PCI identity
# Every script that names the
# card sources this file; no script may hardcode a BDF, device id, slot, or VFIO
# group number of its own. POSIX sh, safe to source from sh and bash alike.
#
# WHAT the card is, is fixed: kudos' GPU driver targets the RTX 4090 (AD102) and
# no other device (src/drivers/gpu/gpu.zig RTX_4090_DEVICE).
GPU_VGA_ID="10de 2684"      # vfio-pci new_id format
GPU_AUD_ID="10de 22ba"      # vfio-pci new_id format

# WHERE it sits is per-machine, so it is FOUND, not assumed: ask lspci for the
# device id above. The two PCI functions (VGA + HD audio) share one IOMMU group
# and always move together, so the audio function is the VGA function's slot with
# .1 in place of .0. Export GPU_VGA_BDF to override (a machine with two 4090s, or
# lspci absent). When the card is not in this machine every value below is empty:
# the scripts that need it say so, and the ones that do not — run.sh sourcing this
# file for the USB stick identity — carry on.
if [ -z "${GPU_VGA_BDF:-}" ]; then
    GPU_VGA_BDF="$(lspci -Dn -d "$(echo "$GPU_VGA_ID" | tr ' ' ':')" 2>/dev/null \
                   | awk 'NR==1 {print $1}')"
fi
GPU_AUD_BDF="${GPU_AUD_BDF:-${GPU_VGA_BDF%.0}${GPU_VGA_BDF:+.1}}"
GPU_VGA_SLOT="${GPU_VGA_BDF#0000:}"   # short form for `lspci -s` / nvidia-smi -i / QEMU host=
GPU_AUD_SLOT="${GPU_AUD_BDF#0000:}"   # short form for QEMU host=
GPU_SLOT="${GPU_VGA_SLOT%.0}"         # short form for `lspci -s` (matches both functions)

# Say it once, here, rather than leaving every GPU script to fail on an empty
# slot. Callers that need the card run this first.
gpu_require_card() {
    [ -n "$GPU_VGA_BDF" ] && return 0
    echo "gpu-env: no RTX 4090 [${GPU_VGA_ID% *}:${GPU_VGA_ID#* }] in this machine." >&2
    echo "  kudos' GPU path is that card and no other. Set GPU_VGA_BDF to override." >&2
    return 1
}

# The VFIO group number is MACHINE-SPECIFIC (a function of slot + IOMMU
# topology) — it must be derived from sysfs, never hardcoded. Prints the group
# number; fails loudly if the device has no IOMMU group (IOMMU disabled, or the
# BDF above no longer matches the hardware).
gpu_vfio_group() {
    _g="/sys/bus/pci/devices/$GPU_VGA_BDF/iommu_group"
    if [ ! -e "$_g" ]; then
        echo "gpu-env: $GPU_VGA_BDF has no IOMMU group — IOMMU off or wrong BDF" >&2
        return 1
    fi
    basename "$(readlink -f "$_g")"
}

# THE kudos storage device: the USB stick a QEMU run passes through whole
# (usb-host), no emulated image. Its FAT32 data partition, label KUDOSUSB, holds
# hello.txt + the model corpus (scripts/tests/usbdisk.py provision writes them).
# The default is the reference machine's stick (Phison MS70, 1 TB); point these at
# YOUR stick — `lsusb` prints the pair — and nothing else needs to change.
USB_STICK_VID="${USB_STICK_VID:-13fe}"
USB_STICK_PID="${USB_STICK_PID:-6500}"
