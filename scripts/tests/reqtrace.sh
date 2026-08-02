#!/usr/bin/env bash
# The requirement-trace gate: spec.md's IDs and the test tree, kept honest both ways
# (process.md §Traceability). Runs in `make check` and costs nothing — no build.
#
# Direction 1 — every requirement is CITED: each ID in spec.md appears in a test
# (test/ or scripts/tests/), or sits on the uncited ratchet (reqtrace_uncited.txt),
# the shrinking record of requirements still awaiting their citation. The ratchet only
# tightens: an ID that gains a citation must leave the file in the same change, so
# progress can never silently regress.
#
# Direction 2 — every citation is real: an ID cited anywhere (source, tests, scripts,
# root docs) whose prefix belongs to spec.md must itself exist in spec.md. A retired or
# misspelled identifier is a citation of nothing.
#
# A citation records where the evidence is claimed to live. It does not itself
# establish that the cited test verifies the requirement — that is the reviewer's job.
set -uo pipefail
cd "$(dirname "$0")/../.."

ID_RE='\b[A-Z]{2,4}-[0-9]{3}\b'
RATCHET=scripts/tests/reqtrace_uncited.txt

spec_ids="$(grep -ohE "$ID_RE" spec.md | sort -u)"
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

# 2. Stale ratchet rows: the ID gained a citation — remove the row in the same change.
stale="$(comm -12 <(echo "$ratchet_ids") <(echo "$cited_by_tests"))"
if [ -n "$stale" ]; then
    echo "  ✗ ratchet entr(ies) now cited by a test — remove them from $RATCHET:"
    echo "$stale" | sed 's/^/      /'
    fail=1
fi

# 3. Ratchet rows for requirements spec.md no longer states.
gone="$(comm -23 <(echo "$ratchet_ids") <(echo "$spec_ids"))"
if [ -n "$gone" ]; then
    echo "  ✗ ratchet entr(ies) not in spec.md — the requirement retired; drop the row:"
    echo "$gone" | sed 's/^/      /'
    fail=1
fi

# 4. Citations of nothing: a spec-prefixed ID that spec.md does not state.
cited_anywhere="$(grep -rhoE "$ID_RE" src/ test/ scripts/ ./*.md --include='*.zig' \
    --include='*.py' --include='*.sh' --include='*.md' 2>/dev/null \
    | grep -E "^($prefixes)-" | sort -u)"
phantom="$(comm -23 <(echo "$cited_anywhere") <(echo "$spec_ids"))"
if [ -n "$phantom" ]; then
    echo "  ✗ cited requirement(s) that spec.md does not state:"
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


# ── RND-007: every extension the pipeline ADVERTISES is a requirement here ──────
# The GL_EXTENSIONS string is the promise the pipeline makes to a client; a token
# added there without a matching requirement is a capability nobody specified.
for tok in $(grep -oE 'GL_EXTENSIONS => "[^"]+"' src/drivers/gl/es/gl.zig | sed 's/.*"\(.*\)"/\1/'); do
    name="${tok#GL_}"
    if ! grep -q "$name" spec.md; then
        echo "  ✗ advertised GL extension '$tok' is captured by no requirement (RND-007)" >&2
        fail=1
    fi
done
if [ "${fail:-0}" = 0 ]; then
    echo "  ✓ every advertised GL extension is captured in spec.md (RND-007)"
fi

if [ "$fail" -ne 0 ]; then
    echo "  reqtrace: FAIL"
    exit 1
fi
echo "  ✓ requirement trace closed both ways ($((total - uncited))/$total cited, $uncited on the ratchet, ceiling $CEILING)"
