#!/usr/bin/env python3
"""boot-3: the SMP/multi-core scheduling stress suite (kudos-smp under real load).

boot-1/boot-2 prove the shell, the devices, and the GPU on the SINGLE-core
kernel; boot-3 boots kudos-smp and stresses the scheduler itself — placement
(KRN-009/010/011), deadline sleep under load (KRN-008), the rotating tick
(KRN-012), per-session address-space churn (MEM), guest vCPUs as schedulable
tasks, and the 60 Hz cadence guarantee while all of it runs (PERF-003/017).

One driver, two tracks — both inject over KMR1 (:9515) and read back the
netdebug capture (:9514), so the transports are identical and only the machine
differs (BOOT3_TRACK):
  native  lemon's bare metal: kudos-smp + GSP, the 4090 composites, the GPU
          instruments (FLIPSTAT, SHOT) are asserted. run_native.sh --smp.
  qemu    QEMU -smp 8, no GPU: the suite's own logic is testable without the
          rig; GPU asserts are replaced by the honest no-GPU flipstat error.
          run_boot3_qemu.sh (which also runs the -Dverify-script in-kernel
          stages before handing the boot to this driver).

PHASE INSTRUMENTS runs first and exists because of a hard lesson from the first
kudos-smp boot on hardware: FLIPSTAT, SHOT and eventually ALL KMR1
request/response ops died while the one-way netdebug stream stayed healthy — a
diagnostic path that quietly dies takes every later "verdict" down with it.
So every probe this suite leans on is itself asserted, and a dead one fails the
run immediately with `INSTRUMENT DEAD: <which>`. This phase is the regression
gate for those service paths.

Randomised choices (task counts, prime targets, cycle counts) derive from ONE
seed printed at start and settable via BOOT3_SEED — any failure is replayable.
BOOT3_SOAK_MIN=<minutes> loops the load phases, re-arming the cadence sampler
each cycle. Shares the boot-1 driver machinery (boot1_emulated), the case
table's parsing helpers (cases), and the verdict homes (cadence, schedclock,
counters) — one definition of every rule, no forks.
"""

import os
import random
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import boot1_emulated as b1  # noqa: E402  — shared driver machinery (wm, type_cmd, records)
import boot1_native as bn  # noqa: E402  — shared native readiness probes
import cases  # noqa: E402
import cadence  # noqa: E402  — the shared FLIPSTAT verdict home
import counters  # noqa: E402  — the shared no-silent-loss counter home
import schedclock  # noqa: E402  — the shared KRN-008/KRN-012 verdict home
import kmr1_input  # noqa: E402

sys.path.insert(0, os.path.join(HERE, "..", "tools", "netdebug-mcp"))
import kmir  # noqa: E402

TRACK = os.environ.get("BOOT3_TRACK", "native")  # "native" (lemon+GPU) | "qemu" (smoke)
GPU = TRACK == "native"
# qemu track: run_boot3_qemu.sh always passes KUDOS_IP=127.0.0.1 — KMR1 rides a
# slirp hostfwd there, so there is no guest address to discover.
KUDOS_IP = os.environ.get("KUDOS_IP") or (
    (os.environ.get("LEMON_IP") or bn.lemon_ip()) if GPU else None)
if KUDOS_IP is None:
    sys.exit("boot3: the qemu track needs KUDOS_IP (run via run_boot3_qemu.sh)")
NETDEBUG_LOG = os.environ.get("NETDEBUG_LOG", "/tmp/netdebug.log")
SOAK_MIN = float(os.environ.get("BOOT3_SOAK_MIN", "0"))
SEED = int(os.environ.get("BOOT3_SEED", "0")) or (int(time.time()) & 0xFFFFFF)
rng = random.Random(SEED)

SHOT_DIR = os.path.join(b1.ROOT, "build", "logs", "shots")

# ── budgets and load shapes (every wait states its budget) ──────────────────
READY_TIMEOUT_S = 300           # full netboot fetch + 32-core bring-up on lemon
VERIFY_TIMEOUT_S = 300          # the in-kernel -Dverify-script stages (qemu track)
HEARTBEAT_FRESH_TIMEOUT_S = 8   # netdebug heartbeats ride a 2 s cadence
STATS_DUMP_TIMEOUT_S = 10       # OP_STATS ack -> counter records on the trace
FLIPSTAT_VERDICT_TIMEOUT_S = 30  # re-arm -> verdict is ~13 s (cmd/flipstat.zig)
BOOT_VERDICT_TIMEOUT_S = 60     # first-present auto-window -> its one verdict
PEG_WINDOWS_MAX = 12            # cascade keeps this many close boxes reachable
OVERSUB_MIN, OVERSUB_MAX = 2, 4  # CPU-bound tasks beyond the core count (qemu)
PEG_PRIME_MIN, PEG_PRIME_MAX = 1_000_000_000, 2_000_000_000  # never finishes; cancelled by close
LOAD_WINDOW_S = 5               # per-core CPU% measurement window
CORE_BUSY_MIN_PCT = 85          # "no core idles while tasks wait", as a floor
RT_LOAD_PERIODS = 20            # 2 s of 10 Hz deadline sleep under full load
RT_STORM_PERIODS = 300          # 30 s — long enough that every storm rt overlaps
WAKESTORM_TERMS_MIN, WAKESTORM_TERMS_MAX = 3, 5
CHURN_CYCLES_MIN, CHURN_CYCLES_MAX = 6, 10
CHURN_BG_PRIMES = 2             # cores kept busy so teardown TLB shootdowns cross cores
MEM_TOLERANCE_MB = 16           # transient noise; a leaked session (24 MiB) still trips
GUEST_BOOT_TIMEOUT_S = 120      # vm boot -> KUDOS-GUEST-UP (nested VMX is slower)
GUEST_DUP_SETTLE_S = 4          # window in which a phantom duplicate guest would boot
GUEST_EXITS_WINDOW_S = 2        # exits must climb across this
GUEST_STOP_TIMEOUT_S = 15       # vm stop -> guest leaves `running`


def read():
    return b1.read_serial()


def _record(line):
    b1._record(line)


# Live progress meter: every OK carries its running count and the current
# phase index, so a watcher sees how far through the run we are without
# waiting for the summary line (CLAUDE.md: long runs stream progress).
PHASES_TOTAL = 6  # INSTRUMENTS, LOAD, GUEST, CHURN, FAULT, WAKE STORM
_phase_now = [0]


