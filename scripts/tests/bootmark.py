"""Boot-milestone checks — the ONE home for judging the kernel's boot
milestones out of a netdebug capture: the boot-to-first-present budget verdict
(spec PERF-002) and that networking bound off the boot critical path
(spec PERF-014).

Shared by the passthrough driver (boot2_passthrough.py) and the native driver
(boot1_native.py) so both tracks judge the milestones by IDENTICAL rules. The
kernel owns the facts: gpu.zig times boot entry -> first GPU present against
its budget and emits one greppable `boot-to-first-present ... PASS/OVER` line;
dhcp.zig logs `dhcp: bound (async)` when the background bind commits its
lease. This module only parses and orders those lines — it holds no policy the
kernel does not already own.
"""

import re

import cadence  # FIRST_PRESENT_ANCHOR — the one home for the anchor string

# gpu.zig emits this exactly once, right after the warm-up that follows the
# first present: `gpu: boot-to-first-present <N> ms (PERF-002 budget <B> ms)
# PASS|OVER`. The kernel computes the verdict against its own budget constant;
# the harness's job is only to refuse OVER — and to refuse SILENCE, because a
# capture without the line means the first present never happened (or the
# image predates the milestone) and the budget went unmeasured.
PERF002_VERDICT_RE = re.compile(
    r"boot-to-first-present (\d+) ms \(PERF-002 budget (\d+) ms\) (PASS|OVER)")

# dhcp.zig logs this when the ASYNC background bind commits its lease — the
# only bind path a normal boot has (the blocking configure() belongs to the
# -Dheartbeat debug image, which deliberately trades PERF-014 away to get
# telemetry up before the desktop).
DHCP_BOUND = "dhcp: bound (async)"

# dhcp.zig logs this when ANY bind path (async or blocking) commits a lease:
# a capture with this line but no DHCP_BOUND means the BLOCKING bind ran.
DHCP_ACK_COMMITTED = "dhcp: ACK committed"

# How long a driver polls for DHCP_BOUND before judging PERF-014: the async
# bind lands seconds after the desktop, but a lost first DISCOVER plus the
# retry gap costs ~13 s, so 60 s covers several retries without masking a
# bind that will never come.
DHCP_BOUND_TIMEOUT_S = 60


def judge_boot_to_first_present(text):
    """Judge PERF-002 from a capture. Returns (ok, detail): ok only when the
    kernel's verdict line is present AND says PASS; a missing line or an OVER
    verdict is a failure with the reason in detail."""
    m = PERF002_VERDICT_RE.search(text)
    if m is None:
        return False, ("no boot-to-first-present verdict in the capture "
                       "(first present never happened, or a pre-milestone image)")
    detail = f"boot-to-first-present {m.group(1)} ms (budget {m.group(2)} ms) {m.group(3)}"
    return m.group(3) == "PASS", detail


def judge_network_off_critical_path(text):
    """Judge PERF-014 from a capture. Returns (ok, detail).

    The invariant a capture can prove is WHICH bind path committed the lease.
    A normal boot binds in the BACKGROUND (dhcp.pump, one-shot record
    DHCP_BOUND) while the desktop presents on its own schedule — the bind may
    commit before OR after the first present depending on how long GSP-RM
    bring-up takes (a real boot-2-native capture shows it landing first), so
    stream order between the two lines is NOT an invariant. The violation is a
    lease committed WITHOUT the async record: only the blocking bind does
    that, and it waits for the lease ahead of the desktop — the path that
    belongs solely to the -Dheartbeat debug image. A capture with no anchor
    (no desktop) or no lease at all also fails — poll until DHCP_BOUND is
    present before judging."""
    if cadence.FIRST_PRESENT_ANCHOR not in text:
        return False, "no first-GPU-present anchor in the capture"
    if DHCP_BOUND in text:
        return True, "lease committed by the async background bind"
    if DHCP_ACK_COMMITTED in text:
        return False, (f"a lease was committed WITHOUT the {DHCP_BOUND!r} record "
                       "— the BLOCKING bind ran, on the boot critical path")
    return False, (f"no {DHCP_BOUND!r} record in the capture — "
                   "the background DHCP bind never committed a lease")
