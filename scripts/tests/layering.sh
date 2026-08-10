#!/usr/bin/env bash
# The layering gate: the architecture rules in CLAUDE.md, made executable — the
# layered-module discipline itself is spec ARCH-001, and the import checks below
# are its enforcement.
#
# A rule that only lives in a document is a rule that comes back. Every check below must
# stay empty, and this script is what keeps it that way. It runs in `make check` and
# costs nothing — no build, no hardware.
#
# Adding a rule here is cheap. Deleting one because it is inconvenient is not a fix.
set -uo pipefail
cd "$(dirname "$0")/../.."

fail=0

check() {
    local name="$1" fix="$2"
    shift 2
    local hits
    hits="$("$@" || true)"
    if [ -n "$hits" ]; then
        echo "  ✗ $name"
        echo "$hits" | sed 's/^/      /'
        echo "      fix: $fix"
        fail=1
    else
        echo "  ✓ $name"
    fi
}

echo "▸ layering (CLAUDE.md's rules, enforced)"

# Dependencies point one way: ui/ → iface/ ← drivers/ → kernel/. A group that reaches
# sideways into another has bypassed the contract that makes both testable in isolation.
check "ui/ does not import drivers/" \
    "add a vtable in src/iface/ and publish through it" \
    grep -rEn '@import\("(\.\./)+drivers/' src/ui/

check "drivers/ does not import ui/" \
    "add a vtable in src/iface/ and publish through it" \
    grep -rEn '@import\("(\.\./)+ui/' src/drivers/

# There is one way to draw 3D, and it is `gles` (ARCH-006: all kgl rendering routes
# through gles). An app that reaches past it into the device seam gets to skip the
# state machine's validation and leave GL's state disagreeing with what was drawn — a
# class of bug that only ever shows up as pixels. gles.createContext is the whole of
# what an app needs; idraw is the driver's business.
# The window manager draws through kgl and nothing else (ARCH-005): glcomp is a kgl
# client, and no WM file issues its own GL draw or vertex-array calls. The desktop's
# direct gles use is frame orchestration only — context lifecycle, present, scissor,
# texture upload — which kgl deliberately does not own.
check "the window manager draws through kgl, never raw gles draw calls" \
    "draw through kgl (glcomp is the pattern); raw GL geometry belongs to the 3D model path" \
    grep -rEn 'gles\.(drawArrays|drawElements|vertexPointer|colorPointer|texCoordPointer|normalPointer)' src/ui/desktop/ src/ui/wm/

check "ui/ draws through gles, not around it" \
    "use gles.createContext + the gl entry points; idraw is not an app-facing seam" \
    grep -rEn '@import\("idraw"\)' src/ui/

# The ES 1.1 state machine is pure, and stays pure: it may know the specification and
# the device CONTRACT, and nothing about the silicon that implements it. Let it reach
# sideways and the first thing to follow is a method offset.
check "gl/es/ does not import the hardware half" \
    "lower it through iface/idraw.zig instead" \
    grep -rEn '@import\("(\.\./)*(ada|engine|opengl|gr|methods|shaders)' src/drivers/gl/es/

# gl/ada/ encodes ADA_A method streams and nothing else: it takes numbers and produces
# the bytes the 3D class eats. That purity is what makes it host-testable, and it is the
# only reason the method goldens exist — a single MMIO import would take the whole layer
# off the host and out of the test list. The silicon-bound half is gl/engine/.
check "gl/ada/ stays pure — no MMIO, no GPU state, no kernel" \
    "it belongs in gl/engine/, which is allowed to touch the device" \
    grep -rEn '@import\("(\.\./)*(gpu|engine|opengl)/|@import\("(\.\./)*\.\./kernel/' src/drivers/gl/ada/

# Embedding a UI asset is importing it by another name: it is still a driver that knows
# what a welcome message looks like. Seeding is boot policy — see src/main_root.zig `seedRamdisk`.
check "drivers/ does not embed ui/ assets" \
    "embed it where the policy lives (src/main_root.zig), not in the driver" \
    grep -rEn '@embedFile\("(\.\./)+ui/' src/drivers/

# A subsystem may nest ONE level when it has genuinely separable layers
# (src/<group>/<subsystem>/<layer>/<file>.zig). Never deeper. Asset blobs may nest freely.
check "no .zig deeper than <group>/<subsystem>/<layer>/" \
    "hoist it; only non-code assets may nest further" \
    find src -mindepth 5 -name '*.zig'

