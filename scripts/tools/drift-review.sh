#!/usr/bin/env bash
# drift-review — the background design review. Reviews a change set together with its
# upstream and downstream neighbours against process.md's rubric, applies the mechanical
# fixes on a branch, and promotes recurring findings into gates and rails.
#
#   scripts/tools/drift-review.sh queue [SHA]   record a point of interest and try to run
#   scripts/tools/drift-review.sh run           run now if the debounce allows it
#   scripts/tools/drift-review.sh now           run regardless of the debounce
#   scripts/tools/drift-review.sh working-tree  review UNCOMMITTED work instead of a range
#   scripts/tools/drift-review.sh status        queue, locks, last run, ledger size
#
# WHAT TRIGGERS IT, AND WHY NOT A GIT HOOK. `queue` is called from the Stop hook in
# .claude/settings.json — versioned config that ships with the repo and can be reviewed like
# anything else. A .git/hooks/ script cannot be committed, so it would be the one part of this
# automation nobody else could see or review, which is exactly the failure the rest of the
# setup exists to avoid. Add a cron entry calling `run` if you want it firing with no session
# open; the debounce below makes either trigger safe.
#
# THE REVIEW NEVER TOUCHES YOUR CHECKOUT. Every run happens in its own git worktree on a
# branch `drift/<stamp>`; the mechanical fixes, the gate run and any new rail all land
# there. You merge it, or you delete it. That is the whole safety model, and it is why the
# job can run unattended while you have uncommitted work in the tree.
#
# WHY A DEBOUNCE, AND WHY IT MUST ALSO WAKE. Commits arrive in bursts — 31 in one day is a
# normal working day here — so reviewing per commit would mean 31 reviews of overlapping
# work. The floor below collapses a burst into one review of the UNION change set. But a
# pure "check on commit" rule loses the tail of a session: the last commits arrive inside
# the floor, get queued, and nothing ever fires again because nothing else is committed. So
# a blocked run schedules a deferred wake at last-run + FLOOR. Continuous committing yields
# one review per floor; a burst then silence still yields exactly one, at most one floor late.
#
# THE HOOK MUST NEVER BLOCK A COMMIT. `queue` appends and detaches; the work happens in a
# process git is not waiting on.
set -uo pipefail
cd "$(dirname "$0")/../.."

REPO="$(pwd)"
STATE="$REPO/.claude/drift"
QUEUE="$STATE/queue"
LEDGER="$STATE/findings.jsonl"
RUNLOCK="$STATE/run.lock"          # a DIRECTORY: mkdir is the atomic test-and-set
WAKELOCK="$STATE/wake.lock"
LAST_RUN="$STATE/last-run"
LAST_REVIEWED="$STATE/last-reviewed"
RUNS="$STATE/runs"
WORKFLOW="$REPO/.claude/workflows/drift-review.js"

FLOOR_S="${DRIFT_FLOOR_S:-7200}"   # 2 hours between reviews
SHAPE_EVERY="${DRIFT_SHAPE_EVERY:-5}"

mkdir -p "$STATE"

say() { printf 'drift-review: %s\n' "$*" >&2; }