def phase(title):
    _phase_now[0] += 1
    _record(f"boot3: PHASE {_phase_now[0]}/{PHASES_TOTAL} — {title}")


def ok(what):
    b1.passed += 1
    _record(f"boot3:   OK [{b1.passed:2d}, phase {_phase_now[0]}/{PHASES_TOTAL}]  {what}")


def fail(msg, grep=None):
    _record(f"boot3: FAIL — {msg}")
    if grep:
        hits = [ln for ln in read().splitlines() if grep in ln]
        for ln in hits[-10:]:
            _record("   " + ln)
    _record(f"boot3: {b1.passed} assertions passed before the failure")
    sys.exit(1)


def rpc(what, fn, *args, **kwargs):
    """One KMR1 request/response op, or a named INSTRUMENT DEAD failure. The
    request path itself is under test: on the first kudos-smp hardware boot,
    every KMR1 op eventually stopped answering while netdebug kept streaming."""
    try:
        return fn(*args, **kwargs)
    except kmir.KmirError as e:
        fail(f"INSTRUMENT DEAD: {what} ({e})")


# ── driving helpers (KMR1 keys via the shared type_cmd; clicks via OP_MOUSE_ABS) ──

def scoped_on(chan, cmd):
    """This command's own mirrored output on terminal channel `chan`: everything
    after the LAST `> <cmd>` echo (the multi-channel form of b1's core-0 helper)."""
    mirror = cases.mirror_text(read(), core=chan)
    idx = mirror.rfind(f"> {cmd}")
    if idx == -1:
        return None
    nl = mirror.find("\n", idx)
    return mirror[nl + 1:] if nl != -1 else ""


def obs_cmd(q, cmd, expects=(), deadline_s=30, label=None):
    """Type `cmd` at the FOCUSED terminal and poll that terminal's own mirror
    until every expected substring appears in the command's scoped output.
    Returns (scoped_output, channel).

    One LOUD retry on timeout: the evidence channel is UDP and can drop a
    datagram (the trace's seq numbering makes that visible as a gap), so a
    missing line gets one fresh issue of the command before it convicts the
    kernel. The retry is recorded — a green run that needed it is still a
    flag to read the trace for the gap."""
    for attempt in (1, 2):
        chan = b1.type_cmd(q, cmd)
        deadline = time.time() + deadline_s
        scoped = None
        while time.time() < deadline:
            scoped = scoped_on(chan, cmd)
            if scoped is not None and all(e in scoped for e in expects):
                return scoped, chan
            time.sleep(0.3)
        if attempt == 1:
            _record(f"boot3:   RETRY {label or repr(cmd)}: mirror incomplete "
                    f"after {deadline_s}s — reissuing once (UDP evidence "
                    f"channel; check the trace for a seq gap)")
    missing = [e for e in expects if scoped is None or e not in scoped]
    fail(f"{label or repr(cmd)}: missing {missing} in output on term.{chan} "
         f"within {deadline_s}s (after one retry)", grep=f"term.{chan}")


def open_terminal(q):
    """F12 opens a fresh terminal that takes focus (the hotkey works even while
    every shell is busy). Returns (window_id, mirror_channel)."""
    n0 = b1.wm()["nwins"]
    if n0 is None:
        fail("no wm.nwins record — is the WM state mirror compiled in (-Dtest-hooks)?")
    q.key("f12")
    st = b1.wm_wait(lambda s: s["nwins"] == n0 + 1, deadline_s=10)
    if st["nwins"] != n0 + 1 or st["focus"] is None:
        fail(f"F12 did not open a terminal (nwins {n0} -> {st['nwins']})")
    wid, title = st["focus"]
    m = re.match(r"term #(\d+)", title)
    if not m:
        fail(f"F12 focus is not a terminal (focus={st['focus']})")
    return wid, int(m.group(1))


def click_abs(q, x, y):
    """One left click AT (x, y) over KMR1's absolute-pointer op (bypasses the
    acceleration curve, so wm coordinates are click coordinates). Uses the raw
    client: the suite never mixes in relative motion, so the Kmr1Input position
    belief has nothing to go stale against."""
    q.c.inject_mouse_abs(x, y, 0)
    time.sleep(0.15)
    q.c.inject_mouse_abs(x, y, 1)
    time.sleep(0.15)
    q.c.inject_mouse_abs(x, y, 0)
    time.sleep(0.15)


def close_window(q, wid, what):
    """Close window `wid` via its close box — the path that also CANCELS a
    running command (a pegged shell cannot be `exit`ed; the keystroke would
    queue behind the very load it is meant to remove)."""
    g = b1.wm()["wins"].get(wid)
    if g is None:
        fail(f"{what}: window {wid} already missing before close")
    click_abs(q, *cases.close_box_center(g))
    st = b1.wm_wait(lambda s: wid in s["closed"], deadline_s=10)
    if wid not in st["closed"]:
        fail(f"{what}: close box did not close window {wid}")


def refocus_window(q, wid):
    """Click window `wid`'s title bar until it holds focus. Reachable for ANY
    live window: the cascade offsets successive windows by exactly the
    title-bar height, so an earlier window's whole title bar stays visible
    under later siblings."""
    for _ in range(3):
        g = b1.wm()["wins"].get(wid)
        if g is None:
            fail(f"cannot refocus window {wid}: it is gone")
        click_abs(q, *cases.title_center(g))
        st = b1.wm_wait(lambda s: s["focus"] is not None and s["focus"][0] == wid,
                        deadline_s=4)
        if st["focus"] is not None and st["focus"][0] == wid:
            return
    fail(f"could not refocus window {wid} (focus={b1.wm()['focus']})")


def exit_focused(q, wid):
    """`exit` terminal window `wid` (refocusing it first if a close elsewhere
    moved focus) and wait for its window to close."""
    st = b1.wm()
    if st["focus"] is None or st["focus"][0] != wid:
        refocus_window(q, wid)
    b1.type_cmd(q, "exit")
    st = b1.wm_wait(lambda s: wid in s["closed"], deadline_s=10)
    if wid not in st["closed"]:
        fail(f"`exit` did not close window {wid}")


# ── the no-silent-loss watch ────────────────────────────────────────────────

