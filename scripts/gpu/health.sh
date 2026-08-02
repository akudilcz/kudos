#!/bin/sh
# Check the physical RTX 4090's (10de:2684) health and, on request, reset it back
# to a healthy state after a kudos passthrough run.
#
# WHY THIS EXISTS
# ---------------
# A kudos --passthrough session boots the GSP, drives the display, then tears the
# GSP down and QEMU exits. The card is often left parked in D3hot (low-power) —
# MMIO looks dead until it is woken to D0, which makes a perfectly healthy card
# "feel" wedged. This script wakes it and resets it IN PLACE so it is usable again.
#
# IMPORTANT — this script NEVER rebinds the nvidia driver
# -------------------------------------------------------
# Writing to /sys/bus/pci/drivers/nvidia/{bind,unbind} runs the driver's GPU
# init/teardown SYNCHRONOUSLY inside that write. After an FLR it has been observed
# to spin forever in an unkillable R state, which then BLOCKS a clean reboot (only
# a forced `systemctl reboot --force` recovered the host). So this script only
# uses nvidia-smi when the host has ALREADY bound the card to nvidia, and resets
# via PCI FLR otherwise. Moving the card between vfio-pci and nvidia is left to the
# dedicated, deliberate scripts/gpu/bind.sh / scripts/gpu/unbind.sh.
#
# THE ONE THING SOFTWARE CANNOT FIX (the transient hardware wedge)
# ---------------------------------------------------------------------------
# A genuine silicon/firmware wedge (the Xid 62 `RmInitAdapter failed 0x62...` that
# once hit kudos, nouveau AND the NVIDIA driver simultaneously on this card) is NOT
# cleared by ANY software reset — not FLR, not PCI bus reset, not D3hot, not
# vfio remove+rescan, not Secondary Bus Reset. This slot has no ACPI _PR3, so there
# is no software D3cold either. Only a **full host power-off** (rails drop) clears
# it. If `reset` runs and the card still cannot init, this script says so plainly
# rather than pretending it fixed it.
#
# USAGE (run as root):
#   sudo scripts/gpu/health.sh            # check-only (non-destructive)
#   sudo scripts/gpu/health.sh check      # same as above
#   sudo scripts/gpu/health.sh reset      # wake D0, then reset in place:
#                                         #   on nvidia -> nvidia-smi -r
#                                         #   otherwise  -> PCI FLR (no rebind)
#
# Grounded in: kernel Documentation/PCI (sysfs `reset` = FLR), nvidia-smi(1)
# (`-r` = GPU reset).
set -e

# Card identity comes from the one shared definition.
. "$(dirname "$0")/env.sh"
gpu_require_card || exit 1
VGA="$GPU_VGA_BDF"
SLOT="$GPU_VGA_SLOT"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (sudo $0)" >&2
    exit 1
fi

# --- which driver currently owns the VGA function -----------------------------
# `readlink` on .../driver gives .../drivers/<name>; strip to the leaf. Prints
# "none" when the card is unbound. (Guarded so a driver-less card never yields a
# garbage token like the literal string "driver".)
current_driver() {
    link="$(readlink "/sys/bus/pci/devices/$VGA/driver" 2>/dev/null || true)"
    if [ -z "$link" ]; then echo none; else echo "${link##*/}"; fi
}

# --- report the current state of the card (non-destructive) ------------------
# Prints driver binding, PCI power state, link status and config-space sanity so a
# human can tell "asleep/vfio-parked" (normal, fixable) from "off the bus" (wedge).
report_state() {
    echo "== 4090 state =="
    if [ ! -e "/sys/bus/pci/devices/$VGA" ]; then
        echo "  DEVICE ABSENT from PCI ($VGA) — card has dropped off the bus."
        echo "  This is the hard-wedge signature; only a host power-off recovers it."
        return
    fi
    driver="$(current_driver)"
    pstate="$(cat "/sys/bus/pci/devices/$VGA/power_state" 2>/dev/null || echo '?')"
    echo "  driver in use : $driver"
    echo "  power state   : $pstate"
    # A responsive card returns its real vendor id (10de); a wedged one reads ffff.
    vendor="$(cat "/sys/bus/pci/devices/$VGA/vendor" 2>/dev/null || echo '?')"
    echo "  config vendor : $vendor  (want 0x10de; 0xffff = not responding)"
    lspci -nnk -s "$SLOT" | sed 's/^/  /'
    echo "  link status   :"
    lspci -vvs "$SLOT" 2>/dev/null | grep -iE "LnkSta:|LnkCap:|DevSta:" | sed 's/^[[:space:]]*/    /' || true
}

