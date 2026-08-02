#!/usr/bin/env bash
# THE GATE — the assembled test suite (spec TEST-001) and the REGISTER it runs on.
#
#   scripts/tests/check.sh              the ITERATION loop: run what this tree has not
#                                       yet proven, skip what it has. No lemon reboot.
#   scripts/tests/check.sh --hw         the FINAL validation: also REFUSES unless the
#                                       native tracks have passed against this tree.
#   scripts/tests/check.sh --fast       as above but skip the QEMU track too
#   scripts/tests/check.sh status       the register, read-only: every track, verified
#                                       or stale, in about a second. Runs nothing.
#   scripts/tests/check.sh run T...     run the named track(s) NOW and record them
#   scripts/tests/check.sh --stamp NAME record that track NAME verified this tree
#                                       (called by the native runners on pass)
#   FORCE=1 scripts/tests/check.sh      ignore the register, run everything
#
# THE REGISTER. Every expensive track records, in build/verified/<track>, the content
# digest of the source paths it covers, alongside result/when/duration. The gate
# re-runs a track only when that digest has gone STALE — so a green `check` re-run
# with no edits costs seconds, and a one-file edit re-runs only the tracks that file
# feeds. "This test passes" is never stored; "this test passed against tree-state X"
# is, and entries expire by content, not by memory.
#
# COVERAGE IS DELIBERATELY NARROW (optimistic). A host group's track covers its own
# src/<group> + test/<group>, not the transitive closure of everything it imports: a
# kernel/ edit does not re-run the ui host suites. The cross-group fallout that
# narrowness can miss is exactly what the whole-image tracks (qemu-boot-1, the native
# boots) exist to catch — they cover src/ entire. Broad-and-slow lives there, not in
# the per-group loop.
#
# WHY THE DEFAULT DOES NOT TOUCH REAL HARDWARE. Every native run NETBOOTS lemon and
# resets it — real wear on a real machine, not something to spend on a typo. The
# everyday loop is host tracks plus the QEMU suite (which runs inside lemon's Ubuntu,
# in a VM: no reboot, no wear). Real hardware is the LAST step: `make check-hw`.
# The default still TELLS you when hardware evidence has gone stale — it just does
# not fail on it. Confidence is built on QEMU; it is CONFIRMED on silicon.
#
# WHY DIGESTS AND NOT `git diff`. A diff against `git merge-base HEAD master` is empty
# on master with a clean tree, so the gate would short-circuit to PASS and never consult
# the stamps — blind on the branch you actually work on. The digest is over the
# WORKING-TREE content (tracked AND untracked source), so an uncommitted edit — or a
# brand-new file — invalidates exactly the tracks it should.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

STAMP_DIR="build/verified"

# How many host-group tracks may run individually before one full `zig build test`
# is cheaper than N filtered builds (the full run then stamps every group at once).
FULL_SUITE_THRESHOLD=5

# ── The track list ──────────────────────────────────────────────────────────────
# host:<group> tracks are DISCOVERED from test/'s directories (drivers one level
# deeper — its subsystems are separable), so a new test group is a new track with
# no edit here. support/ is shared fakes, not a suite.
host_groups() {
    local d s
    for d in test/*/; do
        d="${d%/}"; d="${d#test/}"
        [ "$d" = "support" ] && continue
        if [ "$d" = "drivers" ]; then
            for s in test/drivers/*/; do s="${s%/}"; echo "drivers/${s#test/drivers/}"; done
        else
            echo "$d"
        fi
    done
}

all_tracks() {
    local g
    for g in $(host_groups); do echo "host:$g"; done
    echo "stackframes"
    echo "agent-pipeline"
    echo "gltf-validate"
    echo "coverage"
    echo "qemu-boot-1"
    echo "boot-1-native"
    echo "boot-2-native"
    echo "boot-3-native"
}

