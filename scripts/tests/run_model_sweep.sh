#!/usr/bin/env bash
# Model-corpus sweep on the REAL USB stick, on the rigged 4090.
#
# For every .glb under models/ + scenes/ on the physical stick: load it in a
# live kudos (`show`), verify the kernel survives its first draw, screenshot it
# (the "materials visible" evidence), close its window, next. The stick passes
# through to the guest whole (the stick IS kudos storage now — vm/run.sh always
# attaches it via usb-host), so the FAT reads are real
# BOT transfers against real flash.
#
# Expectations come from glbcheck (the same glb.parse/png.decode the kernel
# runs) executed host-side against the mounted stick at sweep start; the stick
# is then unmounted so QEMU can claim it. The kernel's model cache holds
# modelcache.MAX_MODELS=8 entries (boot teapot takes one), so the sweep runs in
# batches of 7 with a fresh guest per batch — the machine must be RIGGED
# (`make rig`), and stays rigged throughout.
#
# Usage: scripts/tests/run_model_sweep.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

. scripts/gpu/env.sh

MOUNT="/run/media/$USER/KUDOSUSB"
LOGDIR="$ROOT/build/logs"
mkdir -p "$LOGDIR" "$LOGDIR/shots"
MANIFEST="$LOGDIR/model-manifest.json"
PER_BOOT=7                                 # keep in lockstep with model_sweep.py

LOCK=/tmp/kudos-passthrough-suite.lock
exec 9>"$LOCK"
flock -n 9 || { echo "run_model_sweep: another passthrough run holds $LOCK" >&2; exit 1; }

# Rig precondition (same contract as run_passthrough.sh — never rig implicitly).
drv="$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU_VGA_BDF/driver" 2>/dev/null)" 2>/dev/null || echo none)"
[ "$drv" = "vfio-pci" ] || { echo "run_model_sweep: card on '$drv' — run make rig first" >&2; exit 1; }
ss -lun 2>/dev/null | grep -q ':9514 ' && { echo "run_model_sweep: UDP :9514 is held — stop the holder" >&2; exit 1; }

# 1. Manifest from the MOUNTED stick via glbcheck (host truth). If unmounted
#    but a manifest exists, reuse it; no stick and no manifest = fail loud.
if [ -d "$MOUNT/models" ]; then
    zig build glbcheck -p build --cache-dir build/.zig-cache
    python3 - "$MOUNT" "$MANIFEST" <<'PY'
import json, os, subprocess, sys
mount, out = sys.argv[1], sys.argv[2]
rows = []
for sub in ("models", "scenes"):
    d = os.path.join(mount, sub)
    if not os.path.isdir(d):
        continue
    for name in sorted(os.listdir(d)):
        if not (name.lower().endswith(".glb") or name.lower().endswith(".gltf")):
            continue
        r = subprocess.run(["./build/bin/glbcheck", os.path.join(d, name)],
                           capture_output=True, text=True)
        line = r.stdout.splitlines()[0] if r.stdout else ""
        ok = "PARSE FAIL" not in line and "FAIL" not in line.split()[-1:]
        reason = None
        if "PARSE FAIL:" in line:
            reason = line.split("PARSE FAIL:")[1].strip()
        elif "TEX FAIL:" in line:
            reason = "texture: " + line.split("TEX FAIL:")[1].split()[0]
        rows.append({"path": f"/usbdisk/{sub}/{name}", "expect_ok": ok, "reason": reason})
json.dump(rows, open(out, "w"), indent=1)
print(f"manifest: {len(rows)} models -> {out}")
PY
    echo "run_model_sweep: unmounting the stick so QEMU can claim it ..."
    udisksctl unmount -b /dev/disk/by-label/KUDOSUSB >/dev/null
elif [ -f "$MANIFEST" ]; then
    echo "run_model_sweep: stick not mounted — reusing $MANIFEST"
else
    echo "run_model_sweep: no mounted stick at $MOUNT and no $MANIFEST — mount the stick" >&2
    exit 1
fi

N=$(python3 -c "import json,sys;print(len(json.load(open('$MANIFEST'))))")
BATCHES=$(( (N + PER_BOOT - 1) / PER_BOOT ))
echo "run_model_sweep: $N models, $BATCHES batches of <=$PER_BOOT"
: > "$LOGDIR/boot2-result.log"