# Prose under src/ rots, because nothing compiles it. Grounding belongs in the doc
# comment of the module it grounds, where a reader of the code will actually meet it.
# A subsystem's own README.md is its map and stays.
check "no reference material under src/" \
    "fold it into the owning module's doc comment, or into the group's README.md" \
    find src -name '*.md' ! -name README.md

# kudos is GPU-only (ARCH-015: the desktop is never CPU-rasterised while the GPU is
# present): the software rasteriser (drivers/gl/soft.zig) renders the product's
# desktop nowhere. It has exactly two legitimate reachers — test/, and src/main_root.zig's
# `-Dsoft-display` bring-up, which publishes it as a draw device only on an emulator that
# has no GPU. Both go through the `soft` MODULE; a relative-path import is how the CPU
# renderer would creep back in as an ordinary dependency, so that is what is banned.
# src/main_root.zig is the sole file allowed to name the module: the publish decision has one home,
# and no compositor or window code may reach the backend directly.
# An address-space switch is a REGISTER WRITE of a value computed once at session
# setup: sessionspace.cr3Of is a field read, sched.setAddressSpace takes the u64 it
# returns. Nothing on that path may allocate (MEM-009) — a switch happens on every
# context switch, so an allocation there is unbounded work on the hot path. The
# matcher is proven live: pointed at sessionspace.create it reports that function's
# allocations, so an allocation appearing in either switch function would be caught.
check "an address-space switch allocates nothing (MEM-009)" \
    "the switch takes a precomputed CR3 value — keep allocation out of cr3Of/setAddressSpace" \
    awk '/pub fn (cr3Of|setAddressSpace)/{f=1} f&&/\.alloc\(|allocator|create\(/{print FILENAME":"NR": "$0} f&&/^}/{f=0}' src/kernel/memory/sessionspace.zig src/kernel/sched/sched.zig

# A loaded module runs in the address space of the session that ran it (MOD-006):
# `run` carves the image and the app's arena from THAT session's private region,
# so the module is only ever mapped where its session is. A heap allocation here
# would put the image in kernel memory every session can reach.
check "a module is carved from its session's own space (MOD-006)" \
    "run.zig must carve the image from sessionspace's private region, never the shared heap" \
    grep -nE "\.alloc\(|std\.heap|allocator" src/console/cmd/run.zig

check "soft.zig is reached only as a module, never by path" \
    "the desktop renders on the GPU; import the 'soft' module from src/main_root.zig or delete this (see CLAUDE.md 'Rendering: GPU only')" \
    grep -rEn '@import\("(\.\./)*(drivers/gl/)?soft\.zig"\)' src/

check "only the soft-display bring-up names the soft module" \
    "the publish decision lives in drivers/gl/softdisplay.zig — nothing else may reach the CPU backend" \
    grep -rEn '@import\("soft"\)' src/ --include='*.zig' --exclude=softdisplay.zig

# Shaders are compiled offline and embedded; the target carries no shader compiler
# (ARCH-009). Absence is enforced the way the soft-rasteriser ban is: by name — the
# machinery a runtime compiler would need cannot appear in src/ under its own name.
check "no shader compiler on target" \
    "shaders compile offline in scripts/shaders/ (ARCH-008); delete the on-target compilation path" \
    grep -rEni '\bglslang\b|\bshaderc\b|glCompileShader|glShaderSource' src/

# src/ ROOT HOLDS MODULE ROOTS AND NOTHING ELSE. A Zig module's import path is its
# own directory, so the three files that must resolve imports across every group —
# the two kernel entry points and the host-test root — are forced to sit here. An
# ordinary file at the top is not forced, it has just escaped its group: pump.zig
# floated here for a release before landing in boot/. The *_root.zig suffix makes
# "this is a module root" checkable rather than remembered.
check "src/ root holds only *_root.zig module roots" \
    "move it into the group it belongs to — only module roots may sit at src/ root" \
    find src -maxdepth 1 -name '*.zig' ! -name '*_root.zig'

