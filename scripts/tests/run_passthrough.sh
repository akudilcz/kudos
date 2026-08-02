#!/bin/sh
# Boot-2 integration run — the real-4090 passthrough track (GPU + desktop + timing).
#
# REQUIRES THE MACHINE TO BE RIGGED FIRST (`make rig`, ideally from SSH): card
# already on vfio-pci, display-manager down. A test run then never touches the
# display-manager or the binding — the two host-lethal transitions simply do
# not occur on the test path. This runner:
#   1. captures the netdebug UDP:9514 stream to build/logs/ (persistent — /tmp
#      is tmpfs and a host power-cycle destroys the evidence exactly when it
#      matters most);
#   2. launches passthrough.sh in PRE-BOUND mode (no --manage-vfio: it neither
#      stops the DM nor unbinds on exit), which builds the -Dtest-hooks
#      -Dflip-sample ISO and boots the 4090;
#   3. drives boot2_passthrough.py against the capture + KMR1 (:9515);
#   4. tears down the GUEST only (graceful kill-qemu: KMR1 shutdown → GSP
#      teardown → poweroff), then waits for passthrough.sh's own trap. The
#      machine STAYS RIGGED for the next run; `make stop` restores the desktop.
#
# Usage: scripts/tests/run_passthrough.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

. scripts/gpu/env.sh

LOGDIR="$ROOT/build/logs"
mkdir -p "$LOGDIR"
CAPTURE="$LOGDIR/boot2-netdebug.log"
# Wire-level USB ground truth: usb-host routes the real mouse/keyboard through the
# host's usbfs, so the host kernel's usbmon sees every URB QEMU exchanges with them
# — the descriptors read during enumeration and every report streamed after. This is
# the guest-independent oracle for a HID enumeration/decode bug (e.g. which endpoint
# a report actually arrives on, and its true bytes), captured with ZERO kudos-side
# instrumentation. Bus 0 = all buses. Best-effort: a missing usbmon never fails the run.
USBMON_CAPTURE="$LOGDIR/boot2-usbmon.log"

# Single instance: a second concurrent run would fight over :9514, the KMR1
# socket, and the GPU itself. flock makes it fail loud instead.
LOCK=/tmp/kudos-passthrough-suite.lock
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "run_passthrough: FAIL — another passthrough-suite run holds $LOCK" >&2
    exit 1
fi

# RIG PRECONDITION — fail loud, never rig implicitly (rigging takes the whole
# machine; that decision belongs to a human-initiated `make rig`).
drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU_VGA_BDF/driver" 2>/dev/null)" 2>/dev/null || echo none)"
if [ "$drv" != "vfio-pci" ]; then
    echo "run_passthrough: FAIL — the 4090 is bound to '$drv', not vfio-pci." >&2
    echo "  Rig the machine first (takes the display; run from SSH):  make rig" >&2
    exit 1
fi
if systemctl is-active --quiet display-manager 2>/dev/null; then
    echo "run_passthrough: FAIL — a display-manager is active but the card is on" >&2
    echo "  vfio-pci?! Inconsistent state; sort it out with make stop / make rig." >&2
    exit 1
fi

command -v socat >/dev/null 2>&1 || {
    echo "run_passthrough: socat is required to capture netdebug :9514 (apt install socat)" >&2
    exit 1
}

# The netdebug MCP server, if running, owns :9514 exclusively — our socat capture
# would then get nothing. Refuse loudly rather than silently reading an empty log.
if ss -lun 2>/dev/null | grep -q ':9514 '; then
    echo "run_passthrough: something already holds UDP :9514 (the kudos-netdebug MCP?)." >&2
    echo "  Stop it first — this run needs to capture :9514 itself." >&2
    exit 1
fi

