---
name: gate-discipline
description: How to run the kudos gate without wasting time — batch the whole work package, run once, branch on exit codes, and never re-run a green register track.
---

# Gate discipline

A full gate run costs tens of minutes. The rules below exist because each was paid for once.

## Batch the work, then verify it once

Implement **every** queued task — source, tests, docs, gate rows — and run the gate once at the
end. Five failures in one run is five fixes for the price of one wait. Do not run the suite
after each file, and do not run a separate compile-check: compile errors surface in the same
run. For mutation testing, pick the two or three highest-value mutations per package rather
than one run per assertion.

## The register makes the gate incremental

`build/verified/` holds one record per track: a digest of the paths that track covers, plus the
result. `make check` re-runs only stale tracks.

- `make status` (~1 s) — what this tree has proven and what it still needs.
- `make test T=<track>` — run one track and record it. `FORCE=1` overrides.
- **Never re-run a track `make status` shows green against this tree.** The record IS the
  evidence; re-running it proves nothing new and costs the wait.

Records are written with the digest captured **before** the run, so an edit to a covered path
mid-run leaves the track stale. Do not edit covered paths while a recorded run is in flight.

## Gate on exit codes, never on greps

    make check ... | grep PASS && git commit     # WRONG

That commits on the grep's success even when the gate failed — it put a red tree on master once.
Capture the status of `make check` itself and branch on that:

    make check; RC=$?; [ $RC -eq 0 ] && git commit ...

## Watch long runs in the foreground

Run and watch long tracks with a blocking command that streams, not with a background monitor
plus polling. Background monitors made progress invisible and a stale one once reported a
timeout that looked like a failure. Long runs must show progress at least every 5 s — stream
the output; never swallow one behind a final `| tail`, because silence is indistinguishable
from a hang.

Never `timeout`-kill a local `make check`: the remote boot-1 run on lemon survives the dead ssh
and then wedges when its stdout pipe fills, holding the suite lock. Kill it cleanly on lemon
instead (`pkill -f boot1_emulated`, `pkill -f 'qemu.*kudos.iso'`, remove the suite lock).

## The ladder, and what may be claimed

`make check-fast` (host only) → `make check` (host + QEMU, the iteration gate) → `make check-hw`
(native tracks on real hardware, the final gate). State the highest rung that actually ran and
its result; never claim a rung that did not execute. The laptop has no 4090 and no reference
stick, so `qemu-boot-1`, the native tracks and the model sweep all run on lemon.