# Which source paths each track's evidence covers. A change under any of these makes
# that track's stamp stale. Host groups are NARROW on purpose (see header); the
# whole-image tracks are broad on purpose — they boot everything, so they cover
# everything. The native sets predate the register and stay as they were: a false
# "you must re-run" there costs a lemon reboot, so they name what the track exercises.
paths_for() {
    case "$1" in
        host:*)
            local g="${1#host:}"
            echo "src/$g test/$g test/support src/test_root.zig" ;;
        stackframes)
            echo "src build.zig linker.ld scripts/tests/stackframes.sh scripts/tests/stackframes.py scripts/tests/stackdebt.txt" ;;
        agent-pipeline)
            echo "scripts/agent" ;;
        gltf-validate)
            echo "assets/models src/ui/assets scripts/tests/gltf-validate.sh" ;;
        coverage)
            echo "src test build.zig scripts/tests/coverage.sh" ;;
        qemu-boot-1)
            echo "src build.zig linker.ld scripts/tests/run_emulated.sh scripts/tests/boot1_emulated.py scripts/tests/cases.py scripts/debug scripts/vm" ;;
        boot-1-native)
            echo "src/drivers/usb src/drivers/net src/drivers/storage src/drivers/input src/kernel src/boot src/main_root.zig src/main_smp_root.zig" ;;
        boot-2-native)
            echo "src/drivers/gpu src/drivers/gl src/ui src/drivers/usb src/drivers/net src/kernel src/boot src/main_root.zig src/main_smp_root.zig" ;;
        boot-3-native)
            echo "src/kernel src/console src/apps src/drivers/net src/boot src/main_smp_root.zig" ;;
        *) echo "" ;;
    esac
}

# A digest over the WORKING-TREE content of a track's paths — tracked and untracked
# (a brand-new test file must invalidate too), .gitignore respected.
digest() {
    local paths; paths=$(paths_for "$1")
    [ -z "$paths" ] && { echo "unknown-track"; return; }
    # shellcheck disable=SC2086
    git ls-files -co --exclude-standard -z -- $paths \
        | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -c1-16
}

# ── The register: read and write ────────────────────────────────────────────────
# One file per track: first line the digest (the key), then result=/when=/duration_s=.
# The digest recorded is the one captured BEFORE the track ran (when given): an edit
# made while a track runs must leave the track stale, not stamped as tested.
record() { # track result duration_s [pre-run digest]
    local f="$STAMP_DIR/$1"
    mkdir -p "$(dirname "$f")"
    { echo "${4:-$(digest "$1")}"; echo "result=$2"; echo "when=$(date +%s)"; echo "duration_s=$3"; } > "$f"
}

field() { # track key -> value or ""
    local f="$STAMP_DIR/$1"
    [ -f "$f" ] && grep -m1 "^$2=" "$f" | cut -d= -f2 || true
}

# Does the register hold a PASS for this track against the CURRENT tree?
# A record carrying a digest but no result= was only ever written on pass, so the
# absence of result=fail counts as pass.
fresh_pass() { # track
    local f="$STAMP_DIR/$1"
    [ "${FORCE:-0}" = "1" ] && return 1
    [ -f "$f" ] || return 1
    [ "$(head -n1 "$f")" = "$(digest "$1")" ] || return 1
    ! grep -q '^result=fail$' "$f"
}

age_of() { # track -> "3m"/"4h"/"2d" or "?"
    local when; when=$(field "$1" when)
    [ -z "$when" ] && { echo "?"; return; }
    local d=$(( $(date +%s) - when ))
    if   [ "$d" -lt 3600 ];  then echo "$((d / 60))m"
    elif [ "$d" -lt 86400 ]; then echo "$((d / 3600))h"
    else                          echo "$((d / 86400))d"; fi
}

