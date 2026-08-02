#!/usr/bin/env bash
# boot-1/2/3-NATIVE — the integration suites on REAL HARDWARE (lemon).
#
#   scripts/tests/run_native.sh          boot-1-native: no GPU firmware, shell + WM cases
#   scripts/tests/run_native.sh --gpu    boot-2-native: GSP firmware staged, the 4090 runs
#   scripts/tests/run_native.sh --smp    boot-3-native: the kudos-smp kernel + GSP — the
#                                        SMP scheduling stress suite (boot3_native.py)
#
# Same cases and same assertions as the emulated track (cases.py is shared); only the
# transport differs — KMR1 (:9515) injects, netdebug (:9514) reads back. See
# boot1_native.py for why that matters: every bug that has cost us a trip to lemon was
# invisible under QEMU.
#
# THE boot-1/boot-2 TRACKS DIFFER BY EXACTLY ONE THING: whether GSP firmware is staged.
#   no firmware -> kudos runs on the GRUB framebuffer, the 4090 is never touched. This
#                  IS boot-1 (no GPU) on real silicon, and it is the safe one: a hang
#                  cannot wedge the card for the next POST.
#   firmware    -> GSP boots the 4090 natively; the desktop composites on the real GPU.
#
# BOOT-3 changes the KERNEL, not the firmware: mknetboot stages kudos-smp (every core
# online, IO-APIC tick rotating, per-session address spaces) with GSP, and the driver is
# boot3_native.py — placement/oversubscription, deadline sleep and the tick under full
# load, session churn, a guest vCPU as a scheduled task, 60 Hz cadence throughout, and a
# no-silent-loss counter watch after every phase. BOOT3_SOAK_MIN=<minutes> loops the load
# phases; BOOT3_SEED replays a run's randomised shapes.
#
# WHAT A boot-3 RUN MUST CONFIRM ON THE RIG (its INSTRUMENTS phase gates these, and it
# fails loudly, by name, while any of them is dead — they are the suite's own probes):
#   - the from-first-present FLIPSTAT verdict emits on kudos-smp (it does on the
#     single-core kernel; on kudos-smp the shell's `flipstat` echoes but no verdict
#     follows);
#   - the KMR1 SHOT (screenshot) op replies;
#   - KMR1 request/response service stays alive for the whole run (the stream-only
#     netdebug side staying healthy is not enough);
#   - one injected `vm boot 1` boots exactly ONE guest (request-id dedup once the
#     service can run on any core).
#
# SAFETY. The image is netbooted ONE-SHOT (grub-reboot), so any reset — a wedge, a
# panic, the KMR1 reboot at the end — lands back in Ubuntu with nobody in the room. The
# run ALWAYS ends by rebooting lemon, even on failure, so a red test never leaves the
# machine sitting in kudos.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

GPU=0
SMP=0
case "${1:-}" in
    --gpu) GPU=1 ;;
    --smp) SMP=1 ;;
    "")    ;;
    *)     echo "usage: $0 [--gpu | --smp]" >&2; exit 2 ;;
esac

BUILD_DIR="${BUILD_DIR:-build}"
LEMON_IP="${LEMON_IP:-$(scripts/netboot/lemonip.sh)}"

# WHAT --gpu ACTUALLY ADDS. Both tracks run the SAME driver (boot1_native.py) over the
# SAME shared case table; the only difference is whether GSP firmware is staged, i.e.
# whether the desktop composites through the real 4090 or through the GRUB framebuffer.
# So boot-2-native proves the whole shell/WM suite AGAINST A LIVE GPU STACK — which is
# what makes its stamp meaningful for src/drivers/gpu and src/drivers/gl — AND, on the
# metal where no hypervisor can preempt the vCPU, the from-first-present frame-cadence
# guarantee: phase_cadence judges the same 10 s "smooth from the first present" verdict
# boot2_passthrough does (shared cadence.py). It does NOT run the under-load/thrash
# FLIPSTAT phases, the model sweep, or the screenshot artifact — those live in
# `make test-boot-2-qemu`.
if [ "$SMP" = 1 ]; then
    TRACK="boot-3-native (kudos-smp + GSP: SMP scheduling stress)"
    STAMP=boot-3-native