# Teardown = the GUEST only, strictly SEQUENTIAL — concurrent kill-qemu and
# unbind paths hang the host:
#   1. stop the capture (harmless),
#   2. stop the guest gracefully exactly once (kill-qemu.sh: KMR1 `shutdown`
#      → GSP teardown → poweroff; hard kill only as last resort),
#   3. WAIT for passthrough.sh's own trap to finish (pre-bound mode: it cleans
#      the tap/dnsmasq but does NOT unbind — the machine stays rigged).
# No restore.sh here: the desktop comes back only when a human runs `make stop`.
cleanup() {
    [ -n "${CAP_PID:-}" ] && kill "$CAP_PID" 2>/dev/null || true
    [ -n "${USBMON_PID:-}" ] && sudo kill "$USBMON_PID" 2>/dev/null || true
    echo "run_passthrough: stopping the guest gracefully (kill-qemu.sh) ..."
    sudo scripts/vm/kill-qemu.sh || true
    if [ -n "${PT_PID:-}" ]; then
        kill "$PT_PID" 2>/dev/null || true
        wait "$PT_PID" 2>/dev/null || true
    fi
    echo "run_passthrough: done — machine is still rigged (make stop restores the desktop)"
}
trap cleanup EXIT INT TERM

: > "$CAPTURE"
echo "run_passthrough: capturing netdebug :9514 -> $CAPTURE"
socat -u "udp-recv:9514,reuseaddr" - >> "$CAPTURE" 2>/dev/null &
CAP_PID=$!

# Wire-level USB capture (best-effort — never fails the run). usbmon's text node
# lives in debugfs; load the module and tail bus 0 (all buses) for the whole run.
: > "$USBMON_CAPTURE"
sudo modprobe usbmon 2>/dev/null || true
USBMON_NODE="/sys/kernel/debug/usb/usbmon/0u"
if sudo test -r "$USBMON_NODE"; then
    echo "run_passthrough: capturing usbmon (all buses) -> $USBMON_CAPTURE"
    sudo sh -c "cat '$USBMON_NODE'" >> "$USBMON_CAPTURE" 2>/dev/null &
    USBMON_PID=$!
else
    echo "run_passthrough: usbmon node not readable ($USBMON_NODE) — skipping wire capture" >&2
fi

# KUDOS_SMP=1 boots the multi-core kernel: passthrough.sh already builds iso-smp and
# forwards --smp to its run.sh when it sees the flag, so all that changes here is
# passing it. The boot2 driver reads KUDOS_SMP from the environment and adds the SMP
# proofs; the 60 Hz idle + under-load cadence phases run unchanged — now on many cores.
if [ "${KUDOS_SMP:-}" = "1" ]; then
    PT_SMP="--smp"
    echo "run_passthrough: launching the SMP guest on the rigged card ..."
else
    PT_SMP=""
    echo "run_passthrough: launching the guest on the rigged card ..."
fi
# --build-opts is a LEADING flag passthrough.sh consumes itself; --smp is not — it must
# come AFTER so it falls through to the args passthrough.sh forwards to run.sh (which
# boots kudos-smp.iso). Reversing them would strand --build-opts unparsed.
# shellcheck disable=SC2086  # $PT_SMP is one optional flag, deliberately unquoted
# -Dgr-backend: the passthrough track exists to exercise the REAL GPU, so it builds with
# the 4090 GR-engine gles backend (drivers/gl/opengl.zig) — that is what renders the model
# windows the render-proof phase gates on. Without it the build falls back to the software
# rasteriser, which produces no GLSTAT slots and the phase fails 0/6.
scripts/vm/passthrough.sh --build-opts "-Dtest-hooks -Dflip-sample=true -Dgr-backend=true" $PT_SMP \
    --require-stick \
    > "$LOGDIR/boot2-passthrough.log" 2>&1 &
PT_PID=$!

echo "run_passthrough: driving boot2_passthrough.py ..."
python3 scripts/tests/boot2_passthrough.py "$CAPTURE"

echo "run_passthrough: PASS"
