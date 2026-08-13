#!/usr/bin/env bash
# The requirement-trace gate: the spec's IDs (specs/*.md) and the test tree, kept
# honest both ways (process.md §Traceability). Runs in `make check` and costs
# nothing — no build.
#
# Direction 1 — every requirement is CITED: each ID in specs/*.md appears in a test
# (test/ or scripts/tests/), or sits on the uncited ratchet (reqtrace_uncited.txt),
# the shrinking record of requirements still awaiting their citation. The ratchet only
# tightens: an ID that gains a citation must leave the file in the same change, so
# progress can never silently regress.
#
# Direction 2 — every citation is real: an ID cited anywhere (source, tests, scripts,
# docs) whose prefix belongs to the spec must itself exist in specs/*.md. A retired or
# misspelled identifier is a citation of nothing.
#
# A citation records where the evidence is claimed to live. It does not itself
# establish that the cited test verifies the requirement — that is the reviewer's job.
set -uo pipefail
cd "$(dirname "$0")/../.."

ID_RE='\b[A-Z]{2,4}-[0-9]{3}\b'
RATCHET=scripts/tests/reqtrace_uncited.txt

spec_ids="$(grep -ohE "$ID_RE" specs/*.md | sort -u)"
prefixes="$(echo "$spec_ids" | sed 's/-.*//' | sort -u | paste -sd'|')"
# scripts/agent/ holds the agent-pipeline tests check.sh runs; its samples/ are
# fixtures — prose there cites requirements without verifying them, so it is excluded.
cited_by_tests="$(grep -rhoE "$ID_RE" test/ scripts/tests/ scripts/agent/ \
    --exclude-dir=samples --include='*.zig' --include='*.py' --include='*.sh' \
    2>/dev/null | sort -u)"
ratchet_ids="$(grep -vE '^\s*(#|$)' "$RATCHET" | sort -u)"

fail=0

# 1. Uncited and not on the ratchet: a requirement nobody verifies and nobody recorded.
missing="$(comm -23 <(echo "$spec_ids") <(sort -u <(echo "$cited_by_tests"; echo "$ratchet_ids")))"
if [ -n "$missing" ]; then
    echo "  ✗ requirement(s) with no test citation and no ratchet entry:"
    echo "$missing" | sed 's/^/      /'
    echo "      fix: cite the ID from the test that verifies it — or, for a NEW"
    echo "      requirement landing ahead of its test, add it to $RATCHET"
    fail=1
fi

# 1b. A test that cites a requirement in its NAME and then asserts nothing.
#
# The citation rule is deliberately generous — this project's convention is a
# comment naming the requirement immediately above the assertions that verify it,
# and that is a real citation. What is NOT a citation is an empty test body:
# `test "... (XXX-002)" {}` reads as coverage in every listing, satisfies the
# gate, and verifies nothing at all. An audit of all 254 requirements found one
# of exactly this shape, and it is the only citation form that can be judged
# worthless without reading the surrounding code — so it is the one the gate can
# honestly refuse.
empty_tests="$(grep -rhoE "^[[:space:]]*test \"[^\"]*($ID_RE)[^\"]*\"[[:space:]]*\{[[:space:]]*\}" \
    test/ --include='*.zig' 2>/dev/null | grep -ohE "$ID_RE" | sort -u)"
if [ -n "$empty_tests" ]; then
    echo "  ✗ requirement(s) cited by a test whose body is EMPTY — it cannot fail,"
    echo "    so it is a comment wearing a test's name:"
    echo "$empty_tests" | sed 's/^/      /'
    echo "      fix: assert the requirement's claim, or move the citation to the"
    echo "      test that already does"
    fail=1
fi

# 2. Stale ratchet rows: the ID gained a citation — remove the row in the same change.
stale="$(comm -12 <(echo "$ratchet_ids") <(echo "$cited_by_tests"))"
if [ -n "$stale" ]; then
    echo "  ✗ ratchet entr(ies) now cited by a test — remove them from $RATCHET:"
    echo "$stale" | sed 's/^/      /'
    fail=1
fi