# The top-level groups are a FIXED set (CLAUDE.md: "New subsystem = a real decision.
# New group = no"). A new directory here is an architecture change, so it fails until
# it is added to this list AND given a K-level in klevel() above.
GROUPS_ALLOWED="agent apps boot console drivers iface kernel ui widgets"
unknown_groups() {
    local d g
    for d in src/*/; do
        g="$(basename "$d")"
        case " $GROUPS_ALLOWED " in
            *" $g "*) ;;
            *) echo "src/$g is not a declared top-level group" ;;
        esac
    done
    # test/ mirrors src/, plus `support` for shared fakes.
    for d in test/*/; do
        g="$(basename "$d")"
        case " $GROUPS_ALLOWED support " in
            *" $g "*) ;;
            *) echo "test/$g mirrors no source group" ;;
        esac
    done
}
check "every top-level directory is a declared group" \
    "add it to GROUPS_ALLOWED and give it a K-level in klevel() — a new group is an architecture decision" \
    unknown_groups

# Name the thing, not its role (CLAUDE.md). These suffixes describe a file's job
# title rather than its subject, and they are where unrelated code accumulates.
check "no _impl/_utils/_helper/_manager files" \
    "name it for what it IS — the concern, not the role it plays" \
    find src test -name '*_impl.zig' -o -name '*_util*.zig' -o -name '*_helper*.zig' -o -name '*_manager.zig'

# Runtime abstractions live only at REAL seams — hardware, IO, time, network,
# randomness (spec ARCH-004). The interface layer is therefore a CLOSED set: a new
# contract is an architecture decision, declared here or refused at review.
IFACE_ALLOWED="iaccel iblockdev idesk idevices idisplay idraw ifilesys ilog imouse inet ipci ipresent iramdisk ivirt iwindow"
undeclared_ifaces() {
    local f stem
    for f in src/iface/*.zig; do
        stem="$(basename "$f" .zig)"
        case " $IFACE_ALLOWED " in *" $stem "*) ;; *) echo "$f" ;; esac
    done
}
check "the interface layer is a closed, declared seam set (ARCH-004)" \
    "a new runtime abstraction is an architecture decision — declare it in IFACE_ALLOWED, or pass a value instead of a dependency" \
    undeclared_ifaces

# A contract must not reach into an implementation (spec ARCH-002). The point of
# the interface layer is that the subsystems either side of it stay MUTUALLY
# UNAWARE; a contract that imports a driver, an app or the desktop has connected
# them after all, and the seam is decorative.
#
# What this checks and what it does not: it enforces the mutual-unawareness half
# of ARCH-002 — contracts may name only `std`, other contracts, and kernel
# primitives. The "never logic" half is not machine-checkable and is not claimed
# here; src/iface/ivirt.zig genuinely carries rings and counters, which is a
# known deviation recorded against ARCH-002 rather than hidden behind a green
# check.
iface_reaches_down() {
    local f imp
    for f in src/iface/*.zig; do
        [ -f "$f" ] || continue
        while read -r imp; do
            case "$imp" in
                std|abi|ring|input_latency) continue ;;          # primitives
                *) [ -f "src/iface/${imp}.zig" ] || echo "$f imports '$imp' (not a contract or primitive)" ;;
            esac
        done < <(grep -ohE '@import\("[^"]+"\)' "$f" | sed 's/@import("//; s/")//')
    done
}
check "an interface contract names no implementation (ARCH-002)" \
    "a contract that imports a driver, app or the desktop has connected the two sides it exists to keep apart" \
    iface_reaches_down

# One conformance suite per shared contract (spec TEST-003): every contract that a
# real driver and a fake both implement is exercised by ONE vector suite that every
# implementation passes — the fake cannot drift from the device it stands in for.
CONFORMANCE_CONTRACTS="iramdisk ifilesys iblockdev"
missing_conformance() {
    local c
    for c in $CONFORMANCE_CONTRACTS; do
        [ -f "test/iface/${c}_conformance.zig" ] || echo "test/iface/${c}_conformance.zig (for src/iface/${c}.zig)"
    done
}
check "every shared contract keeps its conformance suite (TEST-003)" \
    "a conformance file moved or was deleted — every implementation, real or fake, passes ONE suite" \
    missing_conformance

# ── Files & modularity (process.md §49–56): pairing, naming, size ──────────────────────

# Source and tests pair one-to-one (process.md §53). build.zig's host-suite table IS the
# pairing manifest: an `.s` row without `.t` promises test/<stem>_test.zig; an explicit
# `.t` (or an ad-hoc addTest block) names its file outright. Both directions are checked
# here with no build — a row whose test file is missing and a test file no row reaches
# are the same rot seen from opposite ends.
unpaired_suite_rows() {
    local t s stem
    # Every test/*.zig path build.zig spells out must exist on disk. A `{` marks a
    # b.fmt template (the default-pairing rule itself), not a path.
    grep -oE '"test/[^"{]+\.zig"' build.zig | tr -d '"' | sort -u | while read -r t; do
        [ -f "$t" ] || echo "build.zig names $t, which does not exist"
    done
    # Every `.s` row with no `.t` override pairs by default with the MIRRORED
    # path: src/<group.../file>.zig pairs with test/<group...>/<file>_test.zig.
    grep -E '\.s = "src/[^"]+\.zig"' build.zig | grep -v '\.t = ' \
        | sed -E 's/.*\.s = "([^"]+)".*/\1/' | while read -r s; do
        stem="$(basename "$s" .zig)"
        d="$(dirname "$s")"; d="test/${d#src/}"; [ "$d" = "test/src" ] && d=test
        [ -f "$d/${stem}_test.zig" ] || echo "$s row expects $d/${stem}_test.zig, which does not exist"
    done
}
orphan_test_files() {
    local f name stem
    for f in $(find test -name '*.zig'); do
        name="$(basename "$f")"
        # Named outright in build.zig (a `.t` override or an ad-hoc addTest block).
        grep -qF "\"$f\"" build.zig && continue
        # The default pairing: a `.t`-less `.s` row whose stem derives this file.
        # (Captured, not `grep -q`: -q ending a pipeline SIGPIPEs the upstream grep,
        # and under pipefail that reads as a random miss.)
        stem="${name%_test.zig}"
        if [ "$stem" != "$name" ] && [ -n "$(grep -E "\.s = \"[^\"]*/${stem}\.zig\"" build.zig \
            | grep -v '\.t = ' || true)" ]; then
            continue
        fi
        # A sibling suite composes it directly (relative import in the same
        # dir), or it is a shared test/support module composed by name.
        grep -qrF "@import(\"$name\")" test/ && continue
        modname="${name%.zig}"
        grep -qF "b.path(\"test/support/${name}\")" build.zig && continue
        echo "$f is reachable from no build.zig suite"
    done
}