elif [ "$GPU" = 1 ]; then
    TRACK="boot-2-native (GSP + the real 4090)"
    STAMP=boot-2-native
else
    TRACK="boot-1-native (no GPU firmware)"
    STAMP=boot-1-native
fi

# EVIDENCE MUST SURVIVE THE NEXT RUN. The trace is per-track and lives under build/logs/
# (real disk, survives a power cut). The previous run rotates to .prev, and a FAILED run
# is copied to .failed, which a later success never touches — so retrying cannot erase
# why the first attempt failed.
LOGDIR="$ROOT/$BUILD_DIR/logs"
mkdir -p "$LOGDIR"
NETDEBUG_LOG="${NETDEBUG_LOG:-$LOGDIR/$STAMP-netdebug.log}"
export LEMON_IP NETDEBUG_LOG
[ -f "$NETDEBUG_LOG" ] && cp -f "$NETDEBUG_LOG" "$NETDEBUG_LOG.prev"

echo "run_native: $TRACK on lemon ($LEMON_IP)"
echo "run_native: trace -> $NETDEBUG_LOG"

# -Dtest-hooks compiles in the terminal-output mirror (dbg: term.<core> = …), which is
# how the harness reads what kudos printed. Without it every assertion is blind.
# -Dflip-sample (GPU track only) compiles in the from-first-present frame-cadence window
# so boot1_native.py's phase_cadence can judge "10 s smooth from the first present" on the
# metal — the same measurement boot2_passthrough runs, but without QEMU's host-scheduler
# jitter. The no-GPU track has no present ring, so it would never emit a verdict.
BUILD_FLAGS="-Dtest-hooks"
if [ "$GPU" = 1 ] || [ "$SMP" = 1 ]; then BUILD_FLAGS="$BUILD_FLAGS -Dflip-sample"; fi
# boot-3 is the multi-core kernel: build + stage kudos-smp (the mknetboot argument
# SELECTS the kernel — `kudos` is single-core, `kudos-smp` is SMP).
if [ "$SMP" = 1 ]; then
    ISO_TARGET=iso-smp
    VARIANT=kudos-smp
else
    ISO_TARGET=iso
    VARIANT=kudos
fi
echo "run_native: building $ISO_TARGET ($BUILD_FLAGS) ..."
# shellcheck disable=SC2086  # deliberate word-split of the flag list
zig build "$ISO_TARGET" $BUILD_FLAGS -p "$BUILD_DIR" --cache-dir "$BUILD_DIR/.zig-cache" >/dev/null

# GSP_FW_DIR= (empty) stages NO firmware -> the no-GPU track. boot-2 AND boot-3 run
# the real 4090 (kudos-smp on lemon composites at 60 Hz through GSP).
if [ "$GPU" = 1 ] || [ "$SMP" = 1 ]; then
    scripts/netboot/mknetboot.sh "$VARIANT" >/dev/null
else
    GSP_FW_DIR= scripts/netboot/mknetboot.sh "$VARIANT" >/dev/null
fi

# The server must be up before lemon resets, or it fetches nothing and falls into Ubuntu.
scripts/netboot/serve.sh status | grep -q "^http: *UP" || scripts/netboot/serve.sh start

# Capture netdebug for the whole run. This is the readback channel — start it BEFORE the
# boot or the terminal greeting we gate on scrolls past unseen.
#
# A SIGKILLed previous run leaks its socat (the cleanup trap never fires on an
# uncatchable kill), and a stale socat still bound to :9514 competes for the
# datagrams — the new socat then misses the boot banner and the run fails its
# first assertion on a healthy boot. Reap any leftover, and wait for the port to
# actually free before binding (a just-killed socket lingers a moment).
if pgrep -f "socat.*9514" >/dev/null 2>&1; then
    echo "run_native: killing a stale :9514 capture from a previous run" >&2
    pkill -f "socat.*9514" || true
    for _ in 1 2 3 4 5; do ss -lun 2>/dev/null | grep -q ":9514 " || break; sleep 0.4; done