def counters_dump(client):
    """Force a full counter dump onto the trace and return the parsed values.
    `net.kmr1.reqs` is registered at fileserv init and counts this very
    request, so its record arriving is proof the dump landed."""
    offset = b1.serial_size()
    rpc("KMR1 OP_STATS", client.dump_stats)
    deadline = time.time() + STATS_DUMP_TIMEOUT_S
    while time.time() < deadline:
        if "net.kmr1.reqs = " in read()[offset:]:
            return counters.latest(read())
        time.sleep(0.5)
    fail(f"INSTRUMENT DEAD: OP_STATS acked but no counter records reached the "
         f"trace within {STATS_DUMP_TIMEOUT_S}s")


def sweep(client, label, base):
    """Dump the counters and fail on ANY increment in the loss set since `base`
    — no silent loss, phase by phase. Returns the new baseline."""
    vals = counters_dump(client)
    keys = counters.loss_keys(emulated=not GPU) + (counters.GPU_LOSS_KEYS if GPU else ())
    regs = counters.regressions(base, vals, keys)
    if regs:
        fail(f"silent loss during {label}: "
             + ", ".join(f"{k} {b}->{a}" for k, b, a in regs))
    ok(f"loss counters unchanged through {label}")
    return vals


# ── output parsers over kernel-owned formats ────────────────────────────────

# `ps` ends with its legend line; a scoped read gated on it holds the WHOLE
# listing — under load the rows trail the header through the metered mirror,
# and parsing early reads a truncated core table (observed: 4 of 8 rows).
PS_COMPLETE = "(* = running;"
_PS_ROW_RE = re.compile(r"^#(\d+)\s+\S+\s+(\d+)%\s+(.*)$", re.M)
_MEM_RE = re.compile(r"free (\d+) MiB / (\d+) MiB total")
_VM_ROW_RE = re.compile(r"^\s*vm (\d+)\s+core (\S+)\s+(\w+)(?: \(stopping\))?\s+exits (\d+)", re.M)
_GUEST_UP_RE = re.compile(r"vm\d+: .*KUDOS-GUEST-UP")


def parse_ps(scoped):
    """{core: (cpu_pct, task_list_text)} from one `ps` listing."""
    return {int(m.group(1)): (int(m.group(2)), m.group(3))
            for m in _PS_ROW_RE.finditer(scoped)}


def mem_free_mib(q):
    scoped, _ = obs_cmd(q, "mem", ("MiB total",))
    m = _MEM_RE.search(scoped)
    if not m:
        fail(f"`mem` output unparseable: {scoped!r}")
    return int(m.group(1))


_HELD_RE = re.compile(r"sessions (\d+) holding (\d+) MiB")


def sessions_held(q):
    """(session count, MiB held) from `mem` — the per-address-space accounting
    (MEM-008). Free RAM alone cannot tell a leaked session from ordinary churn;
    this is the figure that can."""
    scoped, _ = obs_cmd(q, "mem", ("MiB total", "sessions "))
    m = _HELD_RE.search(scoped)
    if not m:
        fail(f"`mem` reports no per-session accounting (MEM-008): {scoped!r}")
    return int(m.group(1)), int(m.group(2))


def vm_rows(scoped):
    """[(id, core, state, exits)] from one `vm` status listing."""
    return [(int(m.group(1)), m.group(2), m.group(3), int(m.group(4)))
            for m in _VM_ROW_RE.finditer(scoped)]


def guest_up_count():
    return len(_GUEST_UP_RE.findall(read()))


def flipstat_pass(q, label):
    """Re-arm the present-cadence sample from the focused terminal and demand a
    fresh full-window PASS — the PERF-003/PERF-017 measurement, judged by the
    shared cadence rules. GPU track only (there is no present ring otherwise)."""
    before = cadence.verdict_count(read())
    obs_cmd(q, "flipstat", ("sampling re-armed",), label=f"{label}: flipstat re-arm")
    deadline = time.time() + FLIPSTAT_VERDICT_TIMEOUT_S
    while time.time() < deadline and cadence.verdict_count(read()) <= before:
        time.sleep(1)
    if cadence.verdict_count(read()) <= before:
        fail(f"INSTRUMENT DEAD: FLIPSTAT — re-arm acked but no verdict within "
             f"{FLIPSTAT_VERDICT_TIMEOUT_S}s ({label})", grep="FLIPSTAT")
    good, detail = cadence.judge_window(cadence.latest_verdict(read()))
    if not good:
        fail(f"{label}: cadence window failed: {detail}", grep="FLIPSTAT")
    # The under-load call sites make this the PERF-007 verdict: no device or IO
    # work degrades the 60 Hz cadence.
    ok(f"{label}: 60 Hz held ({detail})")


# ── phase INSTRUMENTS ───────────────────────────────────────────────────────