check "every build.zig host-suite row has its test file" \
    "write the test, or point the row's .t at the file that holds it" \
    unpaired_suite_rows

# Wired is not the same as RUN (process.md §17). A suite attached only to a manual
# step (`zig build screenshot`) never executes in the gate, so it rots unseen — and
# one had: desktop_shot.zig would not even compile, its Timer API removed by a
# toolchain migration nobody's suite exercised. Every addTest must reach test_step.
untested_suites() {
    awk '
        /const t = b.addTest\(/ { file=$0; sub(/.*b.path\("/, "", file); sub(/".*/, "", file); wired=0 }
        /testWired\(test_only, t\)/ { wired=1 }
        /^    \}$/ { if (file != "" && wired == 0) print file " is built as a test but never reaches `zig build test`"; file=""; wired=0 }
    ' build.zig
}

check "every addTest suite runs in the gate, not only behind a manual step" \
    "add: if (testWired(test_only, t)) test_step.dependOn(&b.addRunArtifact(t).step);" \
    untested_suites

check "every test/ file is wired into build.zig" \
    "add a host-suite row — an unwired test is a comment (CLAUDE.md Tests)" \
    orphan_test_files

# One naming pattern per kind (process.md §50): a test file's suffix says what it is —
# _test (unit suite), _sim (a fake and its contract tests), _conformance (a shared
# contract suite), _shot (a rendered capture). percept.zig is the one bare module: the
# perceptual-diff metric two suites sibling-import; its own pins live in
# percept_test.zig. fixtures/ holds corpora, not code, so only the top level is named.
check "test/ files follow the suffix convention" \
    "name it *_test/_sim/_conformance/_shot.zig — or record a new kind here" \
    find test -name '*.zig' \
        ! -name '*_test.zig' ! -name '*_sim.zig' ! -name '*_conformance.zig' \
        ! -name '*_shot.zig' ! -name 'percept.zig'

# The mirror image: nothing in src/ wears a test suffix. A module-root shim that exists
# only so host tests can resolve a file's relative imports is *_testroot.zig — a shim
# is a path, not a test, and the distinct suffix keeps that visible.
check "src/ files never wear a test suffix" \
    "move it to test/ (module-root shims are *_testroot.zig)" \
    find src \( -name '*_test.zig' -o -name '*_sim.zig' \
        -o -name '*_conformance.zig' -o -name '*_shot.zig' \)

# Size tracks cohesion (process.md §51): past 1000 lines a file needs a recorded reason to
# stay whole, and this allowlist IS the record — one entry, one justification. The DEBT
# entries mark a planned split, they do not bless the size: they leave the list through
# the split. Nothing joins the list without a human writing the reason down.
SRC_FILE_LINES_MAX=1000
size_justified() {
    case "$1" in
    src/drivers/usb/xhci.zig) ;;            # pending its designed decomposition — do not grow it further
    src/drivers/net/stack/tlsclient.zig) ;; # vendored-shape TLS client: one wire protocol, one file
    src/drivers/storage/fat.zig) ;;         # single-concern FAT16/FAT32 driver
    src/ui/assets/jpeg.zig) ;;              # single-concern baseline+progressive JPEG decoder
    src/drivers/gl/soft.zig) ;;             # host-test fixture: the software IDraw twin of the GPU path
    src/drivers/gl/es/gl.zig) ;;            # GLES 1.1 API facade: every spec entry point, spec-shaped
    src/ui/desktop/desktop.zig) ;;          # DEBT: split planned — this entry marks it, not blesses it
    src/drivers/gl/opengl.zig) ;;           # DEBT: split planned — this entry marks it, not blesses it
    *) return 1 ;;
    esac
}
oversized_src_files() {
    local f lines
    while IFS= read -r f; do
        lines="$(wc -l < "$f")"
        [ "$lines" -gt "$SRC_FILE_LINES_MAX" ] || continue
        size_justified "$f" || echo "$f: $lines lines, and no justification on the allowlist"
    done < <(find src -name '*.zig')
}

