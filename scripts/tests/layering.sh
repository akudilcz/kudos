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
#
# And every contract carries a DISPOSITION: whether a loaded .kudos module may bind
# it (MOD-007) or whether it stays kernel-only, with the reason recorded. The
# question "can untrusted code reach this?" then has an answer for all of them, and
# a new contract fails this gate until someone gives it one — "nobody decided" is
# not a security posture, and it is the state a growing interface layer drifts into
# on its own.
#
# A contract is never published RAW: every one of them is Zig-typed (slices, error
# unions, tagged unions), which cannot cross the C ABI a module binds through. What
# a published row names is the capability in abi.zig whose vtable MIRRORS that
# contract, and the mirror is where the bounds and the copies live.
#
#   <contract>:<app|feature|kernel>:<capability or ->:<reason>
#     app      may be bound by a sandboxed application module (and so by a feature)
#     feature  may be bound only by a hot-loaded feature module, at full kernel trust
#     kernel   not published to any module
#
# A row states the DECISION and the capability that carries it. Whether kudos
# publishes it TODAY is a different question with its own answer: the grant table
# (src/console/grants.zig) is what is published, and `caps` on a running machine is
# what is live. So an `app` row whose capability has no grant row yet is an adapter
# still to be written, not a contradiction.
IFACE_DISPOSITION="
iaccel:kernel:-:raw scanout VA and the compositor entry — code holding this needs no kernel
iblockdev:kernel:-:raw sectors; the bounded view is the vfs capability
idesk:feature:desk:the window list and acting on a window — machine-level control
idevices:kernel:-:a pull seam over live driver state; no module-facing mirror of it exists
idisplay:app:metrics:frame timing, read-only
idraw:kernel:-:the rasteriser command sink, valid only inside core 0's open frame
ifilesys:app:vfs:the file system beyond the module's ramdisk sandbox
ilog:kernel:-:the kernel trace; a feature reaches it through FeatureApi.log and an app through Api.print, so nothing is bound
imouse:app:input:pointer events for the module's own focused window
inet:app:net:the network stack
ipci:kernel:-:raw hardware enumeration
ipresent:kernel:-:GPU submit and flip; K1, and core-0 only
iramdisk:kernel:-:the base Api already carries file_read/file_write over it
iscene:app:gl:recorded 3D replayed into the module's window; validated before any GL call
ivirt:feature:guests:guest virtual machines — machine-level control
iwindow:app:window:the module's own windows, pixels copied on the module's own core
"

