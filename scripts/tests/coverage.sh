#!/usr/bin/env bash
# Statement coverage: the host suites under kcov → build/coverage/.
#
#   scripts/tests/coverage.sh run          build the test binaries, sweep kcov
#                                          over them (parallel), merge the report
#   scripts/tests/coverage.sh check [PCT]  assert every measured file ≥ PCT%
#                                          lines covered (default 90)
#
# WHY A SCRIPT AND NOT BUILD STEPS. Under the build runner every kcov step
# exits 1 after its tests pass, while the identical command in a shell exits 0
# (185/190 "failures" with all-green output, across parallel/serial and
# cached/fixed output dirs). `zig build coverage` therefore only BUILDS the
# binaries into build/testbin/; this script owns the sweep and the verdict.
#
# The number is a MEASUREMENT, not a target (process.md §Verification): a file
# failing `check` is a finding to disposition — missing requirement, dead code,
# or inadequate test — never a prompt to write assertion-free tests.
set -uo pipefail
cd "$(dirname "$0")/../.."

case "${1:-run}" in
run)
    # Debug VIA LLVM, not ReleaseFast and not the self-hosted backend: coverage
    # is a MEASUREMENT. ReleaseFast inlining wrecks line attribution (files with
    # green suites read 0%), and the self-hosted Debug backend's DWARF is thin
    # enough that kcov sees a fraction of the files (35 vs ~190 binaries). The
    # pass/fail TEST gate stays ReleaseFast; only the instrument changes.
    zig build coverage -Ddebug -Dllvm -p build --cache-dir build/.zig-cache || exit 1
    rm -rf build/coverage
    mkdir -p build/coverage/raw
    # One kcov per binary, a few at a time; per-binary logs keep a failure
    # diagnosable without drowning the sweep's own progress line.
    ls build/testbin/t* | xargs -P 8 -I{} sh -c '
        n=$(basename {})
        kcov --include-path=src --clean "build/coverage/raw/$n" {} \
            > "build/coverage/raw/$n.log" 2>&1 \
            || { echo "kcov FAILED: {} (build/coverage/raw/$n.log)"; exit 9; }
        echo "  ✓ $n"
    ' || { echo "coverage: sweep failed"; exit 1; }
    # Merge the per-binary DIRECTORIES only — raw/ also holds their .log files.
    find build/coverage/raw -mindepth 1 -maxdepth 1 -type d -print0 \
        | xargs -0 kcov --merge build/coverage || exit 1
    echo "coverage: merged → build/coverage/index.html"
    ;;
check)
    min="${2:-90}"
    python3 - "$min" <<'EOF'
import json, os, sys
min_pct = float(sys.argv[1])

# Declared exemptions: file suffix -> why its host number cannot honestly reach
# the bar. VISIBLE every run — a silent exclusion would read as coverage that
# does not exist. Each names the evidence that stands in for the missing lines.
EXEMPT = {
    "src/drivers/net/stack/tlsclient.zig":
        "post-handshake record machinery needs a live TLS peer; the ClientHello "
        "+ error paths are host-tested and HTTPS runs on-target",
    "src/drivers/gl/soft.zig":
        "residue is the -Dsoft-display in-place present path (RND-012..014, no "
        "gate boots it) and PBR fragment internals pinned by the render-oracle "
        "goldens + Khronos references + the 4090 track",
    "src/drivers/gl/es/gl.zig":
        "residue is device-loss/wedge defensive arms (acquire failure, "
        "FINISH_POLL_CAP, DrawBusy) a healthy host device cannot produce; GPU "
        "loss is boot-2's story",
    "src/drivers/gl/es/state.zig":
        "residue is allocator-failure unwind arms (staging OOM, retire-full "
        "marked unreachable-with-geometric-growth in source)",
    "src/kernel/sched/sched.zig":
        "the scheduler IO edge (context switch asm, per-core dispatch, task "
        "birth) never runs on a host — it is COMPILED here only because "
        "taskstat names its types; the scheduler's evidence is boot-3-native "
        "(placement, deadline sleep, wake storm on 32 real cores)",
    "src/drivers/gl/ada/variant.zig":
        "residue is two `catch unreachable` bounded-format arms — "
        "uncoverable by construction",
}

d = json.load(open("build/coverage/kcov-merged/coverage.json"))
files = d.get("files", [])
low, exempt = [], []
for f in files:
    if float(f.get("percent_covered", 0)) >= min_pct:
        continue
    # kcov reports absolute paths; the EXEMPT keys and the report are
    # repo-relative. Strip THIS checkout's root, wherever it was cloned — a
    # hardcoded one silently stops matching on anybody else's machine, and the
    # exemptions then read as failures.
    path = f["file"].removeprefix(os.getcwd() + "/")
    (exempt if path in EXEMPT else low).append((path, f["percent_covered"]))
low.sort(key=lambda x: float(x[1]))
print(f"  coverage: {d.get('percent_covered')}% overall, {len(files)} files measured")
for path, pct in exempt:
    print(f"  ~ {pct:>6}%  {path} — EXEMPT: {EXEMPT[path]}")
for path, pct in low:
    print(f"  ✗ {pct:>6}%  {path}")
if low:
    print(f"  coverage: {len(low)} file(s) under {min_pct}% — disposition each "
          "(missing requirement / dead code / inadequate test)")
    sys.exit(1)
print(f"  ✓ every measured file ≥ {min_pct}% lines (exemptions above are declared, not hidden)")
EOF
    ;;
*)
    echo "usage: $0 [run | check [PCT]]" >&2
    exit 2
    ;;
esac