def phase_instruments(q, client):
    """Fail fast, with a named reason, if any probe the suite depends on is
    dead. On the GPU track this is currently the expected first failure — the
    first kudos-smp hardware boot showed FLIPSTAT/SHOT/KMR1 service dying —
    and this phase is the regression gate for fixing them."""
    phase("INSTRUMENTS — the suite's own probes must answer")

    status = rpc("KMR1 PING", client.ping)
    st = schedclock.parse_status(status)
    if "ticks" not in st or "build" not in st:
        fail(f"INSTRUMENT DEAD: KMR1 PING replied but unparseably ({status!r})")
    # NET-002: KMR1 is stateless UDP request/response through kudos's own
    # stack — this round-trip fails if UDP rx-demux or tx breaks.
    ok("KMR1 request/response round-trip (PING)")

    # DIAG-006: the version query answers with the full identity triple, and
    # its build must be the build PING reported — one kernel, one story.
    ver = rpc("KMR1 VERSION", client.version)
    vm = re.search(r"build=(\d+) git=(\S+) built=(\S+)", ver)
    if vm is None or int(vm.group(1)) != st["build"]:
        fail(f"INSTRUMENT DEAD: KMR1 VERSION unparseable or wrong build ({ver!r})")
    ok(f"KMR1 VERSION identity triple (git {vm.group(2)[:10]})")

    # DIAG-011: the in-memory trace history replays on command. Asking for it
    # must put REAL trace back on the wire — the reply being acked proves the
    # command was received, not that anything was retained, so this measures
    # the capture growing by more than the request could have produced.
    before = b1.serial_size()
    rpc("KMR1 RINGTAIL", client.dump_ringtail, 8)
    deadline = time.time() + STATS_DUMP_TIMEOUT_S
    while time.time() < deadline and b1.serial_size() - before < 2048:
        time.sleep(0.5)
    replayed = b1.serial_size() - before
    if replayed < 2048:
        fail(f"INSTRUMENT DEAD: RINGTAIL acked but replayed only {replayed} "
             f"bytes of trace history (DIAG-011)")
    ok(f"trace history replayed on command ({replayed} bytes, DIAG-011)")

    # BOOT-002: the running kernel must be the image most recently staged —
    # a stale image would silently invalidate every verdict this track emits.
    m = re.search(r"kudos build #(\d+)", read())
    if m and int(m.group(1)) != st["build"]:
        fail(f"stale kernel: trace banner says build {m.group(1)}, "
             f"PING says {st['build']} — netboot served the wrong image")
    ok(f"running kernel is the staged build (#{st['build']})")

    hb0 = len(re.findall(r"\bhb \d+:", read()))
    deadline = time.time() + HEARTBEAT_FRESH_TIMEOUT_S
    while time.time() < deadline and len(re.findall(r"\bhb \d+:", read())) <= hb0:
        time.sleep(0.5)
    if len(re.findall(r"\bhb \d+:", read())) <= hb0:
        fail(f"INSTRUMENT DEAD: netdebug heartbeat — none within "
             f"{HEARTBEAT_FRESH_TIMEOUT_S}s", grep="hb ")
    if schedclock.tick_period_ms(read()) is None:
        fail("INSTRUMENT DEAD: heartbeat carries no usable ticks/tick_ms fields",
             grep="hb ")
    # DIAG-007: the periodic heartbeat carries liveness AND timer-tick health;
    # DIAG-004: this stream over :9514 is the evidence channel every verdict
    # in this suite reads, with hard timeouts — a dead facility fails the run.
    ok("netdebug heartbeat flowing (tick period known)")

    # Typed probes go through a fresh F12 terminal: it takes focus itself, so
    # this works whatever window (or nothing) held focus beforehand — on the
    # qemu track the in-kernel verify stages have just churned the desktop.
    obs_id, _obs_chan = open_terminal(q)

    # Typed round-trip AND the core count in one probe: `ps` walks every online
    # core, so its row count is the authoritative topology (the one-shot
    # `smp: N usable cores` boot line can be lost on the native transport).
    scoped, _ = obs_cmd(q, "ps", ("CORE", "ROLE", PS_COMPLETE))
    ncores = len(parse_ps(scoped))
    if ncores < 2:
        fail(f"SMP kernel shows {ncores} core row(s) in ps — is this kudos-smp?",
             grep="term.")
    ok(f"typed command round-trip; SMP up with {ncores} online cores")

    counters_dump(client)
    ok("OP_STATS dump reaches the trace")

    if GPU:
        if cadence.FIRST_PRESENT_ANCHOR not in read():
            fail("INSTRUMENT DEAD: no first GPU present — the desktop never "
                 "reached the panel", grep="gpu.")
        ok("first GPU present reached the panel")
        deadline = time.time() + BOOT_VERDICT_TIMEOUT_S
        while time.time() < deadline and cadence.verdict_count(read()) < 1:
            time.sleep(1)
        if cadence.verdict_count(read()) < 1:
            fail(f"INSTRUMENT DEAD: FLIPSTAT — the from-first-present verdict "
                 f"never emitted within {BOOT_VERDICT_TIMEOUT_S}s of boot "
                 f"(the known kudos-smp-on-hardware regression)", grep="FLIPSTAT")
        good, detail = cadence.judge_window(cadence.latest_verdict(read()))
        if not good:
            fail(f"boot cadence window failed: {detail}", grep="FLIPSTAT")
        ok(f"smooth from the first present ({detail}) [PERF-001/PERF-003]")
        flipstat_pass(q, "idle desktop re-arm")
        shot, capture_s = rpc("KMR1 SHOT", client.screenshot_timed, SHOT_DIR)
        # PERF-012: the CAPTURE completes in under a second — trigger to the
        # artifact landing in the ramdisk. The download that follows is
        # transport, not capture, and is excluded on purpose.
        if capture_s >= 1.0:
            fail(f"screenshot capture took {capture_s:.2f}s — over the 1 s budget (PERF-012)")
        ok(f"SHOT capture in {capture_s * 1000:.0f} ms (PERF-012 budget 1 s); artifact {shot}")
    else:
        # No GPU in the smoke boot: the instrument must still ANSWER, with the
        # honest error the case table owns.
        case = next(c for c in cases.CASES
                    if c.cmd == "flipstat" and c.track == "emulated")
        obs_cmd(q, case.cmd, case.expects, label="flipstat (no-GPU answer)")
        ok("flipstat answers honestly with no GPU present path")

    exit_focused(q, obs_id)
    # The loss baseline is taken LAST — after the GPU asserts and the SHOT.
    # The SHOT's PNG encode runs seconds inside the system task and stalls
    # presents (a filed finding of its own); taken earlier, that EXPECTED
    # movement (frame_drops, input_present_max_us) charges the NEXT phase's
    # sweep and reds a healthy load phase.
    base = counters_dump(client)
    ok("counter baseline taken (post-instruments)")
    return ncores, base


# ── phase LOAD (KRN-009/010/011 + KRN-008 + KRN-012 + PERF-003) ─────────────