# ── Running one track ───────────────────────────────────────────────────────────
track_cmd() { # track -> runs it (exit status is the verdict)
    case "$1" in
        host:*) zig build test -Dtest-only="test/${1#host:}/" -p build --cache-dir build/.zig-cache ;;
        stackframes)    scripts/tests/stackframes.sh ;;
        agent-pipeline) python3 scripts/agent/test_factory.py \
                            && python3 scripts/agent/test_agent.py \
                            && python3 scripts/agent/test_mcp_stdio.py ;;
        gltf-validate)  scripts/tests/gltf-validate.sh ;;
        coverage)       scripts/tests/coverage.sh run && scripts/tests/coverage.sh check 90 ;;
        qemu-boot-1)    scripts/tests/run_emulated.sh ;;
        boot-1-native)  scripts/tests/run_native.sh ;;         # stamps itself on pass
        boot-2-native)  scripts/tests/run_native.sh --gpu ;;
        boot-3-native)  scripts/tests/run_native.sh --smp ;;
        *) echo "check: unknown track '$1' — 'status' lists them" >&2; return 2 ;;
    esac
}

run_track() { # track -> run + record; returns the verdict
    local t="$1" start rc=0 pre
    pre="$(digest "$t")"
    start=$(date +%s)
    track_cmd "$t" || rc=$?
    case "$t" in boot-*-native) return $rc ;; esac   # the native runners stamp themselves
    if [ "$rc" = 0 ]; then
        record "$t" pass "$(( $(date +%s) - start ))" "$pre"
    else
        record "$t" fail "$(( $(date +%s) - start ))" "$pre"
    fi
    return $rc
}

# ── Subcommands ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--stamp" ]; then
    track="${2:?--stamp needs a track name}"
    record "$track" pass "${3:-}"
    echo "check: stamped $track = $(head -n1 "$STAMP_DIR/$track") (this tree is now verified)"
    exit 0
fi

if [ "${1:-}" = "status" ]; then
    echo "test register — this tree vs build/verified/ (runs nothing)"
    echo
    for t in $(all_tracks); do
        dur=$(field "$t" duration_s); dur="${dur:+${dur}s}"; dur="${dur:-?}"
        if fresh_pass "$t"; then
            printf "  ✓ %-22s verified against this tree (passed %s ago, took %s)\n" \
                "$t" "$(age_of "$t")" "$dur"
        elif [ -f "$STAMP_DIR/$t" ] && [ "$(head -n1 "$STAMP_DIR/$t")" = "$(digest "$t")" ]; then
            printf "  ✗ %-22s FAILED against this exact tree %s ago — fix, don't re-run\n" \
                "$t" "$(age_of "$t")"
        elif [ -f "$STAMP_DIR/$t" ]; then
            printf "  ✗ %-22s stale — covered code changed since it passed (%s ago, took %s)\n" \
                "$t" "$(age_of "$t")" "$dur"
        else
            printf "  ✗ %-22s never run against any tree\n" "$t"
        fi
    done
    echo
    scripts/tests/mutcheck.sh --status
    echo
    echo "run one:  make test T=<track>     run what's needed:  make check"
    exit 0
fi

if [ "${1:-}" = "run" ]; then
    shift
    [ $# -ge 1 ] || { echo "usage: check.sh run <track>... ('status' lists tracks)" >&2; exit 2; }
    rc=0
    for t in "$@"; do
        echo "▸ $t"
        run_track "$t" || rc=1
    done
    exit $rc
fi

FAST=0
HW=0
case "${1:-}" in
    --fast) FAST=1 ;;
    --hw)   HW=1 ;;
    "")     ;;
    *)      echo "usage: $0 [--hw | --fast | status | run T... | --stamp NAME]" >&2; exit 2 ;;
esac

echo "──────────────────────────────────────────────────────────────────────"
if [ "$HW" = 1 ]; then
    echo " kudos gate — FINAL VALIDATION (real hardware required)"
else
    echo " kudos gate — iteration (stale tracks only; lemon is not rebooted)"
fi
echo "──────────────────────────────────────────────────────────────────────"

# ── 1. The always-run checks. Each is seconds with no build — cheaper than the
#       bookkeeping to skip them — and they run first, because a group reaching
#       sideways into another is the failure that makes every later check harder
#       to reason about.
echo
scripts/tests/layering.sh

