#!/usr/bin/env bash
# ONE command: screenshot a model on the real RTX 4090 under QEMU passthrough.
#
#     scripts/tests/shot.sh                 # MetalRoughSpheres.glb (the default)
#     scripts/tests/shot.sh rabbit.glb      # any .glb on the stick or assets/models
#
# No flags, no prior `make rig`, no build options. It rigs the card if needed,
# boots the test-hooks image against the 4090 + the physical stick, opens the
# model maximised over netdebug (keyboard only — no pointer dance), pulls the
# screenshot, and converts it to PNG at build/logs/shots/<model>.png. Every
# resource is released on exit (QEMU killed, tap + firewall rules removed); the
# card is LEFT rigged for a fast next shot — `make stop` restores the desktop.
#
# !!! Takes the whole machine if it has to rig: the display goes dark and stays
# !!! dark. Meant for the headless GPU box (lemon) over SSH.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
. scripts/gpu/env.sh

MODEL="$(basename "${1:-MetalRoughSpheres.glb}")"
STEM="${MODEL%.*}"
STICK=/dev/disk/by-label/KUDOSUSB
LOGDIR="$ROOT/build/logs"
SHOTDIR="$LOGDIR/shots"
CAPTURE="$LOGDIR/shot-netdebug.log"
OUT_PNG="$SHOTDIR/$STEM.png"
mkdir -p "$SHOTDIR"

# One at a time: a second run would fight over the card, the tap, and :9514.
exec 9>/tmp/kudos-shot.lock
flock -n 9 || { echo "shot: another run holds the lock — wait for it to finish" >&2; exit 1; }

# Rig on demand (never silently): if the card is not already on vfio-pci, take
# the display and bind it. Idempotent — a rigged card is left as-is.
drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU_VGA_BDF/driver" 2>/dev/null)" 2>/dev/null || echo none)"
if [ "$drv" != "vfio-pci" ]; then
    echo "shot: card on '$drv' — rigging (this takes the display) ..."
    scripts/gpu/rig.sh --take-display
fi

# Stage the model onto the stick if it isn't already there (removed on exit so
# the stick is left as found). run.sh passes the WHOLE physical stick to the guest.
STAGED=0
mt() { sudo -n env MTOOLS_SKIP_CHECK=1 "$@"; }
if ! mt mdir -i "$STICK" -b ::/models/ 2>/dev/null | grep -Fqix "::/models/$MODEL"; then
    SRC="assets/models/$MODEL"
    [ -f "$SRC" ] || { echo "shot: $MODEL is neither on the stick nor at $SRC" >&2; exit 1; }
    echo "shot: staging $SRC onto the stick"
    mt mcopy -o -i "$STICK" "$SRC" ::/models/
    STAGED=1
fi
MODEL_ARG="/usbdisk/models/$MODEL"

CAP_PID="" ; PT_PID=""
cleanup() {
    sudo -n scripts/vm/kill-qemu.sh >/dev/null 2>&1 || true
    [ -n "$PT_PID" ]  && { kill "$PT_PID"  2>/dev/null || true; wait "$PT_PID"  2>/dev/null || true; }
    [ -n "$CAP_PID" ] && kill "$CAP_PID" 2>/dev/null || true
    if [ "$STAGED" = 1 ] && scripts/tests/stick_reclaim.sh 2>/dev/null; then
        mt mdel -i "$STICK" "::/models/$MODEL" 2>/dev/null && echo "shot: unstaged $MODEL"
    fi
}
trap cleanup EXIT

: > "$CAPTURE"
socat -u "udp-recv:9514,reuseaddr" - >> "$CAPTURE" 2>/dev/null &
CAP_PID=$!
scripts/vm/passthrough.sh --build-opts "-Dtest-hooks" --require-stick > "$LOGDIR/shot-passthrough.log" 2>&1 &
PT_PID=$!

# The driver opens the window and pulls the shot over netdebug. It may fail ONLY
# at the transfer (a flaky GSP boot can wedge core 0 and starve the file server) —
# but kudos also saves every screenshot to the stick (::/shots/SHOTnnnn.PNG), so
# that copy is the reliable fallback. `|| true` keeps set -e from aborting here.
python3 scripts/tests/model_shot.py "$CAPTURE" "$MODEL_ARG" "$SHOTDIR" || true

# kudos encodes the screenshot as PNG on-device (its own png encoder); name it
# for the model so repeat shots don't clobber each other.
mv -f "$SHOTDIR/screenshot.png" "$OUT_PNG" 2>/dev/null || true

if [ ! -f "$OUT_PNG" ]; then
    echo "shot: netdebug transfer did not land the PNG — falling back to the stick copy" >&2
    sudo -n scripts/vm/kill-qemu.sh >/dev/null 2>&1 || true
    if scripts/tests/stick_reclaim.sh >/dev/null 2>&1; then
        # Newest on-device capture: SHOTnnnn.PNG sorts by its zero-padded number.
        latest="$(mt mdir -i "$STICK" -b ::/shots/ 2>/dev/null | grep -oiE 'SHOT[0-9]+\.PNG' | sort | tail -1)"
        [ -n "$latest" ] && mt mcopy -o -i "$STICK" "::/shots/$latest" "$OUT_PNG" 2>/dev/null \
            && echo "shot: recovered $latest from the stick" >&2
    fi
fi

if [ -f "$OUT_PNG" ]; then
    echo "shot: PNG  $OUT_PNG"
    echo "shot: done"
else
    echo "shot: FAILED — no screenshot from netdebug or the stick" >&2
    exit 1
fi