# ── the debounce ────────────────────────────────────────────────────────────────────────
# Returns 0 when a run may start now, 1 when it must wait (and prints the remaining seconds).
floor_remaining() {
    [ -f "$LAST_RUN" ] || { echo 0; return; }
    local last now elapsed
    last=$(stat -c %Y "$LAST_RUN" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed=$(( now - last ))
    if [ "$elapsed" -ge "$FLOOR_S" ]; then echo 0; else echo $(( FLOOR_S - elapsed )); fi
}

# Schedule one deferred wake, at most one outstanding. The wake re-enters `run`, which
# re-checks everything — if the queue emptied meanwhile it exits silently.
schedule_wake() {
    local delay="$1"
    mkdir "$WAKELOCK" 2>/dev/null || { say "wake already pending"; return 0; }
    setsid nohup sh -c "sleep $delay; rmdir '$WAKELOCK' 2>/dev/null; '$0' run" \
        >>"$STATE/wake.log" 2>&1 &
    say "deferred wake in ${delay}s"
}

# ── subcommands ─────────────────────────────────────────────────────────────────────────
cmd_queue() {
    local sha="${1:-$(git rev-parse HEAD 2>/dev/null)}"
    [ -n "$sha" ] && echo "$sha" >>"$QUEUE"
    # Detach immediately: git is waiting on this process, and a review takes minutes.
    setsid nohup "$0" run >>"$STATE/run.log" 2>&1 &
    return 0
}

cmd_run() {
    local force="${1:-}"

    if ! mkdir "$RUNLOCK" 2>/dev/null; then
        say "a run is already in flight"
        return 0
    fi
    trap 'rmdir "$RUNLOCK" 2>/dev/null' EXIT

    if [ "$force" != "--force" ]; then
        local wait_s
        wait_s=$(floor_remaining)
        if [ "$wait_s" -gt 0 ]; then
            say "within the ${FLOOR_S}s floor, ${wait_s}s remaining"
            rmdir "$RUNLOCK" 2>/dev/null; trap - EXIT
            schedule_wake "$wait_s"
            return 0
        fi
    fi

    if [ ! -s "$QUEUE" ] && [ "$force" != "--force" ]; then
        say "nothing queued"
        return 0
    fi

    # THE UNION CHANGE SET, never one commit at a time. Everything since the last review.
    local base head
    head=$(git rev-parse HEAD)
    if [ -f "$LAST_REVIEWED" ] && git rev-parse --verify --quiet "$(cat "$LAST_REVIEWED")^{commit}" >/dev/null; then
        base=$(cat "$LAST_REVIEWED")
    else
        base=$(git rev-parse HEAD~1 2>/dev/null || echo "$head")
    fi
    if [ "$base" = "$head" ]; then
        say "no commits since the last review"
        : >"$QUEUE"
        return 0
    fi

    : >"$QUEUE"
    # A FAILED RUN HAS NOT REVIEWED ANYTHING. Advancing the marker on failure would retire a
    # change set nobody looked at — the silent gap this job exists to prevent. So the marker
    # moves only on success, while last-run is stamped either way so a persistent failure
    # retries at the floor's pace instead of spinning on every trigger.
    if run_workflow commits "$base" "$head"; then
        echo "$head" >"$LAST_REVIEWED"
    else
        say "run failed — $base..$head stays unreviewed and will be retried"
    fi
    touch "$LAST_RUN"
}

cmd_working_tree() {
    if ! mkdir "$RUNLOCK" 2>/dev/null; then say "a run is already in flight"; return 0; fi
    trap 'rmdir "$RUNLOCK" 2>/dev/null' EXIT
    run_workflow working-tree "HEAD" "HEAD"
}

# THE WORKTREE IS THE SANDBOX. In working-tree mode the uncommitted work is carried across
# as a patch, because a worktree checkout only ever sees committed state.
run_workflow() {
    local mode="$1" base="$2" head="$3"
    local stamp branch tree n shape
    stamp=$(date +%Y-%m-%d-%H%M)
    branch="drift/$stamp"
    tree="$REPO/.claude/worktrees/drift-$stamp"

    n=$(( $(cat "$RUNS" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$RUNS"
    shape=false
    [ $(( n % SHAPE_EVERY )) -eq 0 ] && shape=true

    say "run #$n  mode=$mode  range=$base..$head  branch=$branch  shape=$shape"

    local err
    if ! err=$(git worktree add --detach "$tree" "$head" 2>&1); then
        say "could not create the worktree: $err"
        return 1
    fi
    git -C "$tree" switch -c "$branch" >/dev/null 2>&1

    if [ "$mode" = "working-tree" ]; then
        # Tracked edits plus untracked files, so the review sees what you are actually working on.
        git diff HEAD | git -C "$tree" apply --index - 2>/dev/null
        git ls-files --others --exclude-standard | while IFS= read -r f; do
            mkdir -p "$tree/$(dirname "$f")"; cp -p "$f" "$tree/$f"
        done
    fi

    claude -p "Run the drift-review workflow. Invoke the Workflow tool with
scriptPath \"$WORKFLOW\" and args {\"repo\":\"$REPO\",\"tree\":\"$tree\",\"branch\":\"$branch\",\"base\":\"$base\",\"head\":\"$head\",\"mode\":\"$mode\",\"shapePass\":$shape}.
Do not do the review yourself and do not summarise the codebase first — the workflow is the
whole job. When it returns, print its report path and the confirmed/applied counts." \
        >>"$STATE/run.log" 2>&1
    local rc=$?

    if [ $rc -ne 0 ]; then
        say "the review exited $rc — see $STATE/run.log"
    fi

    # An empty branch is noise. Keep it only if the review actually produced something.
    if [ -z "$(git -C "$tree" status --porcelain)" ] && \
       [ "$(git -C "$tree" rev-parse HEAD)" = "$head" ]; then
        say "no changes produced; discarding $branch"
        git worktree remove --force "$tree" >/dev/null 2>&1
        git branch -D "$branch" >/dev/null 2>&1
    else
        say "branch $branch is ready in $tree"
    fi
    return $rc
}

cmd_status() {
    printf 'queue:         %s entry(s)\n' "$( [ -f "$QUEUE" ] && wc -l <"$QUEUE" || echo 0 )"
    printf 'run lock:      %s\n' "$( [ -d "$RUNLOCK" ] && echo held || echo free )"
    printf 'wake pending:  %s\n' "$( [ -d "$WAKELOCK" ] && echo yes || echo no )"
    printf 'runs:          %s\n' "$(cat "$RUNS" 2>/dev/null || echo 0)"
    printf 'last run:      %s\n' "$( [ -f "$LAST_RUN" ] && date -d "@$(stat -c %Y "$LAST_RUN")" || echo never )"
    printf 'floor:         %ss (%ss remaining)\n' "$FLOOR_S" "$(floor_remaining)"
    printf 'last reviewed: %s\n' "$(cat "$LAST_REVIEWED" 2>/dev/null || echo none)"
    printf 'ledger:        %s finding(s)\n' "$( [ -f "$LEDGER" ] && wc -l <"$LEDGER" || echo 0 )"
    git worktree list | grep drift- || true
}

case "${1:-}" in
    queue)        shift; cmd_queue "$@" ;;
    run)          shift; cmd_run "$@" ;;
    now)          cmd_run --force ;;
    working-tree) cmd_working_tree ;;
    status)       cmd_status ;;
    *)            sed -n '2,12p' "$0"; exit 2 ;;
esac
