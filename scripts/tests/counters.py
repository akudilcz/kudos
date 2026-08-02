"""Diagnostics-counter records — the ONE home for reading `dbg: <mod>.<name> = N`
counter lines out of a netdebug capture and for the no-silent-loss verdict
(DIAG-002: every discarding path's drops are counted, and the loss set must
not move during a phase — no failure is silent).

The kernel's counter registry (src/kernel/debug/counter.zig) emits every counter
as a `dbg:` record — on the heartbeat when it moves, and all at once on a KMR1
OP_STATS dump. This module parses those records and names the counters whose
movement means work was silently discarded or a fault was contained: any
increment in that set across a test phase is a FAILURE, never noise. The
in-kernel verify harness asserts the same set (src/console/verifyscript.zig
LOSS_COUNTERS) at the end of a -Dverify-script run.

Two counters that DO move legitimately during suite teardown are deliberately
absent from the loss set and reported as informational instead:
  ui.sess.req_drops  — a closed session's in-flight output is dropped (counted)
  net.netdebug.fifo_drops — the metered trace drain sheds under extreme bursts
"""

import re

# Counters whose increment across a phase is a hard failure: each one counts
# work discarded silently or a containment event (a stranded task, a session
# fault, a shootdown that never acknowledged, a leaked session slot, an input
# event dropped on the floor, a bounded spin that overran its budget).
LOSS_KEYS = (
    "sched.stranded_tasks",
    "smp.session_faults",
    "mem.space_faults",
    "mem.heal_dropped",
    "mem.shootdown_timeouts",
    "ui.sess.leaked",
    "ui.key.drops",
    "usb.key.inject_drops",
    "boot.spin_exceeded",
)

# Additional hard-failure counters on a boot with a live GPU present path:
# kudos holds 60 Hz from the first present (PERF-003), so a dropped frame is a
# regression whether or not a FLIPSTAT window happened to be sampling.
GPU_LOSS_KEYS = ("gpu.frame_drops",)

# Exempt when the machine under test is a VM: these counters time PHYSICAL
# waits (the TLB-shootdown acknowledgement budget is 5 ms of real time), and a
# host scheduler that deschedules a vCPU mid-wait blows the budget without
# losing anything — the remote still acts when it next runs. On silicon there
# is no host, so the same increment is a genuine finding.
EMULATION_EXEMPT_KEYS = ("mem.shootdown_timeouts",)


def loss_keys(emulated):
    """The hard-fail set for one run: the full LOSS_KEYS on silicon, minus the
    emulation-exempt keys when the machine under test is a VM."""
    if emulated:
        return tuple(k for k in LOSS_KEYS if k not in EMULATION_EXEMPT_KEYS)
    return LOSS_KEYS

# One counter record: `dbg: <mod>.<name> = <value>` (the value is always a
# decimal integer for counters; non-numeric dbg records simply don't match).
_COUNTER_RE = re.compile(r"dbg: ([a-z]+\.[a-z_0-9.]+) = (\d+)\s*$", re.M)


def latest(capture):
    """The current value of every counter seen in `capture`: the LAST occurrence
    of each key wins (counters are cumulative and re-emitted on change)."""
    vals = {}
    for m in _COUNTER_RE.finditer(capture):
        vals[m.group(1)] = int(m.group(2))
    return vals


def regressions(before, after, keys):
    """The loss counters that INCREMENTED between two `latest()` snapshots:
    a list of (key, before_value, after_value), empty when the phase was clean.
    A key absent from a snapshot is 0 — the kernel registers a loss counter on
    its first increment, so absence is a genuine zero, not a blind spot."""
    out = []
    for key in keys:
        b = before.get(key, 0)
        a = after.get(key, 0)
        if a > b:
            out.append((key, b, a))
    return out


def _selftest():
    cap = (
        "dbg: net.kmr1.reqs = 41\n"
        "[000123] dbg: sched.stranded_tasks = 0\n"
        "dbg: mem.shootdown_timeouts = 2\n"
        "dbg: wm.focus = 2:term #1\n"  # non-numeric record: must not parse
        "dbg: net.kmr1.reqs = 55\n"    # later value must win
    )
    vals = latest(cap)
    assert vals["net.kmr1.reqs"] == 55, vals
    assert vals["sched.stranded_tasks"] == 0
    assert "wm.focus" not in vals
    # A clean phase: nothing in the loss set moved.
    assert regressions(vals, dict(vals), LOSS_KEYS) == []
    # A dirty phase: an increment in the set is reported; an absent-before key
    # counts from zero; a non-loss counter moving is ignored.
    after = dict(vals)
    after["mem.shootdown_timeouts"] = 3
    after["ui.sess.leaked"] = 1
    after["net.kmr1.reqs"] = 99
    got = regressions(vals, after, LOSS_KEYS)
    assert ("mem.shootdown_timeouts", 2, 3) in got, got
    assert ("ui.sess.leaked", 0, 1) in got, got
    assert all(k != "net.kmr1.reqs" for k, _, _ in got)
    # The GPU set is separate: frame drops fail only when it is included.
    after["gpu.frame_drops"] = 4
    assert regressions(vals, after, GPU_LOSS_KEYS) == [("gpu.frame_drops", 0, 4)]
    # The emulation exemption drops exactly the physical-wait keys, nothing else.
    assert "mem.shootdown_timeouts" in loss_keys(emulated=False)
    assert "mem.shootdown_timeouts" not in loss_keys(emulated=True)
    assert set(loss_keys(True)) | set(EMULATION_EXEMPT_KEYS) == set(LOSS_KEYS)
    print("counters: self-test PASS")


if __name__ == "__main__":
    _selftest()