check "src/ files past ${SRC_FILE_LINES_MAX} lines carry a written justification" \
    "split it along a seam (concern, layer, client) — or add it above, with the reason" \
    oversized_src_files

# A god module — one that everything imports AND that imports everything — is a layering
# failure that no single edge check sees (process.md §52). High fan-in alone is a healthy
# leaf (log, tsc); high fan-out alone is a composition root (main). It is the pair that
# marks orchestration and dependency tangled in one file. Fan-in is counted by basename,
# so same-named files in different groups pool their counts — the thresholds stay
# generous to keep that imprecision harmless. The allowlist records the known debt.
FAN_OUT_MAX=15
FAN_IN_MAX=20
god_justified() {
    case "$1" in
    src/kernel/sched/sched.zig) ;; # DEBT: split planned (dispatch vs. accounting vs. wake) — marks it, not blesses it
    *) return 1 ;;
    esac
}
god_modules() {
    local f out base in
    while IFS= read -r f; do
        out="$(grep -c '@import(' "$f")"
        [ "$out" -gt "$FAN_OUT_MAX" ] || continue
        base="$(basename "$f")"
        in="$(grep -rl "import(\"[^\"]*$base\")" src --include='*.zig' | wc -l)"
        [ "$in" -gt "$FAN_IN_MAX" ] || continue
        god_justified "$f" || echo "$f: fan-in $in, fan-out $out — split it or demote it"
    done < <(find src -name '*.zig')
}

check "no unrecorded god modules (fan-in > ${FAN_IN_MAX} and fan-out > ${FAN_OUT_MAX})" \
    "split along a seam or record the debt above with the planned split" \
    god_modules