# 3. Ratchet rows for requirements the spec no longer states.
gone="$(comm -23 <(echo "$ratchet_ids") <(echo "$spec_ids"))"
if [ -n "$gone" ]; then
    echo "  ✗ ratchet entr(ies) not in specs/ — the requirement retired; drop the row:"
    echo "$gone" | sed 's/^/      /'
    fail=1
fi

# 4. Citations of nothing: a spec-prefixed ID that the spec does not state.
cited_anywhere="$(grep -rhoE "$ID_RE" src/ test/ scripts/ specs/ ./*.md --include='*.zig' \
    --include='*.py' --include='*.sh' --include='*.md' 2>/dev/null \
    | grep -E "^($prefixes)-" | sort -u)"
phantom="$(comm -23 <(echo "$cited_anywhere") <(echo "$spec_ids"))"
if [ -n "$phantom" ]; then
    echo "  ✗ cited requirement(s) that specs/ does not state:"
    echo "$phantom" | sed 's/^/      /'
    echo "      fix: correct the ID, or if the requirement retired, retire the citation"
    fail=1
fi

total="$(echo "$spec_ids" | wc -l)"
uncited="$(echo "$ratchet_ids" | grep -c . || true)"

# The 95% floor: at most CEILING requirements may sit uncited. The ratchet only
# shrinks row-by-row; this is the backstop against new requirements rebuilding the
# debt — a requirement may land ahead of its test only while the total stays above
# 95% cited.
CEILING=0
if [ "$uncited" -gt "$CEILING" ]; then
    echo "  ✗ ratchet holds $uncited uncited requirement(s) — the ceiling is $CEILING (95% of the spec stays cited)"
    fail=1
fi


# ── PERF-002: the boot budget in the code IS the number the spec states ────────
# A requirement that states a number is only as good as the constant enforcing
# it. Nothing tied the two, so raising BOOT_TO_FIRST_PRESENT_BUDGET_MS to 90 s
# would have kept every track green while silently abandoning the requirement —
# the test asserts the kernel's own verdict, and the kernel computes that verdict
# against its own constant.
spec_boot_s="$(grep -h -A 2 '^\*\*PERF-002\.\*\*' specs/*.md | grep -ohE 'within [0-9]+ seconds' | grep -ohE '[0-9]+')"
code_boot_ms="$(grep -ohE 'BOOT_TO_FIRST_PRESENT_BUDGET_MS: u64 = [0-9_]+' src/drivers/gpu/gpu.zig | grep -ohE '[0-9_]+$' | tr -d '_')"
if [ -z "$spec_boot_s" ] || [ -z "$code_boot_ms" ]; then
    echo "  ✗ PERF-002: could not read the boot budget from specs/ or gpu.zig"
    fail=1
elif [ "$code_boot_ms" != "$((spec_boot_s * 1000))" ]; then
    echo "  ✗ PERF-002: spec says ${spec_boot_s}s, gpu.zig enforces ${code_boot_ms}ms"
    echo "      fix: change both, or neither — a budget only the code knows is not a requirement"
    fail=1
fi

# ── RND-007: every extension the pipeline ADVERTISES is a requirement here ──────
# The GL_EXTENSIONS string is the promise the pipeline makes to a client; a token
# added there without a matching requirement is a capability nobody specified.
for tok in $(grep -oE 'GL_EXTENSIONS => "[^"]+"' src/drivers/gl/es/gl.zig | sed 's/.*"\(.*\)"/\1/'); do
    name="${tok#GL_}"
    if ! grep -q "$name" specs/*.md; then
        echo "  ✗ advertised GL extension '$tok' is captured by no requirement (RND-007)" >&2
        fail=1
    fi
done
if [ "${fail:-0}" = 0 ]; then
    echo "  ✓ every advertised GL extension is captured in specs/ (RND-007)"
fi

if [ "$fail" -ne 0 ]; then
    echo "  reqtrace: FAIL"
    exit 1
fi
echo "  ✓ requirement trace closed both ways ($((total - uncited))/$total cited, $uncited on the ratchet, ceiling $CEILING)"