echo
echo "▸ public-surface snapshot"
scripts/tests/apisnap.sh

# The TLS client is the toolchain's own, copied in and patched (there is no way
# to run std's verified-CA path in a kernel). A copy of security-critical code
# goes stale silently, so it is GENERATED and checked here: an upgraded Zig that
# moves the file fails this, which is the prompt to re-vendor and read the diff.
echo
echo "▸ vendored TLS client vs the pinned toolchain"
scripts/build/vendor-tls.py check

# The GLSL uniform block is one half of an ABI whose other half is es/uniforms.zig;
# if they disagree the tree still builds and the GPU still draws — garbage.
echo
python3 scripts/gl/es11_glsl_layout.py --check \
    && echo "  ✓ shaders/gles_state.glsl matches es/uniforms.zig"

echo
echo "▸ requirement trace (spec.md ↔ tests)"
scripts/tests/reqtrace.sh

# The verdict homes: before any hardware verdict that leans on these rules is
# trusted, the rules themselves must provably separate a clean run from a broken
# one — host-checkable in milliseconds.
echo
echo "▸ AA conformance metric self-test (DSK-009)"
python3 scripts/tests/aa_metric.py
echo "  PASS"

echo
echo "▸ boot-3 verdict self-tests (counters + schedclock + mirror parsing)"
python3 scripts/tests/counters.py
python3 scripts/tests/schedclock.py
python3 scripts/tests/cases.py
echo "  PASS"

# ── 2. The host-group tracks. These encode the silicon truths, so a regression in
#       the 64 KiB split rule or the DHCP lease rule goes red here, on the laptop.
#       Only STALE groups run; when many are stale, one full suite run is cheaper
#       than N filtered builds and its green stamps every group at once.
echo
echo "▸ host test tracks"
STALE_HOSTS=""
for g in $(host_groups); do
    t="host:$g"
    if fresh_pass "$t"; then
        echo "  ✓ $t — verified ($(age_of "$t") ago)"
    else
        STALE_HOSTS="$STALE_HOSTS $g"
    fi
done
n_stale=$(echo "$STALE_HOSTS" | wc -w)
if [ "$n_stale" = 0 ]; then
    echo "  (nothing stale — no host suites to run)"
elif [ "$n_stale" -ge "$FULL_SUITE_THRESHOLD" ]; then
    echo "  → $n_stale groups stale: one full suite run is cheaper than $n_stale filtered builds"
    declare -A PRE
    for g in $(host_groups); do PRE["$g"]="$(digest "host:$g")"; done
    start=$(date +%s)
    zig build test -p build --cache-dir build/.zig-cache
    took=$(( $(date +%s) - start ))
    for g in $(host_groups); do record "host:$g" pass "$took" "${PRE[$g]}"; done
    echo "  PASS — all host groups stamped (${took}s)"
else
    for g in $STALE_HOSTS; do
        echo "  → host:$g (stale)"
        run_track "host:$g"
    done
    echo "  PASS"
fi

# ── 3. The mutation gate: proof that regression tests can fail. Per-row stamps —
#       only rows whose target or suite changed re-run (mutcheck.sh owns them).
echo
echo "▸ mutation gate (regression tests must be able to fail)"
scripts/tests/mutcheck.sh

# ── 4. The remaining stamped tracks, cheapest first.
for t in gltf-validate agent-pipeline stackframes; do
    echo
    echo "▸ $t"
    if fresh_pass "$t"; then
        echo "  ✓ cached — passed $(age_of "$t") ago against this exact tree"
    else
        run_track "$t"
    fi
done