# Every contract has exactly one row, and only the declared dispositions exist.
iface_disposition_rows() {
    local f stem row
    for f in src/iface/*.zig; do
        stem="$(basename "$f" .zig)"
        row="$(printf '%s\n' "$IFACE_DISPOSITION" | grep -c "^$stem:")"
        [ "$row" = 1 ] || echo "$f has $row disposition rows (want exactly 1)"
    done
    printf '%s\n' "$IFACE_DISPOSITION" | grep -v '^[[:space:]]*$' | while IFS=: read -r stem disp cap reason; do
        [ -f "src/iface/$stem.zig" ] || echo "$stem is declared but src/iface/$stem.zig does not exist"
        case "$disp" in
            app|feature|kernel) ;;
            *) echo "$stem has disposition '$disp' (want app, feature or kernel)" ;;
        esac
        [ -n "$reason" ] || echo "$stem states no reason for its disposition"
        # kernel-only rows name no capability; published rows must name one.
        case "$disp" in
            kernel) [ "$cap" = "-" ] || echo "$stem is kernel-only but names capability '$cap'" ;;
            *) [ "$cap" != "-" ] || echo "$stem is published but names no capability" ;;
        esac
    done
}
check "every interface contract is a closed, declared seam with a disposition (ARCH-004, MOD-007)" \
    "declare the contract in IFACE_DISPOSITION — publish it to modules with its capability, or record why it stays kernel-only" \
    iface_disposition_rows

# A published row is a claim with two halves, and both are checkable: the ABI must
# DEFINE that capability (an id in abi.zig's Interface), and the registry must
# publish it (a row in the grant table). A claim here that neither file backs is a
# capability that exists only in this comment.
iface_published_backing() {
    printf '%s\n' "$IFACE_DISPOSITION" | grep -v '^[[:space:]]*$' | while IFS=: read -r stem disp cap _; do
        [ "$disp" = kernel ] && continue
        grep -qE "^    $cap = [0-9]+,$" src/kernel/loader/abi.zig \
            || echo "$stem names capability '$cap', which abi.zig's Interface does not define"
    done
}
check "a published contract's capability exists in the ABI (MOD-007)" \
    "add the id to abi.Interface, or correct the disposition row" \
    iface_published_backing

# A contract is reached BY NAME (`@import("iwindow")`), never by relative path.
# The name is what makes it a contract wired in one place (build.zig's iface_mods)
# rather than a file two groups happen to reach into — and a relative import from
# two groups is how a shared mailbox quietly becomes two instances.
iface_relative_imports() {
    grep -rEn '@import\("(\.\./)+iface/' src/ || true
}
check "an interface contract is imported by name, not by path (ARCH-002)" \
    "wire it into build.zig's iface_mods and @import(\"<name>\")" \
    iface_relative_imports

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


# ── THE GROUP EDGE TABLE ─────────────────────────────────────────────────────
#
# CLAUDE.md promises "layers and allowed edges live in one manifest"; before
# this, exactly two edges were checked (ui↔drivers) and the tree had drifted in
# every direction the gate could not see — the kernel importing a driver, the
# console importing the desktop it sits below, the app catalogue owned by the
# lowest group that happened to need it.
#
# One row per group: who it may reach by RELATIVE import. `boot` is the apex and
# may know everyone (that is what the apex IS); `kernel` reaches nothing above
# it; `iface` holds contracts and is checked separately below.
GROUP_EDGES="
kernel:iface
drivers:kernel iface
console:kernel drivers agent iface
agent:kernel console iface
apps:kernel console ui widgets iface
ui:kernel console apps widgets iface
widgets:iface
boot:kernel drivers console agent apps ui widgets iface
"

# Edges the tree still has and that are NOT yet legal — each one named, with the
# reason it survives. A row here is a debt, not a blessing: it leaves this list
# by being fixed. Empty is the goal.
EDGE_DEBT="
console/agenttools.zig->drivers:the agent's machine-side tool surface reaches the screenshot and input drivers; it moves behind idesk/the input seam
ui/desktop/hud.zig->kernel:the heads-up display reads guest state straight from the hypervisor; it wants an ivirt readback
ui/desktop/lifecycle.zig->kernel:spawnVmWindow asks the hypervisor which core a guest is on; it wants an ivirt slot field
"

# Every relative cross-group import, as `<file>-><group>` pairs. The import is
# RESOLVED against the importing file's directory before its group is read: a
# `../screen/` from ui/desktop lands back inside ui/ and is not an edge at all,
# while `../../drivers/` from kernel/timer genuinely leaves the group.
group_edges_found() {
    python3 - <<'PY'
import os, re, subprocess
out = set()
for root, _, files in os.walk('src'):
    for fn in files:
        if not fn.endswith('.zig'):
            continue
        path = os.path.join(root, fn)
        rel = os.path.relpath(path, 'src')
        frm = rel.split(os.sep)[0]
        if frm == 'iface' or os.sep not in rel:
            continue
        try:
            text = open(path, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        for target in re.findall(r'@import\("((?:\.\./)+[^"]+)"\)', text):
            resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
            parts = resolved.split(os.sep)
            if len(parts) < 2 or parts[0] != 'src':
                continue
            to = parts[1]
            if to != frm:
                out.add(f"{rel}->{to}")
for line in sorted(out):
    print(line)
PY
}

# An edge is legal if the from-group declares the to-group, or a debt row names
# this exact file and target.
illegal_group_edges() {
    local pair file from to allowed
    group_edges_found | sort -u | while IFS= read -r pair; do
        file="${pair%%->*}"; to="${pair##*->}"
        from="${file%%/*}"
        allowed="$(printf '%s\n' "$GROUP_EDGES" | grep "^$from:" | cut -d: -f2)"
        case " $allowed " in *" $to "*) continue ;; esac
        printf '%s\n' "$EDGE_DEBT" | grep -q "^$file->$to:" && continue
        echo "$file imports $to/, which $from/ may not reach (GROUP_EDGES)"
    done
}
check "every cross-group import is a declared edge" \
    "route it through a contract in src/iface/, move the file to the group that owns it, or declare the edge" \
    illegal_group_edges

# A debt row that no longer matches a real edge is a rule pretending to be debt.
stale_edge_debt() {
    local found; found="$(group_edges_found | sort -u)"
    printf '%s\n' "$EDGE_DEBT" | grep -v '^[[:space:]]*$' | while IFS=: read -r pair _; do
        printf '%s\n' "$found" | grep -qx "$pair" || echo "$pair is recorded as debt but no longer exists — delete the row"
    done
}
check "no stale edge debt" "the edge is gone; remove its EDGE_DEBT row" stale_edge_debt

# NO TWO-WAY GROUP EDGES. A cycle means neither group can be understood, built
# or tested without the other, and it is invisible to a per-edge rule: each
# direction looks locally reasonable. ui↔apps is the live one — the desktop
# hosts the apps and the apps draw into the desktop's windows.
GROUP_CYCLE_DEBT="apps<->ui"
group_cycles() {
    local pairs; pairs="$(group_edges_found | sed 's|/[^>]*->|->|' | sort -u)"
    printf '%s\n' "$pairs" | while IFS= read -r e; do
        local a b
        a="${e%%->*}"; b="${e##*->}"
        [ "$a" \< "$b" ] || continue
        printf '%s\n' "$pairs" | grep -qx "$b->$a" || continue
        printf '%s\n' "$GROUP_CYCLE_DEBT" | grep -qx "$a<->$b" && continue
        echo "$a/ and $b/ import each other — one of them belongs below the other"
    done
}
check "no two-way group dependencies" \
    "invert one direction through a contract, or declare the cycle as debt" \
    group_cycles

# ── THE NAMED-MODULE CHANNEL ─────────────────────────────────────────────────
#
# build.zig publishes modules by NAME onto the kernel root, so `@import("vfs")`
# from any file resolves with no relative path for the rules above to see. The
# contracts belong there — that is what a contract is for — but everything else
# is a cross-group shortcut that must be a DECLARED decision, not a name someone
# added. This does not grant per-group access (a bigger change); it closes the
# channel to newcomers, so adding a backdoor costs a line here and a reason.
MODULE_CHANNEL="
abi:the module ABI — a contract in all but its directory
algn:alignment math, the ONE home (CLAUDE.md 'Duplication')
job:the cooperative job shape, shared by the runner and its clients
ring:the SPSC ring every mailbox is built from
surface:the pixel-buffer type the whole UI stack passes around
theme:the palette, one home
rects:pure rectangle math
sampler:pure timed-series math
barfill:pure bar geometry
truetype:the scalable font rasteriser
gltext:GL text geometry
glyphcache:the glyph atlas
typeface:the face the HUD sets its figures in
panel:HUD widget toolkit
meter:HUD widget toolkit
stackbar:HUD widget toolkit
sparkline:HUD widget toolkit
statile:HUD widget toolkit
hudview:the HUD view, host-tested away from the desktop
hudcontrol:the HUD's control state, host-tested
gles:the GL ES state machine — the ONE way to draw 3D (ARCH-006)
kgl:the 2D toolkit the desktop draws through (ARCH-005)
soft:the software rasteriser, gated to softdisplay.zig by its own rule above
manifest:the offline-compiled shader table
overlay_plane:pure overlay-plane geometry
hostpush:pure pushbuffer encoding
input_latency:the PERF-008 latch both sides of the accel seam read
keymap:pure scancode mapping
vfs:the file-system namespace the whole machine names paths in
fileproto:the KMR1 wire protocol, pure and host-tested
modelcache:decoded-asset cache shared by the viewer and the desktop
"
undeclared_named_modules() {
    local n path
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        path="$(grep -oE "\-M$n=[^ ]*" /dev/null 2>/dev/null)"
        # A contract needs no row: src/iface/<name>.zig is the declaration.
        [ -f "src/iface/$n.zig" ] && continue
        printf '%s\n' "$MODULE_CHANNEL" | grep -q "^$n:" ||
            echo "build.zig publishes '$n' onto every file, and MODULE_CHANNEL does not declare why"
    done < <(sed -n '/const iface_mods = \[_\]IfaceMod{/,/^    };/p' build.zig |
        grep -oE '\.name = "[a-z_0-9]+"' | sed 's/.*"\(.*\)"/\1/')
}
check "every by-name module is a contract or a declared shortcut" \
    "declare it in MODULE_CHANNEL with the reason, or wire it per-group instead of onto the root" \
    undeclared_named_modules

# A MODULE_CHANNEL row for a name build.zig no longer publishes is a stale rule.
stale_module_channel() {
    local published; published="$(sed -n '/const iface_mods = \[_\]IfaceMod{/,/^    };/p' build.zig |
        grep -oE '\.name = "[a-z_0-9]+"' | sed 's/.*"\(.*\)"/\1/')"
    printf '%s\n' "$MODULE_CHANNEL" | grep -v '^[[:space:]]*$' | while IFS=: read -r n _; do
        printf '%s\n' "$published" | grep -qx "$n" || echo "MODULE_CHANNEL declares '$n', which build.zig no longer publishes"
    done
}
check "no stale MODULE_CHANNEL rows" "delete the row; the module is gone" stale_module_channel

# ── DIRECTORIES NAME THINGS, NOT ROLES ───────────────────────────────────────
#
# The file-level ban on _impl/_utils/_helper/_manager exists because a name that
# states a ROLE attracts anything that can claim the role. A DIRECTORY so named
# does it faster: `base/` and `core/` had collected an ABI mirror, an OS shim, a
# PNG encoder, a logging wrapper and three unrelated pieces of maths between
# them, none of which the name would ever have argued against.
role_named_dirs() {
    find src -type d \( -name base -o -name core -o -name common -o -name misc \
        -o -name util -o -name utils -o -name helpers -o -name shared \) 2>/dev/null
}
check "no role-named directories" \
    "name the directory for what is IN it (gpu/rm, gpu/engines), not for the role it plays" \
    role_named_dirs

# ── ONE RING ─────────────────────────────────────────────────────────────────
#
# kernel/sync/ring.zig is the SPSC ring, and its release/acquire ordering is the
# reason a mailbox between two cores works. A hand-rolled `head`/`tail` index
# pair beside it is that reasoning re-derived by hand, and it has been wrong:
# fileserv's intake ring let two servicing tasks consume one request and advance
# the head twice, deafening remote control for a full lap of the ring.
#
# Non-atomic rings are legitimate where producer and consumer are provably one
# thread; they are listed, so each is a decision.
RING_BY_HAND="
src/kernel/virt/uart16550.zig:a guest's own serial FIFOs — one vCPU thread produces and consumes
src/drivers/gpu/present/fps_window.zig:a rolling FPS window sampled and read on the session loop alone
src/drivers/net/debug/linestore.zig:the trace line store, whose producer/consumer discipline is its own subject
src/drivers/storage/bootlog.zig:a BYTE ring, not an element mailbox: klog feed memcpys in (possibly from an IRQ), the service step drains whole sectors out
"
hand_rolled_rings() {
    local f
    while IFS= read -r f; do
        printf '%s\n' "$RING_BY_HAND" | grep -q "^$f:" && continue
        grep -qE '^var (head|tail): usize' "$f" 2>/dev/null && echo "$f keeps a bare head/tail index pair"
    done < <(find src -name '*.zig' -not -path 'src/kernel/sync/*')
}
check "no hand-rolled rings outside kernel/sync" \
    "use kernel/sync/ring.zig, or list the file in RING_BY_HAND with why one thread owns both ends" \
    hand_rolled_rings

# ── THE SHADER TWIN ──────────────────────────────────────────────────────────
#
# The PBR lighting model exists twice by necessity: once in Zig (the software
# rasteriser, which host tests can run) and once in GLSL (what the 4090 runs).
# They must agree, and no compiler can check that they do — the two never meet.
# When they last disagreed, the fix had to land in both and the mismatch was
# only visible as different pixels on real hardware, costing a verification
# cycle to find.
#
# So the NUMBERS are checked here: the analytic environment and the ACES tone
# curve, extracted from each file and compared. A change to either side alone
# fails this, which is the point — it is not asking you to keep them the same
# forever, it is refusing to let them drift silently.
shader_twin_drift() {
    local zig="src/drivers/gl/soft.zig" frag="src/drivers/gl/shaders/f_pbr.frag"
    [ -f "$zig" ] && [ -f "$frag" ] || { echo "shader twin: $zig or $frag is missing"; return; }
    local z_env f_env z_aces f_aces
    # ENV_SKY / ENV_GROUND / ENV_EXPOSURE, as a flat list of numbers.
    z_env="$(grep -E 'const ENV_(SKY|GROUND|EXPOSURE)' "$zig" | grep -oE '[0-9]+\.[0-9]+' | tr '\n' ' ')"
    f_env="$(grep -E 'ENV_(SKY|GROUND|EXPOSURE) *=' "$frag" | grep -oE '[0-9]+\.[0-9]+' | tr '\n' ' ')"
    [ "$z_env" = "$f_env" ] ||
        echo "analytic environment differs: soft.zig has [$z_env], f_pbr.frag has [$f_env]"
    # The ACES curve's five coefficients, from the scalar Zig form and the GLSL.
    # The first FIVE numbers on that line are the curve; GLSL's clamp bounds
    # (0.0, 1.0) trail it and are not coefficients.
    z_aces="$(grep -E '2\.51 \* x' "$zig" | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -5 | tr '\n' ' ')"
    f_aces="$(grep -E '2\.51 \* x' "$frag" | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -5 | tr '\n' ' ')"
    [ -n "$z_aces" ] || echo "ACES curve not found in soft.zig (did the scalar form move?)"
    [ "$z_aces" = "$f_aces" ] ||
        echo "ACES tone curve differs: soft.zig has [$z_aces], f_pbr.frag has [$f_aces]"
}
check "the software and GPU PBR twins agree on their constants" \
    "change BOTH src/drivers/gl/soft.zig and src/drivers/gl/shaders/f_pbr.frag — they are one lighting model in two languages" \
    shader_twin_drift

# Scripts are consistent and self-describing (process.md §54). The split below is the whole
# rule: a script you can RUN must fail loudly and say what it is for, and a script you
# SOURCE must not reach into its caller's shell and change the options there. Executability
# is the discriminator, so neither half needs an allowlist — the answer is a property of the
# file, not a list someone maintains.
script_discipline() {
    local f
    while IFS= read -r f; do
        [ "$(sed -n '2p' "$f" | cut -c1)" = "#" ] ||
            echo "$f: no usage header — line 2 must begin the comment block saying what it does"
        if [ -x "$f" ]; then
            head -1 "$f" | grep -q '^#!' || echo "$f: executable with no shebang"
            grep -qE '^set -' "$f" ||
                echo "$f: executable but sets no shell options (set -euo pipefail, or the -e-less form the gates use)"
        else
            grep -qE '^set -' "$f" &&
                echo "$f: sourced library, yet it sets shell options — those leak into every caller"
        fi
    done < <(find scripts -name '*.sh')
    return 0
}
check "every script carries a shebang and a usage header, and only runnable ones set shell options" \
    "add the header, or drop the set- line from a library that is meant to be sourced" \
    script_discipline

# The repository root stays canonical (process.md §55): it holds the entry points someone new
# needs and nothing else. The list below is that set, and it is deliberately short — a root
# that accumulates is the first sign of scratch files outliving the work that made them. A
# genuinely new entry point joins the list in the change that introduces it, never silently.
ROOT_ALLOWED="README.md CLAUDE.md process.md build.zig linker.ld Makefile LICENSE NOTICE
BUILD_NUMBER .gitignore .mcp.json .claude assets scripts specs src test"
stray_root_entries() {
    local e
    while IFS= read -r e; do
        case " $(echo $ROOT_ALLOWED) " in
        *" $e "*) ;;
        *) echo "$e: not a declared root entry point" ;;
        esac
    done < <(git ls-files | awk -F/ '{print $1}' | sort -u)
    return 0
}
check "the repository root stays canonical" \
    "move it into its group — or, if it really is an entry point someone new needs, add it to ROOT_ALLOWED above" \
    stray_root_entries

if [ "$fail" -ne 0 ]; then
    echo
    echo "layering: FAIL — the rules above are in CLAUDE.md, and they are not decorative."
    exit 1
fi
echo "  layering: clean"
