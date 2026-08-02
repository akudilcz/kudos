#!/bin/sh
# Turn this machine into a headless kudos TEST RIG: stop the desktop, wait for
# the GPU to be truly free, bind it to vfio-pci. After this, passthrough test
# runs (make test-boot-2-qemu / scripts/tests/run_passthrough.sh) boot and kill
# QEMU freely WITHOUT ever touching the display-manager or the binding: those two
# transitions hang the host if they run inside a test loop. Reverse with
# `make stop` (scripts/gpu/restore.sh) when you want the desktop back.
#
# !!! THIS TAKES THE WHOLE MACHINE: monitors go dark and stay dark, local
# !!! keyboard/mouse do nothing on the host. Control continues ONLY via SSH or
# !!! a pre-existing tmux/console session. If you are reading this in a GUI
# !!! terminal, that terminal (and everything in the GUI session) DIES when the
# !!! display-manager stops — run from SSH, or accept the session loss.
#
# Self-elevating (root needed for systemctl + vfio). The DM stop kills the
# caller's own GUI session if invoked from one, so the actual work runs under
# `systemd-run` (a transient SYSTEM unit) — it survives the session suicide and
# completes the rig regardless of where it was launched from.
#
# Usage: scripts/gpu/rig.sh [--take-display]
#   --take-display  explicit consent when invoked non-interactively (an agent,
#                   a script) — same contract as passthrough.sh: no silent path
#                   to taking the display.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

. scripts/gpu/env.sh
gpu_require_card || exit 1

TAKE_DISPLAY=0
INNER=0
for a in "$@"; do
    case "$a" in
        --take-display) TAKE_DISPLAY=1 ;;
        --inner) INNER=1 ;;  # internal: we ARE the transient unit; do the work
        *) echo "usage: $0 [--take-display]" >&2; exit 2 ;;
    esac
done

# ── the actual rig sequence (runs inside the transient unit) ────────────────
if [ "$INNER" = "1" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "rig.sh --inner must run as root" >&2
        exit 1
    fi
    # Refuse if a kudos QEMU is somehow running already.
    if pgrep -f "qemu-system-x86_64" >/dev/null 2>&1; then
        echo "rig: REFUSING — a QEMU is already running; stop it first" >&2
        exit 1
    fi
    echo "rig: stopping the display-manager (monitors will go dark) ..."
    # `systemctl stop display-manager`, NOT `isolate multi-user.target`: isolate
    # stops every unit not wanted by the target — INCLUDING this transient unit,
    # which isolate TERM-killed 151 ms in, before the bind ever ran (first rig
    # attempt). Stopping just the DM ends the GUI session identically; bind.sh's
    # device-node wait below absorbs the asynchronous release either way.
    systemctl stop display-manager
    # gpu/bind.sh does the rest: waits for the GPU device nodes to be truly
    # free (the GNOME/nvidia-drm release is ASYNC after the stop returns, and
    # binding under it hangs the host), binds both functions, verifies the bind.
    "$ROOT/scripts/gpu/bind.sh"
    echo "rig: READY — card on vfio-pci, desktop down."
    echo "rig: run tests with make test-boot-2-qemu; restore the desktop with make stop."
    exit 0
fi

# ── outer wrapper: consent gate, then hand off to a transient unit ──────────
if ! [ -t 0 ] && ! [ -t 1 ] && [ "$TAKE_DISPLAY" != "1" ]; then
    echo "REFUSING to rig from a non-interactive shell: this stops the" >&2
    echo "display-manager and darkens the machine. Run from a terminal, or" >&2
    echo "pass --take-display to consent explicitly." >&2
    echo "Reverse with: make stop  (sudo scripts/gpu/restore.sh)" >&2
    exit 4
fi

# Already rigged? (card on vfio-pci and no DM) — succeed idempotently.
drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU_VGA_BDF/driver" 2>/dev/null)" 2>/dev/null || echo none)"
if [ "$drv" = "vfio-pci" ] && ! systemctl is-active --quiet display-manager 2>/dev/null; then
    echo "rig: already rigged (card on vfio-pci, no display-manager) — nothing to do"
    exit 0
fi

echo "rig: handing off to a transient system unit (survives this session dying) ..."
# --wait blocks until the unit finishes — from SSH you see it complete; from a
# GUI terminal this shell dies with the session, but the unit runs to the end.
sudo systemd-run --unit=kudos-rig --collect --wait \
    "$ROOT/scripts/gpu/rig.sh" --inner