# --- wake the card from D3hot to D0 ------------------------------------------
# A D3hot card ignores MMIO. Writing "on" to the sysfs power/control forces the
# kernel to keep it in D0; a bus-master enable poke via setpci confirms D0.
wake_to_d0() {
    echo "== waking $VGA to D0 =="
    echo on > "/sys/bus/pci/devices/$VGA/power/control" 2>/dev/null || true
    # Bit 2 (bus master) of the command register can only be set in D0; setting it
    # transitions the function to D0 if it was in D3hot.
    setpci -s "$SLOT" COMMAND=0x02:0x02 2>/dev/null || true
    pstate="$(cat "/sys/bus/pci/devices/$VGA/power_state" 2>/dev/null || echo '?')"
    echo "  power state now: $pstate"
}

# --- Function-Level Reset via sysfs (works while bound to ANY driver) --------
flr() {
    if [ -e "/sys/bus/pci/devices/$VGA/reset" ]; then
        echo "== FLR $VGA (sysfs reset) =="
        echo 1 > "/sys/bus/pci/devices/$VGA/reset" && echo "  FLR issued" || echo "  FLR failed"
    else
        echo "== FLR unavailable (no sysfs reset node) — skipping =="
    fi
}

# --- nvidia-smi health readout (only when the card is already on nvidia) -------
# CRITICAL: this script NEVER binds/unbinds the nvidia driver via sysfs. Writing
# to .../drivers/nvidia/{bind,unbind} runs the driver's GPU init/teardown
# SYNCHRONOUSLY inside the write, and after an FLR that has been observed to spin
# forever in an unkillable R state — which then blocks a clean reboot. So we only
# talk to nvidia-smi when the host has ALREADY bound the card to nvidia; moving
# the card between vfio and nvidia is left to the dedicated, deliberate
# scripts/gpu/bind.sh / scripts/gpu/unbind.sh (run by a human who wants exactly that).
nvidia_smi_report() {
    echo "== nvidia-smi health readout =="
    nvidia-smi -i "$SLOT" || nvidia-smi || echo "  nvidia-smi could not read the card."
}

# --- nvidia-smi GPU reset (soft, in-driver — no bind churn) --------------------
nvidia_smi_reset() {
    echo "== nvidia-smi -r (soft GPU reset) =="
    nvidia-smi -r -i "$SLOT" || nvidia-smi -r || echo "  nvidia-smi -r reported an error"
}

case "${1:-check}" in
    check)
        report_state
        driver="$(current_driver)"
        if [ "$driver" = "nvidia" ]; then
            nvidia_smi_report
        else
            echo "(card is on '$driver'; nvidia-smi only works when it is on the"
            echo " nvidia driver. 'reset' below resets it in place without rebinding.)"
        fi
        ;;
    reset)
        # Reset the card IN PLACE — never change its driver binding (that is the
        # step that hung the host). The mechanism depends on who owns it:
        #   - nvidia : nvidia-smi -r (soft, in-driver reset)
        #   - vfio / none / anything else : sysfs FLR (works regardless of driver,
        #     never spins). Wake to D0 first so the reset targets a live function.
        echo "### 4090 reset (in place — no driver rebind) ###"
        report_state
        wake_to_d0
        driver="$(current_driver)"
        if [ "$driver" = "nvidia" ]; then
            nvidia_smi_report
            nvidia_smi_reset
        else
            echo "== card is on '$driver' — resetting via PCI FLR (no nvidia rebind) =="
            flr
            echo "  If the card still looks stuck AND kudos/nouveau/nvidia all fail to"
            echo "  init it, that is the hard silicon wedge — only a full host"
            echo "  power-off clears it. No software reset will."
        fi
        echo "### done — final state ###"
        report_state
        ;;
    *)
        echo "usage: $0 {check|reset}" >&2
        exit 1
        ;;
esac