for b in $(seq 0 $((BATCHES - 1))); do
    CAPTURE="$LOGDIR/sweep-netdebug-$b.log"
    : > "$CAPTURE"
    echo "run_model_sweep: === batch $b: booting the guest (real stick) ==="
    socat -u "udp-recv:9514,reuseaddr" - >> "$CAPTURE" 2>/dev/null &
    CAP_PID=$!
    scripts/vm/passthrough.sh --build-opts "-Dtest-hooks -Dflip-sample=true" --require-stick \
        > "$LOGDIR/sweep-passthrough-$b.log" 2>&1 &
    PT_PID=$!
    rc=0
    python3 scripts/tests/model_sweep.py "$CAPTURE" "$MANIFEST" "$b" || rc=$?
    echo "run_model_sweep: batch $b driver exit=$rc — stopping the guest"
    sudo scripts/vm/kill-qemu.sh || true
    kill "$PT_PID" 2>/dev/null || true
    wait "$PT_PID" 2>/dev/null || true
    kill "$CAP_PID" 2>/dev/null || true
    [ "$rc" -ne 0 ] && { echo "run_model_sweep: FAIL in batch $b" >&2; exit "$rc"; }
done

# ── post-run: harvest the evidence FROM THE STICK ───────────────────────────
# kudos wrote each capture to /usbdisk/shots/SHOTnnnn.PPM (usbshot.zig) and its
# whole trace to /usbdisk/bootlog.txt. Reclaim the stick (QEMU's usb-host claim
# detaches the host block device — a sysfs soft-replug brings it back), verify
# the FILESYSTEM kudos wrote with Linux's own fsck (the interop proof), then
# extract shots named by model (SHOTMAP lines) and the boot log.
echo "run_model_sweep: reclaiming the stick for evidence extraction ..."
scripts/tests/stick_reclaim.sh

# Interop proof (STO-006): Linux's fsck must accept the FAT kudos mutated
# (read-only), and the mount below extracts from it on stock Linux.
PART="$(readlink -f /dev/disk/by-label/KUDOSUSB)"
if sudo fsck.vfat -n "$PART" > "$LOGDIR/sweep-fsck.log" 2>&1; then
    echo "run_model_sweep: fsck.vfat CLEAN — Linux accepts kudos's FAT writes"
else
    echo "run_model_sweep: fsck.vfat found problems — see $LOGDIR/sweep-fsck.log" >&2
    exit 1
fi

EXTRACT_MOUNT=/mnt/kudosusb
sudo mkdir -p "$EXTRACT_MOUNT"
sudo mount "$PART" "$EXTRACT_MOUNT"
trap 'sudo umount "$EXTRACT_MOUNT" 2>/dev/null || true' EXIT

python3 - "$EXTRACT_MOUNT" "$LOGDIR" <<'PY'
import os, re, shutil, subprocess, sys
mount, logdir = sys.argv[1], sys.argv[2]
shots_out = os.path.join(logdir, "shots")
os.makedirs(shots_out, exist_ok=True)
# SHOTMAP lines from the batch drivers: "sweep: SHOTMAP SHOT0007.PPM = Duck.glb"
mapping = {}
for line in open(os.path.join(logdir, "boot2-result.log"), errors="replace"):
    m = re.search(r"SHOTMAP (SHOT\d+\.\w+) = (\S+)", line)
    if m:
        mapping[m.group(1)] = m.group(2)
if not mapping:
    sys.exit("run_model_sweep: no SHOTMAP lines in boot2-result.log")
missing = []
for shot, model in sorted(mapping.items()):
    src = os.path.join(mount, "shots", shot)
    if not os.path.exists(src):
        missing.append(f"{shot} ({model})")
        continue
    base = f"{os.path.splitext(model)[0]}-{shot.split('.')[0]}"
    ext = os.path.splitext(shot)[1].lower()
    if ext == ".ppm" and shutil.which("convert"):
        # Legacy PPM captures transcode for archival; native PNG copies as-is.
        subprocess.run(["convert", src, os.path.join(shots_out, base + ".png")], check=True)
    else:
        shutil.copyfile(src, os.path.join(shots_out, base + ext))
    print(f"  extracted {base} ({os.path.getsize(src)} bytes)")
if missing:
    sys.exit(f"run_model_sweep: shots MISSING on the stick: {', '.join(missing)}")
print(f"run_model_sweep: {len(mapping)} shots extracted -> {shots_out}")
PY

# The boot log kudos recorded during the sweep (last lines as a sanity echo).
sudo python3 scripts/debug/bootlog.py read "$EXTRACT_MOUNT" > "$LOGDIR/sweep-bootlog.txt" 2>/dev/null \
    && echo "run_model_sweep: bootlog extracted ($(wc -l < "$LOGDIR/sweep-bootlog.txt") lines) -> $LOGDIR/sweep-bootlog.txt" \
    || echo "run_model_sweep: WARNING bootlog read failed"
sudo umount "$EXTRACT_MOUNT"
trap - EXIT

echo "run_model_sweep: PASS — all $N models swept; shots in $LOGDIR/shots/"
echo "run_model_sweep: machine is still rigged (make stop restores the desktop)"
