"""Scheduler-clock verdicts — the ONE home for judging the kernel's two clocks
from the outside: the deadline-sleep clock (KRN-008, the `rt` command's own
jitter/drift report) and the system tick (KRN-012, the `ticks=` counter the
KMR1 PING status and the netdebug heartbeat both carry).

Parsing targets are kernel-owned lines; this module holds no policy the kernel
does not already state:
  rt:  `rt: jitter min/mean/max = A/B/C ns; drift = D us over N periods`
       (src/console/cmd/rt.zig)
  ping status: `build=N up_ms=N ticks=N ...`  (src/drivers/net/debug/fileserv.zig)
  heartbeat:   `hb N: ticks=N tick_ms=N ...`  (src/drivers/net/debug/netdebug.zig)

The rt bounds mirror the in-kernel verify harness's rtStage thresholds
(src/console/verifyscript.zig): generous for emulation-added interrupt latency,
and the point is that jitter is BOUNDED and drift does NOT accumulate with
periods — not that either is exactly zero.
"""

import re

# Worst-case per-period wake jitter the deadline sleep may show.
RT_JITTER_MAX_NS = 5_000_000
# Cumulative drift over the whole run — absolute-deadline scheduling keeps this
# near ONE period's jitter regardless of period count.
RT_DRIFT_MAX_US = 10_000

# KRN-012: how far the tick rate may read from wall time across a measurement
# window before the tick is judged wrong. Wide on purpose — the measurement
# rides two lossy UDP round-trips and the counter's 1-tick granularity; a dead
# or halved tick still lands far outside it.
TICK_RATE_RATIO_MIN = 0.5
TICK_RATE_RATIO_MAX = 1.5

_RT_RE = re.compile(
    r"rt: jitter min/mean/max = (\d+)/(\d+)/(\d+) ns; drift = (\d+) us over (\d+) periods")
_STATUS_FIELD_RE = re.compile(r"\b([a-z_]+)=(\d+)")
_HB_RE = re.compile(r"\bhb \d+: ticks=(\d+) tick_ms=(\d+)")


def parse_rt(text):
    """The LAST rt result in `text` as a dict (min/mean/max_ns, drift_us,
    periods), or None if no complete result line is present."""
    last = None
    for m in _RT_RE.finditer(text):
        last = {
            "min_ns": int(m.group(1)),
            "mean_ns": int(m.group(2)),
            "max_ns": int(m.group(3)),
            "drift_us": int(m.group(4)),
            "periods": int(m.group(5)),
        }
    return last


def judge_rt(res, want_periods):
    """Judge one parsed rt result. Returns (ok, detail). Fails when the run was
    cut short (cancel/close broke it), jitter exceeded the bound, or drift
    accumulated past the bound."""
    if res is None:
        return False, "no rt result line"
    detail = (f"{res['periods']} periods, jitter max {res['max_ns']} ns, "
              f"drift {res['drift_us']} us")
    if res["periods"] < want_periods:
        return False, f"run cut short ({detail}, wanted {want_periods} periods)"
    if res["max_ns"] > RT_JITTER_MAX_NS:
        return False, f"jitter over {RT_JITTER_MAX_NS} ns ({detail})"
    if res["drift_us"] > RT_DRIFT_MAX_US:
        return False, f"drift over {RT_DRIFT_MAX_US} us ({detail})"
    return True, detail


def parse_status(status_line):
    """Every `name=<int>` field of a KMR1 PING status line, as a dict."""
    return {m.group(1): int(m.group(2)) for m in _STATUS_FIELD_RE.finditer(status_line)}


def tick_period_ms(capture):
    """The tick period in ms, derived from the LAST netdebug heartbeat in
    `capture`: `ticks` is the IRQ0 count and `tick_ms` the same uptime in
    milliseconds, so their ratio is the period. None before the first
    heartbeat has arrived."""
    last = None
    for m in _HB_RE.finditer(capture):
        ticks, uptime_ms = int(m.group(1)), int(m.group(2))
        if ticks > 0:
            last = uptime_ms / ticks
    return last


def judge_tick_advance(ticks_before, ticks_after, wall_s, period_ms):
    """KRN-012: judge that the tick kept its rate across a wall-clock window.
    Returns (ok, detail). Fails on a frozen tick or a rate outside the ratio
    band — the failure that costs power cycles is a CPU that still answers
    while IRQ0 is dead."""
    dt = ticks_after - ticks_before
    if dt <= 0:
        return False, f"tick frozen ({ticks_before} -> {ticks_after} over {wall_s:.1f}s)"
    if period_ms is None or period_ms <= 0:
        return False, "no heartbeat tick_ms to judge the rate against"
    ratio = (dt * period_ms / 1000.0) / wall_s
    detail = f"{dt} ticks x {period_ms} ms over {wall_s:.1f}s wall (ratio {ratio:.2f})"
    if ratio < TICK_RATE_RATIO_MIN or ratio > TICK_RATE_RATIO_MAX:
        return False, f"tick rate off ({detail})"
    return True, detail


def _selftest():
    mirror = ("$ kudos rt 20\nrt: 10 Hz, 20 periods ...\n"
              "rt: jitter min/mean/max = 1200/45000/900000 ns; drift = 350 us over 20 periods\n")
    res = parse_rt(mirror)
    assert res == {"min_ns": 1200, "mean_ns": 45000, "max_ns": 900000,
                   "drift_us": 350, "periods": 20}, res
    assert judge_rt(res, 20)[0]
    assert not judge_rt(res, 30)[0]                      # cut short
    assert not judge_rt(dict(res, max_ns=9_000_000), 20)[0]   # jitter blown
    assert not judge_rt(dict(res, drift_us=50_000), 20)[0]    # drift accumulated
    assert not judge_rt(None, 20)[0]

    st = parse_status("build=4375 up_ms=61234 ticks=61234 usbdev=5 kbd=1 mouse=1")
    assert st["ticks"] == 61234 and st["build"] == 4375

    cap = ("hb 3: ticks=3226 tick_ms=32260 tsc_s=32\n"
           "hb 4: ticks=3426 tick_ms=34260 tsc_s=34\n")
    assert tick_period_ms(cap) == 10.0
    assert tick_period_ms("no heartbeat yet") is None
    assert judge_tick_advance(1000, 1400, 4.0, 10.0)[0]
    assert not judge_tick_advance(1000, 1000, 4.0, 10.0)[0]     # frozen
    assert not judge_tick_advance(1000, 1100, 4.0, 10.0)[0]     # rate collapsed
    assert not judge_tick_advance(1000, 1400, 4.0, None)[0]     # no heartbeat
    print("schedclock: self-test PASS")


if __name__ == "__main__":
    _selftest()