fi
: > "$NETDEBUG_LOG"
socat -u udp-recv:9514,reuseaddr - >> "$NETDEBUG_LOG" 2>/dev/null &
CAP_PID=$!

# ALWAYS put lemon back in Ubuntu, pass or fail. A red test that strands the machine in
# kudos costs a human trip — the one thing this whole setup exists to avoid.
cleanup() {
    rc=$?
    kill "$CAP_PID" 2>/dev/null || true

    # Preserve the evidence before anything else, and print the tail: a caller that pipes
    # this run through `tail` would otherwise discard the only description of the failure.
    if [ "$rc" -ne 0 ] && [ -s "$NETDEBUG_LOG" ]; then
        cp -f "$NETDEBUG_LOG" "$NETDEBUG_LOG.failed"
        echo "run_native: FAILED — trace preserved at $NETDEBUG_LOG.failed" >&2
        echo "run_native: last 15 trace lines:" >&2
        tail -15 "$NETDEBUG_LOG" >&2
    fi

    echo "run_native: returning lemon to Ubuntu (KMR1 reboot; one-shot lands in Ubuntu)"
    python3 - <<'PY' || true
import os, sys
sys.path.insert(0, "scripts/tools/netdebug-mcp")
import kmir
try:
    kmir.Client(os.environ["LEMON_IP"]).reboot()
    print("run_native: reboot ACKed by kudos")
except Exception as e:
    print(f"run_native: KMR1 reboot failed ({e}) — NOTHING ELSE RESETS THE RIG:")
    print("run_native: the KMR1 service is the ONLY remote reset path, and a failure")
    print("run_native: mode that kills it (e.g. core-0 interrupt starvation taking NIC")
    print("run_native: RX with it) strands lemon in kudos until a PHYSICAL reset.")
PY
    exit $rc
}
trap cleanup EXIT INT TERM

# lemon must be back in UBUNTU before we can arm the next boot — and a previous run (or
# the image's own self-reboot) may still be on its way there. Waiting here is not
# politeness: `lemon.sh boot` needs ssh, and without this the run dies on "No route to
# host" having done nothing.
echo "run_native: waiting for lemon to be reachable in Ubuntu ..."
for i in $(seq 1 40); do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${LEMON_HOST:-lemon}" true 2>/dev/null; then
        break
    fi
    [ "$i" = 40 ] && { echo "run_native: lemon never came back in Ubuntu" >&2; exit 1; }
    sleep 5
done

# The stick is a TEST FIXTURE and the boot-1/2 suites assert against its contents, so
# check it BEFORE spending a boot — drift here otherwise surfaces three minutes in,
# disguised as a kernel bug. It has to come AFTER the wait above: the stick lives in
# lemon, so this needs ssh, and running it first just fails with "No route to host"
# while lemon is still on its way back to Ubuntu from the previous run. boot-3 asserts
# nothing on the stick, so it does not gate on the fixture.
[ "$SMP" = 1 ] || python3 scripts/tests/usbdisk.py verify

# The kernel arrives over the network (BOOT-001): lemon.sh stages the freshly
# built image to the boot server and lemon fetches it at boot.
scripts/netboot/lemon.sh boot

if [ "$SMP" = 1 ]; then
    echo "run_native: driving boot3_native.py ..."
    BOOT3_TRACK=native python3 scripts/tests/boot3_native.py
else
    echo "run_native: driving boot1_native.py ..."
    python3 scripts/tests/boot1_native.py
fi

# STAMP THE TREE THIS TRACK JUST VERIFIED. `make check` compares this against the
# working tree's current digest, so it can tell you — without cron, without CI, and
# without trusting anyone's memory — that the hardware evidence is stale. See
# check.sh; the digest covers the source paths this track actually exercises.
scripts/tests/check.sh --stamp "$STAMP"

echo "run_native: PASS — $TRACK"