# Every interface contract is in the host compile sweep (ARCH-003): a src/iface file
# missing from test/iface/contracts_test.zig is a contract only the kernel build ever
# compiles — the exact drift the sweep exists to prevent.
iface_sweep_missing() {
    local f n
    for f in src/iface/*.zig; do
        n="$(basename "$f" .zig)"
        grep -q "@import(\"$n\")" test/iface/contracts_test.zig \
            || echo "$f is not imported by test/iface/contracts_test.zig"
    done
}

check "every interface contract is in the host compile sweep (ARCH-003)" \
    "add the @import to test/iface/contracts_test.zig and wire the module in build.zig" \
    iface_sweep_missing

# ── Blast radius (process.md §Blast-radius levels) ──────────────────────────────────────
#
# Every top-level source group carries a K-level — the blast radius of its failure.
# K1 machine, K2 subsystem, K3 session, K4 dev-only. Inheritance is the import graph the
# checks above already police: K1 code can only reach what its allowed edges name, so the
# map below is the assignment record, and the check is completeness — a new group must be
# leveled the day it appears, because an unleveled group is unanalyzed behavior.
klevel() {
    case "$1" in
    kernel) echo K1 ;;   # a defect can stop, wedge, or corrupt the machine
    boot)   echo K1 ;;   # the apex: composes every group and runs the steady-state
                         # loop, so a defect here stops the machine like a kernel one
    iface)  echo K1 ;;   # contracts compiled into K1 paths inherit K1
    drivers) echo K2 ;;  # a defect can take a subsystem or a device for all its users
    console) echo K3 ;;  # session plumbing — contained by K1 machinery
    ui)     echo K3 ;;
    widgets) echo K3 ;;
    apps)   echo K3 ;;
    agent)  echo K3 ;;   # the in-kudos agent runs contained, capability-scoped
    *) return 1 ;;
    esac
}
# The composition root (src/*.zig: main, main_smp, pump) is boot policy wired into the
# kernel — K1 by inheritance. *_testroot.zig shims, scripts/ and test/ are K4: never on
# the product image.
unleveled_groups() {
    local d g
    for d in src/*/; do
        g="$(basename "$d")"
        klevel "$g" > /dev/null || echo "src/$g has no K-level — assign one in klevel() above"
    done
}

check "every top-level source group carries a K-level" \
    "add the group to klevel() with its level and the reason (process.md §Blast radius)" \
    unleveled_groups

echo "  blast radius: $(for d in src/*/; do g="$(basename "$d")"; l="$(klevel "$g" || echo '??')"; printf '%s=%s ' "$g" "$l"; done)"

# An RX dispatch handler runs inside net.pump(), which runs inside the 60 Hz session
# loop (boot/pump.zig). Two things follow, and both are invariants rather than taste:
#
#   1. It must not block. resolveMac() waits up to ARP_RESOLVE_TIMEOUT_MS for an ARP
#      reply, so one frame from an un-cached host would stall the compositor for that
#      whole budget — the deadline PERF-003 and PERF-007 exist to protect.
#   2. It must not re-enter pump(). The frame it is parsing is a slice of the NIC's
#      single `scratch` staging buffer; a nested pump() refills that buffer, so every
#      read of the frame after the nested call returns another packet's bytes.
#
# Resolve the next hop before dispatch, or defer the response to a later pump.
blocking_rx_handler() {
    awk '
      /^(pub )?fn handle/ { inh=1; name=$0; sub(/\(.*/,"",name); sub(/^(pub )?fn /,"",name); next }
      inh && /^}/         { inh=0; next }
      /^[[:space:]]*\/\// { next }
      inh && /resolveMac\(|[^a-zA-Z_.]pump\(/ {
          printf "src/drivers/net/stack/net.zig:%d: %s() calls %s inside the RX dispatch\n", \
                 NR, name, ($0 ~ /resolveMac/ ? "resolveMac()" : "pump()")
      }
    ' src/drivers/net/stack/net.zig
}

check "no RX dispatch handler blocks or re-enters net.pump()" \
    "resolve the next hop before dispatch, or defer the reply to a later pump" \
    blocking_rx_handler

# An orderly FIN and a peer RST are different facts, and a READER must not merge them.
# A FIN ends a close-delimited body: everything sent arrived. A RST abandons it: the
# body is truncated. Collapsing both into "0 bytes, end of stream" makes a torn transfer
# indistinguishable from a complete one — on the TLS path, exactly the truncation an
# attacker injects a RST to cause. Merging them to answer "is the connection closed?"
# is fine and stays unflagged; the defect is specifically yielding EOF from a reset.
# Enforced by shape: this greps for the known one-line collapse, so a differently
# shaped merge of RST into EOF passes it.
check "no one-line 'finished() or wasReset() → return 0' EOF collapse" \
    "return a distinct error for wasReset(); only finished() means EOF" \
    grep -rnE '(finished\(\)[[:space:]]*or[[:space:]]+[a-z]+\.wasReset\(\)|wasReset\(\)[[:space:]]*or[[:space:]]+[a-z]+\.finished\(\)).*return 0' src/drivers/net/

if [ "$fail" -ne 0 ]; then
    echo
    echo "layering: FAIL — the rules above are in CLAUDE.md, and they are not decorative."
    exit 1
fi
echo "  layering: clean"