def phase_load(q, client, ncores, base):
    oversub = rng.randint(OVERSUB_MIN, OVERSUB_MAX)
    npeg = min(ncores + oversub, PEG_WINDOWS_MAX)
    target = rng.randrange(PEG_PRIME_MIN, PEG_PRIME_MAX)
    oversubscribed = npeg > ncores
    phase(f"LOAD — {npeg} prime-pegged terminals on {ncores} cores "
            f"({'oversubscribed' if oversubscribed else 'spread'}; prime {target})")
    n0 = b1.wm()["nwins"]

    pegged = []
    for _ in range(npeg):
        wid, chan = open_terminal(q)
        b1.type_cmd(q, f"prime {target}")
        pegged.append((wid, chan))
    obs_id, obs_chan = open_terminal(q)
    ok(f"{npeg} pegged terminals + observer opened (wm.nwins {n0} -> {n0 + npeg + 1})")

    # First `ps` primes each core's CPU% window; the second, LOAD_WINDOW_S
    # later, reports load over exactly that window.
    obs_cmd(q, "ps", ("CORE", PS_COMPLETE))
    status0 = schedclock.parse_status(rpc("KMR1 PING", client.ping))
    t0 = time.time()
    time.sleep(LOAD_WINDOW_S)
    scoped, _ = obs_cmd(q, "ps", ("CORE", PS_COMPLETE))
    rows = parse_ps(scoped)
    if len(rows) < ncores:
        # A core VANISHING is a defect (retirement would have been loud, ps
        # must walk every online core). More cores is not: AP bring-up is
        # staggered by design (stragglers join the scheduler — and the tick
        # rotation — whenever they come up), and INSTRUMENTS may have counted
        # before the tail finished on a slow parallel boot.
        fail(f"ps walked {len(rows)} cores under load, expected {ncores}",
             grep=f"term.{obs_chan}")
    if len(rows) > ncores:
        _record(f"boot3:   NOTE {len(rows) - ncores} straggler core(s) joined "
                f"after INSTRUMENTS — topology now {len(rows)} cores")
        ncores = len(rows)
        oversubscribed = npeg > ncores

    # KRN-005: per-task CPU time is ACCOUNTED, not merely printed. A prime
    # task pegging a core for LOAD_WINDOW_S must show a `=Nms` charge of at
    # least a large fraction of that window; a counter stuck at 0 (or one
    # charging every task the same) passes every other assertion here.
    charges = [int(m) for m in re.findall(r"\[prime\][^\n]*?=(\d+)ms", scoped)]
    if not charges:
        charges = [int(m) for m in re.findall(r"=(\d+)ms", scoped)]
    busy_ms = max(charges) if charges else 0
    floor_ms = int(LOAD_WINDOW_S * 1000 * 0.5)
    if busy_ms < floor_ms:
        fail(f"KRN-005: busiest task charged {busy_ms}ms over a {LOAD_WINDOW_S}s "
             f"load window (expected >= {floor_ms}ms) — per-task CPU accounting "
             f"is not tracking real time", grep=f"term.{obs_chan}")
    ok(f"per-task CPU time accounted ({busy_ms}ms charged under load, KRN-005)")

    prime_cores = {c for c, (_pct, tasks) in rows.items() if "[prime]" in tasks}
    if oversubscribed:
        lazy = {c: pct for c, (pct, _t) in rows.items() if pct < CORE_BUSY_MIN_PCT}
        if lazy:
            fail(f"KRN-010: core(s) under {CORE_BUSY_MIN_PCT}% while {npeg} tasks "
                 f"compete for {ncores} cores: {lazy}", grep=f"term.{obs_chan}")
        ok(f"KRN-010: no core idles while tasks wait "
           f"(all {ncores} cores >= {CORE_BUSY_MIN_PCT}% with {npeg} tasks)")
    else:
        if len(prime_cores) != npeg:
            fail(f"KRN-009/010: {npeg} primes share only {len(prime_cores)} cores "
                 f"while cores idle (primes on {sorted(prime_cores)})",
                 grep=f"term.{obs_chan}")
        ok(f"KRN-009/011: {npeg} primes on {npeg} distinct cores {sorted(prime_cores)}")
    if len(prime_cores) < 2:
        fail(f"placement never left one core (primes on {sorted(prime_cores)})")
    ok(f"tasks appear across cores ([prime] on {len(prime_cores)} cores)")

    # KRN-012: the tick keeps its rate under full load, wall clock as witness.
    status1 = schedclock.parse_status(rpc("KMR1 PING", client.ping))
    wall = time.time() - t0
    good, detail = schedclock.judge_tick_advance(
        status0["ticks"], status1["ticks"], wall, schedclock.tick_period_ms(read()))
    if not good:
        fail(f"KRN-012 under load: {detail}", grep="hb ")
    ok(f"KRN-012: tick alive at rate under load ({detail})")

    # KRN-008: a deadline-sleeping task keeps its schedule while every core is
    # contested; the kernel's own rt report is the measurement.
    scoped, _ = obs_cmd(q, f"rt {RT_LOAD_PERIODS}", ("ns; drift = ",),
                        deadline_s=RT_LOAD_PERIODS // 10 + 20)
    good, detail = schedclock.judge_rt(schedclock.parse_rt(scoped), RT_LOAD_PERIODS)
    if not good:
        fail(f"KRN-008 under full load: {detail}", grep="rt:")
    ok(f"KRN-008: deadline sleep holds under full load ({detail})")

    if GPU:
        flipstat_pass(q, "all cores loaded")  # PERF-003 under load

    # Teardown: newest first, so every close box is uncovered when clicked.
    for wid, chan in reversed(pegged):
        close_window(q, wid, f"pegged term #{chan}")
    refocus_window(q, obs_id)
    scoped, _ = obs_cmd(q, "ps", ("CORE", PS_COMPLETE))
    if "[prime]" in scoped:
        fail("a prime survived its window's close (cancel did not propagate)",
             grep=f"term.{obs_chan}")
    ok("every prime cancelled by its window's close")
    exit_focused(q, obs_id)
    st = b1.wm_wait(lambda s: s["nwins"] == n0, deadline_s=10)
    if st["nwins"] != n0:
        fail(f"load teardown leaked windows (nwins {st['nwins']} != {n0})")
    ok("window set restored after the load teardown")
    return sweep(client, "the load phase", base)


# ── phase GUEST (exactly-once `vm boot` + PERF-017) ─────────────────────────

# VIRT-014: a stopped guest returns every byte it held (the memory baseline
# below); VIRT-017: guests start and stop from shell commands.
def phase_guest(q, client, base):
    phase("GUEST — one command, one guest; vCPU as a scheduled task"
            + ("; 60 Hz alongside" if GPU else ""))
    # Escape hatch for iterating on the other phases while a guest-launch
    # defect is fatal to the whole boot: the skip is loud, never silent.
    if os.environ.get("BOOT3_SKIP_GUEST") == "1":
        _record("boot3:   SKIP guest phase — BOOT3_SKIP_GUEST=1")
        return base
    obs_id, obs_chan = open_terminal(q)
    scoped, _ = obs_cmd(q, "vm", ("vm:",))
    if "VT-x not available" in scoped:
        _record("boot3:   SKIP guest phase — no VT-x on this machine "
                "(a property of the host, not a regression)")
        exit_focused(q, obs_id)
        return base
    mem0 = mem_free_mib(q)
    ups0 = guest_up_count()
    wins_before = set(b1.wm()["wins"])

    b1.type_cmd(q, "vm boot 1")
    deadline = time.time() + 10
    resp = ""
    while time.time() < deadline and "vm:" not in resp:
        resp = scoped_on(obs_chan, "vm boot 1") or ""
        time.sleep(0.3)
    if "no guest image staged" in resp:
        _record("boot3:   SKIP guest phase — no guest image staged in this build")
        exit_focused(q, obs_id)
        return base
    if "booting a guest" not in resp:
        fail(f"`vm boot 1` did not start a guest: {resp!r}", grep=f"term.{obs_chan}")

    deadline = time.time() + GUEST_BOOT_TIMEOUT_S
    while time.time() < deadline and guest_up_count() < ups0 + 1:
        time.sleep(1)
    if guest_up_count() < ups0 + 1:
        fail(f"guest never reached userspace within {GUEST_BOOT_TIMEOUT_S}s "
             f"(no KUDOS-GUEST-UP)", grep="vm0")
    ok("guest booted Linux to userspace (KUDOS-GUEST-UP)")

    # EXACTLY-ONCE: the first hardware boot showed one injected `vm boot 1`
    # producing TWO guests (a KMR1 request-id dedup race once the service could
    # run on any core). Give a phantom twin time to boot, then count.
    time.sleep(GUEST_DUP_SETTLE_S)
    # The VM console window took focus when it opened; typed keys would go to
    # the GUEST. Put focus back on the observer shell before typing anything.
    refocus_window(q, obs_id)
    ups = guest_up_count()
    if ups != ups0 + 1:
        fail(f"one `vm boot 1` produced {ups - ups0} guests — KMR1 exactly-once "
             f"broken under SMP", grep="KUDOS-GUEST-UP")
    scoped, _ = obs_cmd(q, "vm", ("vm:",))
    rows = vm_rows(scoped)
    if len(rows) != 1:
        fail(f"one `vm boot 1` left {len(rows)} guest slots in use: {rows}",
             grep=f"term.{obs_chan}")
    gid, core, state, exits0 = rows[0]
    if state != "running":
        fail(f"guest not running (vm {gid}: {state})", grep=f"term.{obs_chan}")
    if core == "-":
        fail("guest vCPU never bound a core — the single-core kernel's "
             "'exits 0, core -' shape, on kudos-smp")
    ok(f"exactly one guest for one command (vm {gid}, running on core {core})")

    time.sleep(GUEST_EXITS_WINDOW_S)
    scoped, _ = obs_cmd(q, "vm", ("vm:",))
    rows = vm_rows(scoped)
    if not rows or rows[0][3] <= exits0:
        fail(f"guest exits not climbing ({exits0} -> "
             f"{rows[0][3] if rows else 'gone'}) — vCPU not being scheduled",
             grep=f"term.{obs_chan}")
    ok(f"guest vCPU executing as a scheduled task (exits {exits0} -> {rows[0][3]})")

    if GPU:
        flipstat_pass(q, "guest running")  # PERF-017

    # Teardown: the scriptable stop, then the window close that retires the slot.
    obs_cmd(q, f"vm stop {gid}", ("vm: stop requested",))
    deadline = time.time() + GUEST_STOP_TIMEOUT_S
    while time.time() < deadline:
        scoped, _ = obs_cmd(q, "vm", ("vm:",))
        rows = vm_rows(scoped)
        if not rows or rows[0][2] != "running":
            break
        time.sleep(1)
    else:
        fail(f"guest still running {GUEST_STOP_TIMEOUT_S}s after `vm stop`",
             grep=f"term.{obs_chan}")
    ok("`vm stop` halted the guest")

    vm_wins = [w for w in b1.wm()["wins"] if w not in wins_before and w != obs_id]
    if len(vm_wins) != 1:
        fail(f"expected exactly one VM window, found {vm_wins}")
    # Raise the VM window first: the earlier refocus put the observer shell on
    # top, and its body covers the VM window's close box (the cascade offset
    # exceeds the title-bar height) — a click there lands on the observer.
    refocus_window(q, vm_wins[0])
    close_window(q, vm_wins[0], "VM console window")
    refocus_window(q, obs_id)
    scoped, _ = obs_cmd(q, "vm", ("vm:",))
    if vm_rows(scoped):
        fail(f"guest slot still in use after its window closed: {vm_rows(scoped)}",
             grep=f"term.{obs_chan}")
    ok("guest slot retired when its window closed")
    mem1 = mem_free_mib(q)
    if mem0 - mem1 > MEM_TOLERANCE_MB:
        fail(f"guest teardown leaked ~{mem0 - mem1} MiB ({mem0} -> {mem1} MiB free)")
    ok(f"guest memory reclaimed ({mem1} MiB free, baseline {mem0})")
    exit_focused(q, obs_id)
    return sweep(client, "the guest phase", base)


# ── phase CHURN (session address-space create/teardown under load) ──────────

def phase_churn(q, client, base):
    cycles = rng.randint(CHURN_CYCLES_MIN, CHURN_CYCLES_MAX)
    target = rng.randrange(PEG_PRIME_MIN, PEG_PRIME_MAX)
    phase(f"CHURN — {cycles} session open/close cycles with "
            f"{CHURN_BG_PRIMES} cores pegged (address spaces + TLB shootdowns)")

    obs_id, _ = open_terminal(q)
    mem0 = mem_free_mib(q)
    # MEM-008: the accounting must track the sessions actually open — it moves
    # with this terminal, so a figure frozen at boot (or at zero) fails here.
    held_n0, held_mb0 = sessions_held(q)
    if held_n0 < 1 or held_mb0 < 1:
        fail(f"MEM-008: {held_n0} session(s) holding {held_mb0} MiB while a "
             f"terminal is open — per-address-space accounting is not tracking")
    exit_focused(q, obs_id)

    bg = []
    for _ in range(CHURN_BG_PRIMES):
        wid, chan = open_terminal(q)
        b1.type_cmd(q, f"prime {target}")
        bg.append((wid, chan))

    for i in range(cycles):
        wid, chan = open_terminal(q)
        marker = f"churn-{i}-ok"
        obs_cmd(q, f"echo {marker}", (marker,))
        exit_focused(q, wid)
    ok(f"{cycles} open/echo/close cycles — every session created, ran, tore down")

    for wid, chan in reversed(bg):
        close_window(q, wid, f"background prime term #{chan}")

    obs_id, obs_chan = open_terminal(q)  # F12: takes focus itself
    scoped, _ = obs_cmd(q, "ps", ("CORE", PS_COMPLETE))
    if "[prime]" in scoped:
        fail("a background prime survived its close", grep=f"term.{obs_chan}")
    mem1 = mem_free_mib(q)
    if mem0 - mem1 > MEM_TOLERANCE_MB:
        fail(f"session churn leaked ~{mem0 - mem1} MiB of physical RAM "
             f"({mem0} -> {mem1} MiB free)")
    ok(f"physical RAM back after churn ({mem1} MiB free, baseline {mem0})")
    held_n1, held_mb1 = sessions_held(q)
    if held_n1 > held_n0 or held_mb1 > held_mb0:
        fail(f"MEM-008: sessions still accounted after churn — {held_n1} holding "
             f"{held_mb1} MiB, baseline {held_n0} holding {held_mb0} MiB "
             f"(a leaked address space)")
    ok(f"per-address-space accounting back after churn ({held_n1} holding "
       f"{held_mb1} MiB, MEM-008)")
    exit_focused(q, obs_id)
    return sweep(client, "the churn phase", base)


# ── phase FAULT (induced session memory fault: MEM-005/006) ─────────────────

# The one cr2 the run may see in a crash record: memfault's probe address
# (src/console/cmd/memfault.zig UNMAPPED_PROBE_ADDR = 1 << 45).
INDUCED_FAULT_CR2 = "cr2=0x0000200000000000"
induced_faults = [0]


def phase_memfault(q, client, base):
    """One deliberately-unmapped read inside a session: the fault must be
    COUNTED (mem.space_faults +1, exactly — MEM-005), the faulting session's
    window must close, and every other session and the desktop must carry on
    untouched (MEM-006). The loss watch inverts for this phase: the induced
    fault is the one increment that MUST appear."""
    phase("FAULT — induced unmapped read, contained and counted")

    survivor_id, survivor_chan = open_terminal(q)
    victim_id, victim_chan = open_terminal(q)
    before = counters_dump(client)

    b1.type_cmd(q, "memfault")
    induced_faults[0] += 1
    st = b1.wm_wait(lambda s: victim_id in s["closed"], deadline_s=15)
    if victim_id not in st["closed"]:
        fail(f"memfault window {victim_id} never closed — fault not contained",
             grep=f"term.{victim_chan}")
    ok("faulting session's window closed (fault contained to its session)")

    if st["focus"] is None or st["focus"][0] != survivor_id:
        refocus_window(q, survivor_id)
    marker = "survivor-alive"
    obs_cmd(q, f"echo {marker}", (marker,))
    ok("sibling session undisturbed by the fault (MEM-006)")

    after = counters_dump(client)
    d_space = after.get("mem.space_faults", 0) - before.get("mem.space_faults", 0)
    if d_space != 1:
        fail(f"mem.space_faults moved by {d_space}, expected exactly 1 "
             f"(MEM-005: the fault must be counted, once)")
    ok("mem.space_faults counted the fault, exactly once (MEM-005)")

    keys = [k for k in counters.loss_keys(emulated=not GPU)
            if k != "mem.space_faults"]
    regs = counters.regressions(before, after, keys)
    if regs:
        fail("collateral loss during the induced fault: "
             + ", ".join(f"{k} {b}->{a}" for k, b, a in regs))
    ok("no collateral loss beyond the one induced fault")

    # DIAG-013: the fault's crash record — with its backtrace — must reach the
    # trace over netdebug; the record is the induced one (cr2-matched below in
    # the run-level scan), and its BT lines are the streamed backtrace.
    tail = read()
    if INDUCED_FAULT_CR2 not in tail or "*** BT" not in tail.split(INDUCED_FAULT_CR2, 1)[1]:
        fail("the induced fault's crash record/backtrace never reached the trace "
             "(DIAG-013)", grep="***")
    ok("crash record with backtrace shipped over netdebug (DIAG-013)")

    exit_focused(q, survivor_id)
    return after


# ── phase WAKE STORM (concurrent deadline sleepers) ─────────────────────────

def phase_wakestorm(q, client, base):
    nterms = rng.randint(WAKESTORM_TERMS_MIN, WAKESTORM_TERMS_MAX)
    phase(f"WAKE STORM — {nterms} concurrent rt tasks "
            f"({RT_STORM_PERIODS} periods @ 10 Hz; deadlines share one lattice)")
    n0 = b1.wm()["nwins"]

    storms = []
    for _ in range(nterms):
        wid, chan = open_terminal(q)
        b1.type_cmd(q, f"rt {RT_STORM_PERIODS}")
        storms.append((wid, chan))

    # Concurrency receipt: several [rt] activities visible at one instant.
    # The receipt must land INSIDE the storm (RT_STORM_PERIODS/10 s), so the
    # ps gets short per-attempt deadlines and its own retry loop — obs_cmd's
    # full-length retry would reissue after the storm already finished (a lost
    # UDP line then reads as "never concurrent" on a healthy machine).
    obs_id, obs_chan = open_terminal(q)
    live = 0
    receipt_deadline = time.time() + RT_STORM_PERIODS / 10 - 5
    while time.time() < receipt_deadline and live < 2:
        chan = b1.type_cmd(q, "ps")
        attempt_deadline = time.time() + 6
        while time.time() < attempt_deadline:
            scoped = scoped_on(chan, "ps")
            if scoped is not None and PS_COMPLETE in scoped:
                live = scoped.count("[rt]")
                break
            time.sleep(0.3)
    if live < 2:
        fail(f"wake storm never concurrent ({live} live rt tasks in ps)",
             grep=f"term.{obs_chan}")
    ok(f"{live} rt tasks sleeping/waking concurrently")

    results = {}
    deadline = time.time() + RT_STORM_PERIODS / 10 + 45
    while time.time() < deadline and len(results) < nterms:
        for _wid, chan in storms:
            if chan in results:
                continue
            res = schedclock.parse_rt(scoped_on(chan, f"rt {RT_STORM_PERIODS}") or "")
            if res:
                results[chan] = res
        time.sleep(0.5)
    if len(results) < nterms:
        missing = [chan for _w, chan in storms if chan not in results]
        fail(f"rt storm: no result from term(s) {missing} — a sleeper was lost",
             grep="rt:")
    for chan in sorted(results):
        good, detail = schedclock.judge_rt(results[chan], RT_STORM_PERIODS)
        if not good:
            fail(f"KRN-008 in the wake storm (term #{chan}): {detail}", grep="rt:")
    ok(f"all {nterms} concurrent rt tasks met jitter/drift bounds")

    exit_focused(q, obs_id)
    for wid, chan in reversed(storms):
        close_window(q, wid, f"storm term #{chan}")
    st = b1.wm_wait(lambda s: s["nwins"] == n0, deadline_s=10)
    if st["nwins"] != n0:
        fail(f"wake-storm teardown leaked windows (nwins {st['nwins']} != {n0})")
    ok("window set restored after the wake storm")
    return sweep(client, "the wake storm", base)


# ── entry ───────────────────────────────────────────────────────────────────

def wait_ready():
    """Block until kudos is driveable: a terminal is up, the (re-emitted)
    build banner has arrived, AND a KMR1 ping answers. The ping is part of
    readiness, not a courtesy: on kudos-smp bare metal the terminal appears
    seconds before the NIC can carry a unicast reply (DHCP still in flight,
    plus the I226's ~10 s post-link frame-eating window) — probing the
    injector before the transport answers convicts a healthy boot."""
    deadline = time.time() + READY_TIMEOUT_S
    pinged = False
    while time.time() < deadline:
        log = read()
        try:
            kmir.Client(KUDOS_IP).ping()
            pinged = True
        except Exception:
            pinged = False  # not up yet — that is what we are waiting for
        if pinged and bn._terminal_up(log) and re.search(r"kudos build #\d", log):
            return
        time.sleep(1)
    fail(f"kudos not driveable within {READY_TIMEOUT_S}s "
         f"(terminal up: {bn._terminal_up(read())}, KMR1 ping ok: {pinged})")


def wait_verify():
    """qemu track: the boot runs the -Dverify-script in-kernel stages first
    (KRN-010's idle-vs-waiting oracle, the wake storm, the loss counters —
    assertions only the kernel can make). Wait for its verdict before
    injecting anything: the verify task is a second input producer until then."""
    deadline = time.time() + VERIFY_TIMEOUT_S
    while time.time() < deadline:
        log = read()
        if "verify: FAILURES PRESENT" in log:
            fail("in-kernel verify stages FAILED", grep="FAIL:")
        if "verify: ALL PASS" in log:
            m = re.search(r"verify: (\d+) passed, (\d+) failed", log)
            ok(f"in-kernel verify stages green "
               f"({m.group(1) if m else '?'} assertions)")
            return
        time.sleep(2)
    fail(f"in-kernel verify stages produced no verdict within {VERIFY_TIMEOUT_S}s",
         grep="verify")


def main():
    b1.SERIAL_LOG = NETDEBUG_LOG
    b1.TRACK = "native"
    b1.EXACT_COUNTS = False
    b1.ASSERT_USB_REPORT_COUNTS = False
    track = f"boot-3-{TRACK}"
    b1.RESULT_LOG = os.path.join(b1.ROOT, "build", "logs", f"{track}-result.log")
    try:
        os.makedirs(os.path.dirname(b1.RESULT_LOG), exist_ok=True)
        open(b1.RESULT_LOG, "w").close()
    except OSError:
        pass

    _record(f"boot3: {track} on {KUDOS_IP} — seed {SEED} "
            f"(BOOT3_SEED={SEED} reproduces this run)"
            + (f", soak {SOAK_MIN:g} min" if SOAK_MIN else ""))
    wait_ready()
    if os.environ.get("BOOT3_WAIT_VERIFY") == "1":
        wait_verify()

    # The injector's constructor homes the pointer over KMR1 — already a
    # round-trip, so a dead service fails here by name, not with a traceback.
    q = rpc("KMR1 pointer home", kmr1_input.Kmr1Input, KUDOS_IP)
    client = q.c
    ncores, base = phase_instruments(q, client)

    soak_deadline = time.time() + SOAK_MIN * 60
    cycle = 0
    while True:
        cycle += 1
        if SOAK_MIN:
            _record(f"boot3: SOAK cycle {cycle}")
        # The cadence sampler is re-armed INSIDE each cycle (phase_load and
        # phase_guest both run flipstat_pass on the GPU track), so a soak run
        # keeps demanding fresh full-window PASS verdicts, not one stale one.
        base = phase_load(q, client, ncores, base)
        base = phase_guest(q, client, base)
        base = phase_churn(q, client, base)
        base = phase_memfault(q, client, base)
        base = phase_wakestorm(q, client, base)
        if time.time() >= soak_deadline:
            break

    # A contained fault is a survivable event for the machine and a hard FAIL
    # for the run: a retired core silently narrows the machine under test. The
    # FAULT phase's induced session fault is the ONE excused exception record,
    # identified by its cr2 — the probe address memfault reads
    # (src/console/cmd/memfault.zig UNMAPPED_PROBE_ADDR); anything else fails.
    blob = read()
    for marker, what in (("wedge:", "a wedge report"),
                         ("fault contained", "a fault-containment core retirement")):
        if marker in blob:
            fail(f"{what} fired during the run", grep=marker)
    exceptions = [ln for ln in blob.splitlines() if "*** CPU EXCEPTION" in ln]
    stray = [ln for ln in exceptions if INDUCED_FAULT_CR2 not in ln]
    if stray or len(exceptions) != induced_faults[0]:
        fail(f"{len(exceptions)} CPU exception record(s), {induced_faults[0]} induced "
             f"({len(stray)} unexplained)", grep="*** CPU EXCEPTION")
    ok("diagnostics quiet through the whole run (every exception record accounted)")
    _record(f"boot3: PASS — {b1.passed} assertions green "
            f"({cycle} cycle(s), seed {SEED})")


if __name__ == "__main__":
    main()