# ── 5. The QEMU suite: the whole-image track, where the narrow host coverage gets
#       its cross-group backstop. Costs lemon nothing (a VM inside its Ubuntu).
if [ "$FAST" = 0 ]; then
    echo
    echo "▸ qemu-boot-1 (emulated; no lemon reboot)"
    if fresh_pass "qemu-boot-1"; then
        echo "  ✓ cached — passed $(age_of qemu-boot-1) ago against this exact tree"
    else
        # DO NOT SWALLOW THE OUTPUT into a message that lies: when the suite runs on
        # lemon (it usually does; the stick lives there) a local log path would be a
        # stale leftover from some earlier local run. Capture HERE, tail on failure.
        qemu_log="$(mktemp)"
        start=$(date +%s)
        if scripts/tests/run_emulated.sh >"$qemu_log" 2>&1; then
            record qemu-boot-1 pass "$(( $(date +%s) - start ))"
            rm -f "$qemu_log"
            echo "  PASS"
        else
            record qemu-boot-1 fail "$(( $(date +%s) - start ))"
            echo "  FAIL — last 20 lines:" >&2
            tail -20 "$qemu_log" >&2
            rm -f "$qemu_log"
            echo >&2
            echo "check: FAIL — the QEMU suite is red. Fix that before spending a boot on lemon." >&2
            exit 1
        fi
    fi
fi

# ── 5b. The coverage measurement — FINAL-gate only (--hw): a full instrumented
#        sweep costs ~15 minutes, which belongs at validation boundaries, not in
#        the iteration loop. `make test T=coverage` runs it on demand; the
#        register keeps its verdict either way.
if [ "$HW" = 1 ]; then
    echo
    echo "▸ coverage (kcov sweep + ≥90%/file verdict)"
    if fresh_pass "coverage"; then
        echo "  ✓ cached — passed $(age_of coverage) ago against this exact tree"
    else
        run_track "coverage"
    fi
fi

# ── 6. The hardware evidence. EVERY native track is checked, every time: if the code
#       a track covers is untouched, its stamp still matches and it passes for free.
echo
echo "▸ hardware evidence"
STALE=""
for track in boot-1-native boot-2-native boot-3-native; do
    if fresh_pass "$track"; then
        echo "  ✓ $track — verified against this exact tree ($(age_of "$track") ago)"
    elif [ ! -f "$STAMP_DIR/$track" ]; then
        echo "  ✗ $track — NEVER RUN against this tree"
        STALE="$STALE $track"
    else
        echo "  ✗ $track — STALE (code it covers has changed since it last passed)"
        STALE="$STALE $track"
    fi
done

# --fast SKIPPED the QEMU suite, so no verdict below may claim it. Name what was
# not run: a summary that reads greener than the run was is how a track quietly
# stops being part of the gate.
if [ "$FAST" = 1 ]; then
    QEMU_VERDICT="host tracks are green; the QEMU suite was SKIPPED (--fast)"
else
    QEMU_VERDICT="host tracks and QEMU are green"
fi

if [ -z "$STALE" ]; then
    echo
    echo "check: PASS — $QEMU_VERDICT, and every native track has run on real"
    echo "       hardware against this exact tree."
    exit 0
fi

if [ "$HW" = 0 ]; then
    echo
    echo "check: PASS — $QEMU_VERDICT."
    echo
    echo "       Hardware evidence is NOT current for:"
    for t in $STALE; do echo "         $t"; done
    echo
    echo "       That is fine while you iterate — QEMU is where confidence is built,"
    echo "       and a native run reboots lemon. When you are ready to call this done:"
    echo "           make check-hw"
    exit 0
fi

cat >&2 <<EOF

check: FAIL — code that ONLY REAL HARDWARE CAN EXERCISE has changed since a native
       track last passed, so nothing has verified this tree.

       QEMU does not enforce the xHCI 64 KiB rule, does not run the igc NIC at all,
       and reports Success where real controllers report Short Packet. Green host
       tests and a green QEMU boot genuinely do not mean the real build works.

       Run:
EOF
for t in $STALE; do echo "           make test-$t" >&2; done
cat >&2 <<EOF

       Then re-run: make check-hw
EOF
exit 1
