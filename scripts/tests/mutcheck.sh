#!/usr/bin/env bash
# The mutation gate: evidence that the tests named in mutations.txt can fail
# (process.md §Verification).
#
#   scripts/tests/mutcheck.sh                 run every STALE row, skip verified ones
#   scripts/tests/mutcheck.sh --only SUBSTR   run rows whose target/suite matches
#   scripts/tests/mutcheck.sh --status        one register line, runs nothing
#   FORCE=1 scripts/tests/mutcheck.sh         ignore the register, run every row
#
# A test that cannot go RED is a comment. Every row of mutations.txt reintroduces one
# real, once-shipped bug class into a scratch-modified source file and demands that the
# named host suite FAILS; the tree is restored whichever way the run goes. A mutation
# that does not change the file, or a suite that stays green over a reintroduced bug,
# fails this gate — the second case means the test is decorative.
#
# EACH ROW IS ITS OWN REGISTER TRACK (build/verified/mut/<slug>): a row re-runs only
# when its target file, the test files its suite substring matches, this script, or
# the row itself change. A verified row costs a digest, not a build — which is what
# keeps sixteen rows from being sixteen compiles on every gate run.
#
# Row format (pipe-separated, # comments):
#   <src file> | <sed -E expression> | <-Dtest-only substring> | <bug class reintroduced>
# Every new regression test lands with its row; a module's rows grow on touch.
set -uo pipefail
cd "$(dirname "$0")/../.."

MANIFEST=scripts/tests/mutations.txt
STAMP_DIR=build/verified/mut

MODE=run
ONLY_FILTER=""
case "${1:-}" in
    --status) MODE=status ;;
    --only)   ONLY_FILTER="${2:?--only needs a substring}" ;;
    "")       ;;
    *)        echo "usage: $0 [--status | --only SUBSTR]" >&2; exit 2 ;;
esac

# Rows may share a target AND a suite (a module's rows grow on touch), so the slug
# hashes the whole row identity — target, suite, and the sed expression — or sibling
# rows would overwrite each other's stamp. Editing a row therefore re-runs it (the
# old slug is pruned as an orphan).
slug_of() { # target expr only
    echo "$(basename "$1" .zig)-$(printf '%s' "$1|$2|$3" | sha256sum | cut -c1-8)"
}

row_digest() { # target expr only
    {
        { git ls-files -co --exclude-standard -- "$1" scripts/tests/mutcheck.sh
          git ls-files -co --exclude-standard -- test | grep -F -- "$3" || true
        } | sort -u | tr '\n' '\0' | xargs -0 sha256sum 2>/dev/null
        printf '%s\n' "$2|$3"
    } | sha256sum | cut -c1-16
}

fresh_row() { # slug digest
    [ "${FORCE:-0}" = "1" ] && return 1
    [ -f "$STAMP_DIR/$1" ] || return 1
    [ "$(head -n1 "$STAMP_DIR/$1")" = "$2" ] || return 1
    grep -q '^result=pass$' "$STAMP_DIR/$1"
}

record_row() { # slug digest result duration_s
    mkdir -p "$STAMP_DIR"
    { echo "$2"; echo "result=$3"; echo "when=$(date +%s)"; echo "duration_s=$4"; } \
        > "$STAMP_DIR/$1"
}

fail=0 ran=0 cached=0 total=0
SEEN_SLUGS=""

restore() { [ -n "${backup:-}" ] && cp "$backup" "$target"; backup=""; }
trap restore EXIT

while IFS='|' read -r target expr only why; do
    target="$(echo "$target" | xargs)"; expr="$(echo "$expr" | sed 's/^ *//;s/ *$//')"
    only="$(echo "$only" | xargs)"; why="$(echo "$why" | sed 's/^ *//;s/ *$//')"
    [ -z "$target" ] || [[ "$target" == \#* ]] && continue
    total=$((total + 1))
    slug="$(slug_of "$target" "$expr" "$only")"
    SEEN_SLUGS="$SEEN_SLUGS $slug"
    if [ -n "$ONLY_FILTER" ] && [[ "$target$only" != *"$ONLY_FILTER"* ]]; then continue; fi
    dig="$(row_digest "$target" "$expr" "$only")"
    if fresh_row "$slug" "$dig"; then
        cached=$((cached + 1))
        continue
    fi
    [ "$MODE" = "status" ] && { ran=$((ran + 1)); continue; }
    ran=$((ran + 1))
    if [ ! -f "$target" ]; then
        echo "  ✗ $target: named by a mutation row but does not exist"; fail=1; continue
    fi
    start=$(date +%s)
    backup="$(mktemp)"
    cp "$target" "$backup"
    sed -E -i "$expr" "$target"
    if cmp -s "$backup" "$target"; then
        echo "  ✗ $target: mutation did not apply ($why) — the sed no longer matches"
        restore; record_row "$slug" "$dig" fail 0; fail=1; continue
    fi
    if zig build test -Dtest-only="$only" -p build --cache-dir build/.zig-cache \
        > /dev/null 2>&1; then
        echo "  ✗ $target: suite '$only' stayed GREEN over: $why — the test cannot fail"
        record_row "$slug" "$dig" fail "$(( $(date +%s) - start ))"
        fail=1
    else
        echo "  ✓ $target: '$only' went RED over: $why"
        record_row "$slug" "$dig" pass "$(( $(date +%s) - start ))"
    fi
    restore
done < "$MANIFEST"

if [ "$MODE" = "status" ]; then
    echo "  mutation rows: $total total — $cached verified against this tree, $ran need a run"
    exit 0
fi

# A deleted or renamed row must not leave evidence behind: prune stamps no current
# row owns (full runs only — a --only run has not seen every row).
if [ -z "$ONLY_FILTER" ] && [ -d "$STAMP_DIR" ]; then
    for f in "$STAMP_DIR"/*; do
        [ -e "$f" ] || continue
        case " $SEEN_SLUGS " in
            *" $(basename "$f") "*) ;;
            *) rm -f "$f" ;;
        esac
    done
fi

if [ "$fail" -ne 0 ]; then
    echo "  mutcheck: FAIL"
    exit 1
fi
if [ "$total" -eq 0 ]; then
    echo "  ✓ mutation gate: manifest empty — rows join with each regression test"
elif [ "$ran" -eq 0 ]; then
    echo "  ✓ mutation gate: all $cached row(s) verified against this tree — nothing to run"
else
    echo "  ✓ mutation gate: $ran row(s) run RED as required, $cached cached"
fi
