#!/usr/bin/env python3
"""Boot-1 integration driver — the emulated-VGA track (no GPU).

Assumes run_emulated.sh has already built the -Dserial-uart -Dtest-hooks ISO,
launched it headless (QMP at /tmp/qmp.sock, netdebug capture at /tmp/netdebug.log),
and waited for boot. Five phases, simplest first, every one asserting against
records the kudos test hooks emit (terminal mirror `term.*`, WM mirror `wm.*`):

  1. BOOT + DEVICES — boot banner; xhci up + exact KEYBOARD/MOUSE detection;
     enumeration counts; injected-HID report counters (kbd=12 mouse=4, the
     "detected but dead" guard); /usbdisk FAT mount.
  2. COMMANDS — every emulated/both case from cases.py, each with ALL its
     expected substrings asserted against that command's own mirrored output.
  3. WINDOWS + HOTKEYS + HISTORY — `term`/`system` open windows (wm.nwins,
     wm.focus move); typing lands in the new focused terminal; `exit` closes it
     and focus returns; F10 opens the AI agent window; F12 opens a terminal;
     Up-arrow recalls the last command.
  4. MOUSE / WM BEHAVIOURS — closed-loop pointer driving (wm.ptr verifies where
     each click actually landed, defeating pointer-acceleration drift):
     click-to-focus, title-bar drag moves the window, maximise box maximises,
     second click restores the exact geometry, grip-resize grows the window,
     close box closes it.
  5. CLOSE RECOVERY — `exit` on the last terminal: the desktop opens a recovery
     terminal (greeting appears again), the session stays usable.

Readback is the NETDEBUG capture (UDP :9514 — there is no serial port); injection is QMP/PS2 via qmp.py. Fails LOUD (the
first missing assertion exits non-zero, with the offending records). Every
result line is mirrored to build/logs/boot1-result.log so the verdict survives even
when the invoking harness swallows stdout.
"""

import re
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))  # repo root
sys.path.insert(0, os.path.join(ROOT, "scripts", "debug"))  # for qmp.py

import qmp  # noqa: E402
import cases  # noqa: E402

SERIAL_LOG = "/tmp/netdebug.log"  # kudos has no UART; readback is netdebug (UDP :9514)
# Durable verdict log on persistent disk (build/logs — NOT tmpfs: a host
# power-cycle must never destroy the evidence exactly when it matters).
RESULT_LOG = os.path.join(ROOT, "build", "logs", "boot1-result.log")
os.makedirs(os.path.dirname(RESULT_LOG), exist_ok=True)

# Tier-1 device assertions (all verified against xhci.zig / live runs).
BOOT_BANNER = "kudos build #"
KBD_READY = "xhci:  -> KEYBOARD ready"
MOUSE_READY = "xhci:  -> MOUSE ready"
XHCI_RUNNING = "xhci: running"
# COUNTS ARE A PROPERTY OF THE RIG, NOT OF KUDOS. Under QEMU the peripherals are
# exactly what we attach (usb-kbd + usb-tablet + usb-storage), so the emulated track
# asserts them EXACTLY — that is a real regression check. lemon has whatever is plugged
# into it (hubs, audio, an LED controller, a Bluetooth radio), so the native track can
# only assert the INVARIANT: at least a keyboard and a mouse, on at least three ports.
# Asserting QEMU's numbers on real hardware would be testing the desk, not the kernel.
MIN_HID_DEVICES = 2  # kbd + mouse (MSC counted apart)
MIN_PORTS_CONNECTED = 3  # kbd + mouse + storage stick
EXACT_COUNTS = True  # emulated: the rig is known. boot1_native.py sets this False.
ASSERT_USB_REPORT_COUNTS = True  # see phase1 — emulated-only by construction.
TRACK = "emulated"  # which cases.py variants to run; boot1_native.py sets this "native".
# KUDOS_SMP=1 (set by the run_emulated.sh --smp path) boots the multi-core kernel: run
# the SMP-track cases IN ADDITION to the base suite, assert the AP bring-up trace, and
# drive a terminal pinned to an Application Processor (the cross-core phase).
SMP = os.environ.get("KUDOS_SMP") == "1"
USBDISK_MOUNT = "usbdisk: FAT volume mounted at /usbdisk"
HID_EXPECT = "usb.reports = kbd=12 mouse=4"

TERM_GREETING = "kudos terminal. type 'help'."

passed = 0  # incremented per successful assertion; reported at the end


def _record(line):
    print(line, flush=True)
    try:
        with open(RESULT_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def read_serial():
    with open(SERIAL_LOG, "r", errors="replace") as f:
        return f.read()


# main's QMP handle, published so fail() can dump vcpu registers on the way out.
g_qmp = None


def fail(msg, context_grep=None):
    _record(f"boot1: FAIL — {msg}")
    if context_grep:
        blob = read_serial()
        hits = [ln for ln in blob.splitlines() if context_grep in ln]
        for ln in hits[-10:]:
            _record("   " + ln)
    # Where is every core, RIGHT NOW? A cross-core stall (a spinlock held with
    # IRQs off goes completely dark — no wedge report, no trace) leaves its only
    # evidence in the vcpus' registers. Reuses main's QMP handle: QEMU serves ONE
    # QMP client, so opening a second connection here would block forever.
    if g_qmp is not None:
        try:
            # TWO samples, 300 ms apart: a single snapshot cannot distinguish a
            # core STUCK at an address from one merely passing through it. Same
            # RIP twice (especially with IF=0) = genuinely wedged there.
            for tag in ("t0", "t1"):
                regs = g_qmp.cmd(
                    "human-monitor-command", **{"command-line": "info registers -a"}
                ).get("return", "")
                for ln in regs.splitlines():
                    if "CPU#" in ln or ln.startswith("RIP") or "RFL" in ln:
                        _record(f"   [{tag}] " + ln.strip())
                if tag == "t0":
                    time.sleep(0.3)
        except Exception:
            pass
    _record(f"boot1: {passed} assertions passed before the failure")
    sys.exit(1)


def ok(what):
    global passed
    passed += 1
    _record(f"boot1:   OK  {what}")


def serial_size():
    try:
        return os.path.getsize(SERIAL_LOG)
    except OSError:
        return 0


def wait_quiescent(idle_s=0.4, timeout_s=15):
    """Block until the serial log stops growing for `idle_s` (the action has
    finished emitting) or `timeout_s` elapses — robust for instant commands and
    slow ones (prime/rt, cold USB reads) alike."""
    deadline = time.time() + timeout_s
    last = serial_size()
    quiet_since = time.time()
    while time.time() < deadline:
        time.sleep(0.1)
        now = serial_size()
        if now != last:
            last = now
            quiet_since = time.time()
        elif time.time() - quiet_since >= idle_s:
            return


def wm():
    return cases.wm_state(read_serial())


def wm_wait(pred, deadline_s=8):
    """Poll the replayed WM state until `pred(state)` holds. The wm.* records
    ride the METERED trace drain and can trail the action they describe by
    seconds under load — a snapshot taken right after an action races the
    record and blames the kernel for the transport's latency. On timeout the
    final state is returned so the caller's assert fails with real values."""
    deadline = time.time() + deadline_s
    st = wm()
    while time.time() < deadline:
        if pred(st):
            return st
        time.sleep(0.3)
        st = wm()
    return st


def active_core():
    """The core whose terminal currently has focus, from wm.focus ('id:term #N').

    Keystrokes follow focus, and each terminal mirrors on its OWN core channel
    (dbg: term.<core>). On the single-core kernel the only terminal is ever
    'term #0', so this is always 0 and every caller behaves exactly as before. On
    the SMP kernel `term` opens on an Application Processor, so the focused terminal
    — and thus the mirror channel to read — moves to that core. Non-terminal focus
    (a model/system window) falls back to 0."""
    foc = wm().get("focus")
    if foc is None:
        return 0
    m = re.match(r"term #(\d+)", foc[1])
    return int(m.group(1)) if m else 0


def typeable(cmd):
    bad = [ch for ch in cmd if qmp.char_qcode(ch)[0] is None]
    if bad:
        fail(f"command {cmd!r} has untypeable char(s) {bad!r}; extend qmp._SYMS")


# How long an echo may TRAIL its command before we conclude the keystrokes were
# lost: the mirror record ships on the metered netdebug drain, which a busy
# software render pumps in bursts — execution-to-wire latency of a second or two
# is normal there and is not input loss.
ECHO_TRAIL_S = 4.0


def type_cmd(q, cmd):
    """Type one command + Enter at the focused terminal and wait for it to run.
    Returns the core the command was typed INTO (its echo channel), so the caller
    can read that terminal's own mirror — on SMP the focused terminal may be on an
    Application Processor, not core 0.

    RETYPE ONCE IF THE ECHO NEVER APPEARS. On the native track the keystroke has to cross
    a lossy path — fileserv's RX slot is one deep, and kudos may be mid-`prime` with its
    core pegged — so a press can genuinely go missing. That presented as "command was
    never echoed (did it type?)" and made the suite flaky.
    Retyping is safe here and not a fudge: every case command is idempotent (help, ls,
    cat, echo, mem, ps, net, prime, cd), and _scoped_output reads from the LAST echo, so
    a duplicate that DID land is simply superseded. What is NOT safe is pretending the
    key landed — that turns a transport hiccup into a phantom kernel bug.
    """
    typeable(cmd)
    # The core we are typing INTO is whichever terminal has focus NOW — captured
    # before the command runs, because a focus-changing command (term/exit/system)
    # moves focus away, but its own echo lands on the terminal it was typed at.
    core = active_core()
    # SINCE-MARKER, not substring-anywhere: the echo must be NEW. A whole-mirror
    # substring test is satisfied by a PRIOR identical echo (`term`, `exit`, and
    # several cases are typed more than once per run), so a genuinely dropped
    # keystroke was never retyped and the run failed later with "the command
    # never took effect" — a harness bug masquerading as a kernel bug.
    echoes_before = cases.mirror_text(read_serial(), core=core).count(f"$ {cmd}")
    for attempt in (1, 2):
        q.type_str(cmd)
        q.key("ret")
        wait_quiescent()
        # The echo record rides the METERED trace drain, so it can trail the
        # command's execution by a second or two under render load. Poll for it
        # before concluding the keystrokes vanished: a premature retype of a
        # NON-idempotent command (`exit` closes whichever window has focus) acts
        # twice — that presented as "exit closed two windows" and failed the WM
        # phase on a kernel that had done exactly what it was told.
        deadline = time.time() + ECHO_TRAIL_S
        while time.time() < deadline:
            if cases.mirror_text(read_serial(), core=core).count(f"$ {cmd}") > echoes_before:
                return core
            time.sleep(0.3)
        if attempt == 1:
            _record(f"boot1:   (no echo for {cmd!r} — retyping once; lossy input path)")
    return core


def _scoped_output(cmd):
    """This command's own mirrored output: everything after the LAST `> <cmd>`
    echo line. None if the command was never echoed."""
    mirror = cases.mirror_text(read_serial(), core=0)
    idx = mirror.rfind(f"$ {cmd}")
    if idx == -1:
        return None
    nl = mirror.find("\n", idx)
    return mirror[nl + 1:] if nl != -1 else ""


def run_case(q, case, deadline_s=25):
    """Type the command, then POLL until every expected substring has appeared
    in its scoped output (or fail at the deadline). No quiescence heuristics: a
    command that computes QUIETLY (rt 5 spins for 0.5 s with the whole
    cooperative loop blocked and the serial silent) must not be asserted early —
    silence is not completion."""
    typeable(case.cmd)
    q.type_str(case.cmd)
    q.key("ret")
    deadline = time.time() + deadline_s
    last_err = None
    while time.time() < deadline:
        scoped = _scoped_output(case.cmd)
        if scoped is not None:
            try:
                cases.assert_case(case, scoped)
                last_err = None
                break
            except cases.CaseFailure as e:
                last_err = e  # output still streaming — keep polling
        time.sleep(0.2)
    else:
        if last_err is not None:
            fail(str(last_err), context_grep="term.0 = ")
        fail(f"command {case.cmd!r} was never echoed to the mirror (did it type?)",
             context_grep="term.0 = #0:")
    global passed
    passed += len(case.expects)
    _record(f"boot1:   OK  {case.cmd!r} ({len(case.expects)} assertions)")


# ── phase 1: boot + devices ────────────────────────────────────────────────

def phase1(q):
    _record("boot1: PHASE 1 — boot + device detection")
    # This phase's conversation is itself the ARP proof: the DHCP lease and every
    # unicast KMR1 request reach kudos only because it ANSWERS ARP requests for its
    # own address (NET-004), and its replies reach us only because it RESOLVES the
    # next hop's link-layer address (NET-005). Break either direction and the whole
    # suite goes dark before its first assertion.
    native = TRACK == "native"
    # The native transport ships telemetry over the LAN and the async DHCP bind
    # commits the lease a beat AFTER boot, so the ONE-SHOT boot lines (banner, "->
    # KEYBOARD ready", the enum-count dbg records) are queued while the trace is still
    # buffered/broadcast and a lost datagram makes a live kernel read as bannerless or
    # keyboardless (proven: the flight-recorder bootlog showed the keyboard reporting
    # on a boot whose netdebug capture had no "KEYBOARD ready"). So gate on the
    # RE-EMITTED equivalents there — the heartbeat banner and `usb.hid_present`, both
    # re-sent every heartbeat, recovered by the next beat. Emulated reads the exact
    # one-shot lines over the reliable QEMU serial mirror, unchanged.
    if native:
        checks = [
            (re.compile(r"kudos build #\d"), "boot banner (re-emitted)"),
            (re.compile(r"usb\.hid_present = kbd=[1-9]"), "keyboard enumerated (usb.hid_present)"),
            (re.compile(r"usb\.hid_present = kbd=\d+ mouse=[1-9]"), "mouse enumerated (usb.hid_present)"),
        ]
    else:
        checks = [
            (re.compile(re.escape(BOOT_BANNER)), "boot banner"),
            (re.compile(re.escape(XHCI_RUNNING)), "xhci controller running"),
            (re.compile(re.escape(KBD_READY)), "keyboard detected + configured"),
            (re.compile(re.escape(MOUSE_READY)), "mouse detected + configured"),
            (re.compile(re.escape(USBDISK_MOUNT)), "usbdisk FAT volume mounted"),
        ]
    # Poll: the re-emitted signals arrive on the heartbeat cadence, not instantly.
    deadline = time.time() + 30
    blob = read_serial()
    while time.time() < deadline and not all(rx.search(blob) for rx, _ in checks):
        time.sleep(0.5)
        blob = read_serial()
    for rx, label in checks:
        if not rx.search(blob):
            fail(f"{label}: absent", context_grep="xhci")
        ok(label)

    # DIAG-005: the build identity is the FIRST line of the trace — the kernel
    # queues it as record [000001] before link settle, so the sequence number
    # carries the position even if the datagram itself arrives late. On the
    # lossy native transport a vanished seq-1 is a transport gap, not a
    # position violation, so the assertion is emulated-only.
    if not native:
        first = re.search(r"^\[000001\] (.*)$", blob, re.M)
        if first is None or "NETDEBUG-BUILD kudos build #" not in first.group(1):
            fail("trace record [000001] is not the build banner: "
                 f"{first.group(1) if first else 'absent'}")
        ok("build banner is trace record #1")

    # Enum-count records are one-shot dbg lines, droppable on the native transport;
    # `usb.hid_present` above already proves the HID devices enumerated there. Assert
    # the exact counts only on the reliable emulated mirror.
    if not native:
        for record, minimum, label in [
            ("usb.devices_enum", MIN_HID_DEVICES, "HID devices enumerated"),
            ("usb.ports_connected", MIN_PORTS_CONNECTED, "USB ports connected"),
        ]:
            m = re.findall(rf"dbg: {re.escape(record)} = (\d+)", blob)
            if not m:
                fail(f"{label}: no `dbg: {record}` record at all", context_grep="xhci")
            got = int(m[-1])
            if EXACT_COUNTS and got != minimum:
                fail(f"{label}: expected exactly {minimum}, got {got}", context_grep=record)
            if got < minimum:
                fail(f"{label}: expected at least {minimum}, got {got}", context_grep=record)
            ok(f"{label} ({got})")

    # Injected-HID flow: exact decoded-report counters (2 moves + press/release
    # = 4 mouse reports; "hello"+Enter = 6 keys × press/release = 12 kbd reports).
    q.move(25, 10); time.sleep(0.2)
    q.move(-15, 5)
    q.button("left", True); q.button("left", False); time.sleep(0.2)
    q.type_str("hello"); q.key("ret")
    time.sleep(6)
    # EMULATED ONLY, and not an oversight. `usb.reports` counts REAL USB HID reports
    # decoded by xhci. QMP injection drives QEMU's usb-kbd/usb-tablet, so genuine USB
    # traffic is produced and the counters move — that is a true end-to-end test of the
    # HID pipeline. KMR1 injection enters DOWNSTREAM of that decoder (keyboard.inject /
    # imouse.aggregate), so on the native track these counters correctly stay at zero and
    # asserting them would be asserting a falsehood. Native covers the same ground
    # differently: the real keyboard and mouse must ENUMERATE (asserted above), and every
    # later phase proves injected input reaches the terminal and the window manager.
    if ASSERT_USB_REPORT_COUNTS:
        if HID_EXPECT not in read_serial():
            fail(f"injected input did not produce {HID_EXPECT!r}", context_grep="usb.reports")
        ok(f"USB input flow ({HID_EXPECT})")
    # The stray "hello" line lands at the shell as an unknown command — expected.

    if SMP:
        assert_smp_brought_up()


def assert_smp_brought_up():
    """Prove the multi-core kernel actually brought its Application Processors online
    (klog.puts traces, ungated — present without -Dtest-hooks). `smp: N usable cores
    discovered` (smp.zig init) with N >= 2 shows the topology; `smp/diag: core-0 tasks
    spawned` shows the SMP scheduler path ran — not the single-core cooperative loop."""
    blob = read_serial()
    m = re.search(r"smp: (\d+) usable cores discovered", blob)
    if not m:
        fail("SMP kernel: no `smp: N usable cores discovered` trace", context_grep="smp:")
    ncores = int(m.group(1))
    if ncores < 2:
        fail(f"SMP kernel discovered only {ncores} usable core(s) — expected >= 2 "
             f"(is QEMU booting with -smp 4?)", context_grep="smp:")
    ok(f"SMP topology discovered ({ncores} usable cores)")
    if "smp/diag: core-0 tasks spawned" not in blob:
        fail("SMP kernel: BSP never reached the SMP scheduler path "
             "(`smp/diag: core-0 tasks spawned` absent)", context_grep="smp/diag")
    ok("SMP scheduler path ran on the BSP (not the cooperative loop)")


# ── phase 2: every command ─────────────────────────────────────────────────

def phase2(q):
    selected = cases.cases_for(TRACK, smp=SMP)
    total = cases.count_assertions("emulated", smp=SMP)
    _record(f"boot1: PHASE 2 — {len(selected)} commands / {total} assertions")
    for case in selected:
        run_case(q, case)


# ── phase 2b: Tab completion ───────────────────────────────────────────────

# How long a Tab press may take to complete: the completion enumerates a real
# directory, so on the usb volume it is FAT IO over xhci, not a buffer edit.
TAB_SETTLE_S = 0.6


def complete_case(q, typed, segments, expect_cmd, expects, shown=(), deadline_s=25):
    """Type `typed`, then a Tab before each further segment, then a final Tab
    and Enter — the way a user grows a path — and assert the shell RAN
    `expect_cmd`. The echo of that line IS the completion assertion: if a press
    completed to the wrong text, the command never appears on the mirror. The
    `expects` strings then prove the completed path reached the file system,
    and `shown` strings must appear anywhere on the terminal — that is where a
    candidate LISTING lands, above the re-drawn prompt rather than in any
    command's output."""
    typeable(typed + "".join(segments))
    q.type_str(typed)
    for seg in segments:
        q.key("tab")
        time.sleep(TAB_SETTLE_S)
        q.type_str(seg)
    q.key("tab")
    time.sleep(TAB_SETTLE_S)
    q.key("ret")
    deadline = time.time() + deadline_s
    last = None
    while time.time() < deadline:
        scoped = _scoped_output(expect_cmd)
        if scoped is not None:
            missing = [e for e in expects if e not in scoped]
            if not missing:
                break
            last = missing
        time.sleep(0.2)
    else:
        if last is not None:
            fail(f"completed command {expect_cmd!r} ran but did not print {last!r}",
                 context_grep="term.0 = ")
        fail(f"Tab completion did not build {expect_cmd!r} from {typed!r} + {segments!r} "
             "(the completed line was never echoed)", context_grep="term.0 = #0:")
    mirror = cases.mirror_text(read_serial(), core=0)
    for s in shown:
        if s not in mirror:
            fail(f"Tab did not SHOW its candidates: {s!r} never appeared on the terminal",
                 context_grep="term.0 = ")
    n = 1 + len(expects) + len(shown)
    global passed
    passed += n
    _record(f"boot1:   OK  Tab completion → {expect_cmd!r} ({n} assertions)")


def phase_complete(q):
    """APP-022/023/024 end to end: keystroke → completion core → live VFS → line."""
    _record("boot1: PHASE 2b — Tab completion")
    # `ls /usb`⇥`m`⇥`ra`⇥ — nine typed characters become a 28-character path,
    # one segment per press, each with exactly one matching entry (APP-022,
    # APP-023). Every entry leaned on here is asserted present by phase 2's own
    # `ls` cases, so a failure here is completion, never a missing fixture.
    complete_case(q, "ls /usb", ["m", "ra"],
                  "ls /usbdisk/models/rabbit.glb",
                  ("rabbit.glb  (",))  # ls of a FILE prints its entry
    # `Tri` matches Triangle.gltf AND TriangleWithoutIndices.gltf, so the line
    # grows to the text they share and STOPS there (APP-024) — the error names
    # the common prefix, never either whole name.
    complete_case(q, "ls /usbdisk/models/Tri", [],
                  "ls /usbdisk/models/Triangle",
                  ("ls: no such directory '/usbdisk/models/Triangle'",))
    # The FIRST word completes against the command names, not the file system
    # (APP-025) — `he`⇥ can only be `help`, and gains the space that starts an
    # argument, so what runs is the command itself.
    # `hel` not `he`: the Linux batch added `head`, so `he` is ambiguous now.
    complete_case(q, "hel", [], "help ", ("help            this list",))
    # A lower-case guess still finds capitalised names (APP-027), and a word
    # that cannot be finished SHOWS its candidates (APP-026): `box`⇥ rewrites
    # the line to the `Box` the volume spells and lists all three entries,
    # which is why the error names Box and not box.
    complete_case(q, "ls /usbdisk/models/box", [],
                  "ls /usbdisk/models/Box",
                  ("ls: no such directory '/usbdisk/models/Box'",),
                  shown=("BoxInterleaved.glb", "BoxTextured.glb"))


# ── phase 3: window commands + hotkeys + history ───────────────────────────

def phase3(q):
    _record("boot1: PHASE 3 — windows, hotkeys, history")
    base = wm()
    if base["nwins"] is None:
        fail("no wm.nwins record — is the WM state mirror compiled in (-Dtest-hooks)?")
    base_n = base["nwins"]
    base_focus = base["focus"]

    # `term`: a new terminal window opens and takes focus (single-core: core 0).
    type_cmd(q, "kudos term")
    st = wm_wait(lambda s2: s2["nwins"] == base_n + 1)
    if st["nwins"] != base_n + 1:
        fail(f"`term` did not open a window (nwins {base_n} -> {st['nwins']})")
    # APP-001/APP-002: each terminal is its own window and session with its own
    # shell — the second terminal answers on its own mirror channel.
    ok("`term` opened a window (wm.nwins +1)")
    if st["focus"] == base_focus or st["focus"] is None:
        fail(f"`term` did not move focus (still {st['focus']})")
    ok("`term` window took focus (wm.focus moved)")
    new_term_id = st["focus"][0]
    # The new terminal's OWN mirror channel: core 0 on single-core, an AP on SMP
    # (`term` opens on the lowest free core). Read its output there, not core 0.
    new_core = active_core()

    # Typing lands in the NEW focused terminal.
    type_cmd(q, "echo second-terminal-ok")
    if "second-terminal-ok" not in cases.mirror_text(read_serial(), core=new_core):
        fail("typing after `term` did not reach the new terminal")
    ok("keystrokes follow focus to the new terminal")

    # Up-arrow history — run it HERE, while this terminal provably has focus.
    type_cmd(q, "echo history-marker-7")
    # Press Up, then WAIT until the recalled text has actually been echoed onto
    # the prompt line before pressing Enter. A fixed pause raced the recall
    # under load: Enter would land on a still-empty line and commit nothing.
    # (The mirror flushes per line, so the recalled text may not be visible
    # until Enter — the poll then simply becomes this bounded wait, still far
    # safer than the 0.3 s fixed pause that raced the recall under load.)
    recalls_before = cases.mirror_text(read_serial(), core=new_core).count("history-marker-7")
    q.key("up")
    deadline = time.time() + 2
    while time.time() < deadline:
        if cases.mirror_text(read_serial(), core=new_core).count("history-marker-7") > recalls_before:
            break
        time.sleep(0.2)
    q.key("ret"); wait_quiescent()
    mirror = cases.mirror_text(read_serial(), core=new_core)
    if mirror.count("history-marker-7") < 3:  # echo output ×2 + ≥1 prompt echo
        fail(f"Up-arrow recall did not re-run the command "
             f"({mirror.count('history-marker-7')} occurrences)")
    ok("Up-arrow recalled and re-ran the last command")

    # `exit` closes it; focus returns to an older window.
    type_cmd(q, "exit")
    st = wm_wait(lambda s2: s2["nwins"] == base_n)
    if st["nwins"] != base_n:
        fail(f"`exit` did not close the window (nwins {st['nwins']} != {base_n})")
    ok("`exit` closed the focused terminal (wm.nwins back)")
    if new_term_id not in st["closed"]:
        fail(f"no wm.closed record for window {new_term_id}")
    ok("wm.closed emitted for the exited terminal")
    if st["focus"] is None or st["focus"][0] == new_term_id:
        fail(f"focus did not return after exit (focus={st['focus']})")
    ok("focus returned to a surviving window")

    # The on-screen diagnostics console is gone (netdebug supersedes it) —
    # its old F11 binding is intentionally unbound.
    n_before = wm()["nwins"]

    # F10 opens the dedicated AI agent window from anywhere; /quit closes it. The
    # window is a terminal in ai_mode (prompt `ai>`), so its committed line runs
    # the agent's `/quit` slash command rather than a shell command.
    q.key("f10"); wait_quiescent()
    st = wm_wait(lambda s2: s2["nwins"] == n_before + 1)
    if st["nwins"] != n_before + 1 or cases.win_by_title(st, "AI Agent") is None:
        fail(f"F10 did not open the AI agent window (nwins {n_before} -> {st['nwins']})")
    ok("F10 opened the AI agent window")
    type_cmd(q, "/quit")
    if wm_wait(lambda s2: s2["nwins"] == n_before)["nwins"] != n_before:
        fail("/quit did not close the AI agent window")
    ok("AI agent window closed via /quit")

    # F12 opens a terminal from anywhere; exit closes it again.
    q.key("f12"); wait_quiescent()
    st = wm_wait(lambda s2: s2["nwins"] == n_before + 1)
    if st["nwins"] != n_before + 1:
    # DSK-020: a global shortcut opens a terminal regardless of what holds
    # focus — pressed here while the agent window is focused.
        fail(f"F12 did not open a terminal (nwins {n_before} -> {st['nwins']})")
    ok("F12 opened a new terminal")
    type_cmd(q, "exit")
    if wm_wait(lambda s2: s2["nwins"] == n_before)["nwins"] != n_before:
        fail("exit after F12 did not close the terminal")
    ok("F12 terminal closed via `exit`")

    # `system` LAST — after the F12-terminal exit, focus falls to the topmost
    # remaining window; the system window has no shell, so every later phase-3
    # typed test would silently type into the void. It opens here, is asserted,
    # and PHASE 4 (the mouse phase) uses it as its guinea pig and closes it.
    sys_core = type_cmd(q, "kudos system")  # typed at the terminal that had focus
    st = wm_wait(lambda s2: cases.win_by_title(s2, "system") is not None)
    if cases.win_by_title(st, "system") is None:
        fail(f"`system` did not open (nwins={st['nwins']}, wins={st['wins']})")
    # APP-020: the system monitor application opens on demand.
    ok("`system` opened the system monitor (wm.win t=system)")
    mirror = cases.mirror_text(read_serial(), core=sys_core)
    if "opened the system monitor" not in mirror:
        fail("`system` did not confirm in the terminal")
    ok("`system` confirmed in the terminal output")


# ── phase SMP: cross-core terminal on an Application Processor ──────────────

def phase_smp(q):
    """SMP only: prove a keystroke reaches a terminal PINNED TO AN APPLICATION
    PROCESSOR, and that terminal's output mirrors back from that core's own channel.

    `term` opens a session on the lowest free core — core 1, an AP, since only the
    boot terminal (core 0) is up — titled `term #1` (desktop.zig spawnApp). It takes
    focus, so injected keys land there; readback is core 1's mirror (`dbg: term.1`),
    and the prompt renders `#1:<cwd>>` (terminal.zig prompt), naming the core.

    Opens and CLOSES the AP terminal so the window set is unchanged for the mouse
    phases that follow."""
    _record("boot1: PHASE SMP — cross-core terminal on an Application Processor")
    base_n = wm()["nwins"]

    type_cmd(q, "kudos term")  # typed at terminal #0 (core 0) — type_cmd's core-0 echo holds
    st = wm_wait(lambda s2: s2["nwins"] == base_n + 1)
    if st["nwins"] != base_n + 1:
        fail(f"`term` did not open a window on SMP (nwins {base_n} -> {st['nwins']})")
    found = cases.win_by_title(st, "term #1")
    if found is None:
        fail(f"no `term #1` window — did the terminal land on an AP? wins={st['wins']}")
    ap_id = found[0]
    ok("`term` opened a terminal pinned to core 1 (an AP)")
    if st["focus"] is None or st["focus"][0] != ap_id:
        fail(f"the core-1 terminal did not take focus (focus={st['focus']})")
    ok("focus moved to the core-1 terminal")

    # Type into it and read back from CORE 1's channel (not core 0). Retype once on a
    # missing echo — the same lossy-input rationale as type_cmd, verified on term.1.
    marker = "cross-core-marker"
    for attempt in (1, 2):
        q.type_str(f"echo {marker}")
        q.key("ret")
        wait_quiescent()
        if f"$ echo {marker}" in cases.mirror_text(read_serial(), core=1):
            break
        if attempt == 1:
            _record("boot1:   (no echo on term.1 — retyping once; lossy input path)")
    mirror1 = cases.mirror_text(read_serial(), core=1)
    if "#1:" not in mirror1:
        fail("core-1 terminal never showed its own `#1:<cwd>>` prompt",
             context_grep="term.1 = ")
    ok("core-1 terminal runs its own core-tagged shell prompt (#1:)")
    # Two occurrences on term.1: the command echo + the command's own output. This is
    # the end-to-end proof — the keystroke crossed to core 1 AND its shell executed.
    if mirror1.count(marker) < 2:
        fail(f"`echo {marker}` did not run on core 1 "
             f"({mirror1.count(marker)} occurrences on term.1)", context_grep="term.1 = ")
    ok("keystrokes routed to core 1 and its shell ran the command (term.1)")

    # APP-031: the two terminals run their commands AT THE SAME TIME.
    #
    # The proof is a clock, because that is what the defect stole: with one
    # command worker serving every terminal, a long command in this window left
    # every other window's committed line unrun until it finished — the machine
    # looked hung and said nothing. So: start a long `sleep` here (this terminal
    # is now busy for SLEEP_S), move focus back to the boot terminal, and time
    # how long ITS `echo` takes to answer. Serialized, the echo could not appear
    # before the sleep ended; concurrent, it lands in well under a second.
    SLEEP_S = 10
    BUDGET_S = SLEEP_S / 2  # generous: the echo path is milliseconds
    q.type_str(f"sleep {SLEEP_S}")
    q.key("ret")
    time.sleep(0.5)  # let the line commit and this terminal's worker take it
    started = time.monotonic()

    # A SECOND terminal, opened while the first is busy: F12 is the hotkey the
    # system task serves, so it works whatever a terminal is doing, and the new
    # window takes focus — which is what puts the next keystrokes in it.
    n_busy = wm()["nwins"]
    q.key("f12")
    st = wm_wait(lambda s2: s2["nwins"] == n_busy + 1)
    if st["nwins"] != n_busy + 1:
        fail(f"F12 opened no terminal while another was busy (nwins {n_busy} -> {st['nwins']})")
    busy_peer_id = st["focus"][0] if st["focus"] else None
    peer_core = active_core()

    concurrent = "concurrent-ok"
    q.type_str(f"echo {concurrent}")
    q.key("ret")
    while time.monotonic() < started + BUDGET_S:
        if concurrent in cases.mirror_text(read_serial(), core=peer_core):
            break
        time.sleep(0.2)
    elapsed = time.monotonic() - started
    if concurrent not in cases.mirror_text(read_serial(), core=peer_core):
        fail(f"the second terminal did not run `echo` within {BUDGET_S:.0f}s while the "
             f"first slept — the terminals are serialized on one command worker (APP-031)",
             context_grep=f"term.{peer_core} = ")
    ok(f"a busy terminal does not hold up another one ({elapsed:.1f}s < {SLEEP_S}s sleep, APP-031)")

    # Close the second terminal, then wait the sleep out so the AP terminal is
    # settled before it is asked to exit (its worker must be idle first).
    q.type_str("exit")
    q.key("ret")
    if busy_peer_id is not None:
        wm_wait(lambda s2: busy_peer_id in s2["closed"])
    time.sleep(max(0.0, SLEEP_S - (time.monotonic() - started)) + 0.5)
    wait_quiescent()
    if cases.win_by_title(wm(), "term #1") is None:
        fail("the sleeping terminal did not survive its neighbour's open/close")

    # Close the AP terminal (it holds focus): the window set returns to the boot
    # layout, so phase 3 starts from a clean term #0-focused state. `exit` mirrors
    # on term.1.
    q.type_str("exit")
    q.key("ret")
    wait_quiescent(idle_s=0.6, timeout_s=10)
    st = wm_wait(lambda s2: ap_id in s2["closed"])
    if ap_id not in st["closed"] or cases.win_by_title(st, "term #1") is not None:
        fail(f"`exit` did not close the core-1 terminal (closed={st['closed']})")
    ok("core-1 terminal closed cleanly (window set restored for the mouse phases)")


# ── phase 4: mouse-driven WM behaviours ────────────────────────────────────

class Pointer:
    """Closed-loop relative-pointer driver. Pointer ACCELERATION makes deltas
    non-1:1, so aim is verified on every click via the wm.ptr record (emitted on
    each button transition) and corrected until the press lands in the intended
    rectangle. Position belief is re-anchored on every verified click."""

    CHUNK = 32     # px per QMP event: fixed size + pacing = stable accel factor
    PACE_S = 0.03

    def __init__(self, q):
        self.q = q
        self.x = 0
        self.y = 0
        self.scale = 1.0
        self.pin()

    def pin(self):
        for _ in range(3):
            self.q.move(-4000, -4000)
            time.sleep(0.05)
        # QEMU ACCUMULATES queued relative motion per axis and drains it to the
        # guest at the HID report rate (~127px per report): the ~12000px pin
        # overshoot is still draining when the caller queues its next burst,
        # and that burst is arithmetically absorbed into the leftover negative
        # backlog — the cursor never moves and calibration reads "motion dead".
        # Wait for the backlog to finish: the probed position must hold (0,0)
        # on two successive reads.
        stable = 0
        for _ in range(40):
            if self.probe() == (0, 0):
                stable += 1
                if stable >= 2:
                    break
            else:
                stable = 0
            time.sleep(0.25)
        else:
            fail("pointer pin: motion backlog never drained to (0,0)")
        self.x, self.y = 0, 0

    def _burst(self, dx, dy):
        """Issue one relative move in fixed-size chunks (constant speed)."""
        steps = max(1, (max(abs(dx), abs(dy)) + self.CHUNK - 1) // self.CHUNK)
        for i in range(steps):
            sx = dx * (i + 1) // steps - dx * i // steps
            sy = dy * (i + 1) // steps - dy * i // steps
            self.q.move(sx, sy)
            time.sleep(self.PACE_S)

    def probe(self):
        """Right-click (harmless: no window action binds button 2) to learn the
        REAL cursor position from the wm.ptr record, and re-anchor belief."""
        self.q.button("right", True); time.sleep(0.15)
        self.q.button("right", False); time.sleep(0.25)
        wait_quiescent(idle_s=0.3, timeout_s=5)
        st = wm()
        if st["ptr"] is None:
            fail("no wm.ptr record after a probe click — pointer hook missing?")
        self.x, self.y = st["ptr"][0], st["ptr"][1]
        return self.x, self.y

    def calibrate(self):
        self.pin()
        self._burst(200, 200)
        ax, ay = self.probe()
        moved = (ax + ay) / 2.0
        if moved < 20:
            fail(f"pointer calibration moved only to ({ax},{ay}) — motion dead?")
        self.scale = moved / 200.0
        _record(f"boot1:   pointer calibrated: accel scale ~{self.scale:.2f}")

    def screen(self):
        """(w, h) of the real framebuffer, from the kernel's own `fb: tag WxH` record.

        THE TRACKS HAVE DIFFERENT SCREENS. QEMU's emulated VGA is taller than lemon's
        GRUB framebuffer (1024x768), so a phase target computed for the emulator can land
        BELOW the bottom of the real panel — the suite asked the pointer to reach y=989 on
        a 768-high screen and then failed it for "never converging" on a point that does
        not exist. Clamp to what the machine actually has.
        """
        blob = read_serial()
        # THE GPU RESIZES THE SCREEN OUT FROM UNDER US. `fb: tag WxH` is the GRUB
        # framebuffer the kernel booted on (1024x768 on lemon); once GSP brings the 4090
        # up, the desktop is composited at the MONITOR's real mode (3440x1440) and every
        # coordinate the harness computes against the old size is wrong — the maximise box
        # moves off to the right and the click that should restore the window misses it
        # entirely. Prefer the compositor's own answer; fall back to the boot tag.
        m = re.search(r"desktop . primary monitor (\d+)x(\d+)", blob) or \
            re.search(r"fb: tag (\d+)x(\d+)", blob)
        return (int(m.group(1)), int(m.group(2))) if m else (1024, 768)

    def goto(self, tx, ty, tol=8):
        """Move until the probed position is within tol (target clamped to the screen).

        The acceleration factor
        depends on burst length (short corrective bursts never reach the speed a
        long calibration burst does), so the scale is RE-MEASURED from every
        burst's actual-vs-commanded motion and adapted — dead reckoning with a
        fixed factor stalls at ~75% of the way and never lands."""
        sw, sh = self.screen()
        tx = max(0, min(sw - 1, tx))
        ty = max(0, min(sh - 1, ty))
        for _ in range(12):
            dx, dy = tx - self.x, ty - self.y
            if abs(dx) <= tol and abs(dy) <= tol:
                return
            cmd_x = int(dx / self.scale) or (1 if dx > 0 else -1)
            cmd_y = int(dy / self.scale) or (1 if dy > 0 else -1)
            bx, by = self.x, self.y
            self._burst(cmd_x, cmd_y)
            self.probe()
            commanded = (cmd_x * cmd_x + cmd_y * cmd_y) ** 0.5
            actual = ((self.x - bx) ** 2 + (self.y - by) ** 2) ** 0.5
            if commanded > 0 and actual / commanded > 0.05:
                measured = actual / commanded
                self.scale = min(8.0, max(0.2, 0.5 * self.scale + 0.5 * measured))
        fail(f"pointer never converged on ({tx},{ty}) (at {self.x},{self.y}, scale {self.scale:.2f})")

    def press(self):
        self.q.button("left", True)
        time.sleep(0.2)
        wait_quiescent(idle_s=0.3, timeout_s=5)
        st = wm()
        if st["ptr"] is None or st["ptr"][2] & 1 == 0:
            fail("left press produced no wm.ptr record")
        self.x, self.y = st["ptr"][0], st["ptr"][1]

    def release(self):
        self.q.button("left", False)
        time.sleep(0.2)
        wait_quiescent(idle_s=0.3, timeout_s=8)
        st = wm()
        if st["ptr"] is not None:
            self.x, self.y = st["ptr"][0], st["ptr"][1]

    def click(self, tx, ty):
        self.goto(tx, ty)
        self.press()
        landed = (self.x, self.y)
        self.release()
        return landed

    def drag(self, fx, fy, dx, dy, win_id=None, tol=12):
        """Press at (fx,fy) and drag by (dx,dy). With win_id given the drag is
        CLOSED-LOOP: mid-drag there are no button edges for wm.ptr probes, but
        the dragged window's own wm.win records update live — exact ground truth
        for how far the pointer really moved, so acceleration error is corrected
        while the button is still held."""
        self.goto(fx, fy)
        st = wm()
        start = st["wins"].get(win_id) if win_id is not None else None
        self.press()
        if start is None:
            self._burst_held(int(dx / self.scale), int(dy / self.scale))
        else:
            tx, ty = start["x"] + dx, start["y"] + dy
            for _ in range(10):
                g = wm()["wins"].get(win_id)
                if g is None:
                    break
                rx, ry = tx - g["x"], ty - g["y"]
                if abs(rx) <= tol and abs(ry) <= tol:
                    break
                bx, by = g["x"], g["y"]
                self._burst_held(int(rx / self.scale) or (1 if rx > 0 else -1),
                                 int(ry / self.scale) or (1 if ry > 0 else -1))
                wait_quiescent(idle_s=0.3, timeout_s=5)
                g2 = wm()["wins"].get(win_id)
                if g2 is not None:
                    moved = ((g2["x"] - bx) ** 2 + (g2["y"] - by) ** 2) ** 0.5
                    commanded = max(1.0, (rx * rx + ry * ry) ** 0.5 / self.scale)
                    if moved / commanded > 0.05:
                        self.scale = min(8.0, max(0.2, 0.5 * self.scale + 0.5 * moved / commanded))
        self.release()

    def _burst_held(self, dx, dy):
        """One relative move in fixed chunks with the LEFT button held (QMP
        button state persists across motion events)."""
        self._burst(dx, dy)


def phase4(q):
    _record("boot1: PHASE 4 — mouse-driven window management")
    p = Pointer(q)
    p.calibrate()

    st = wm()
    # The boot layout: the glass terminal. The system window from phase 3 is
    # also up. Use the system window as the guinea pig (fixed 640×460, safely
    # smaller than the screen).
    found = cases.win_by_title(st, "system")
    if found is None:
        fail("system window missing at phase 4 start")
    sys_id, sys_g = found
    term_found = cases.win_by_title(st, "term #0")
    if term_found is None:
        fail("boot terminal missing at phase 4 start")
    term_id, term_g = term_found

    # The system window opened LAST (phase 3), so it starts TOPMOST — but it is
    # small enough that the boot terminal fully covers it once the terminal is
    # raised. Sequence matters: (1) focus the system window while it is still on
    # top, (2) DRAG it below the terminal into clear desktop, (3) then click-to-
    # focus can be tested both ways on non-overlapping bodies.
    p.click(*cases.title_center(sys_g))
    if wm()["focus"][0] != sys_id:
        fail(f"clicking the system title did not focus it (focus={wm()['focus']})")
    ok("click-to-focus: system title click focused it (topmost)")

    # Title-bar drag: move it below the terminal (terminal bottom is ~y=820 on
    # the 2560x1440 emulated panel; the drag target keeps the window + later
    # grip-resize growth on-screen).
    # Drag it clear of the terminal, but KEEP IT FULLY ON SCREEN — the grip-resize case
    # below has to reach this window's bottom-right corner. A fixed +700 fits QEMU's
    # 1024-high screen and shoves the window off the bottom of lemon's 768-high GRUB
    # framebuffer, leaving the grip unreachable and the resize "failing" on a window
    # manager that was working perfectly. The screen is not a constant; ask for it.
    _sh = p.screen()[1]
    # No floor: a floor would push the window's bottom-right GRIP off a short screen (it
    # did — the grip sat at y=832 on a 768-high panel and the resize case could not reach
    # it). Move as far as the screen allows and no further.
    _dy = max(0, min(700, _sh - (sys_g["y"] + sys_g["h"]) - 8))
    p.drag(*cases.title_center(sys_g), 150, _dy, win_id=sys_id)
    g2 = wm()["wins"].get(sys_id)
    # Assert the window reached what was COMMANDED (+150, +_dy), not a fixed floor:
    # _dy is capped by screen height and on lemon's 768-high native framebuffer it is
    # exactly 100, so a hardcoded ">100" check tripped on a drag that landed perfectly.
    # The closed-loop drag converges within its tolerance, so allow a small shortfall.
    if g2 is None or g2["x"] - sys_g["x"] < 110 or g2["y"] - sys_g["y"] < _dy - 40:
    # DSK-011: windows are moved by dragging their title bar — closed loop,
    # the window's own geometry must follow the commanded vector.
        fail(f"title drag did not reach the commanded +150,+{_dy} ({sys_g} -> {g2})")
    ok(f"title-bar drag moved the window (+{g2['x']-sys_g['x']},+{g2['y']-sys_g['y']})")
    sys_g = g2
    # DISJOINT WINDOWS NEED A SCREEN BIG ENOUGH TO HOLD TWO. QEMU's is; lemon's GRUB
    # framebuffer (1024x768) is not — two 640x460 windows cannot be pulled apart in
    # either axis there (2*460 > 768, 2*640 > 1024). That is a property of the panel, not
    # a window-manager bug, so the cases that REQUIRE separation are skipped on a small
    # screen and SAID SO. Skipping loudly is honest; failing here would blame the WM for
    # the size of the monitor, and passing silently would hide a real regression later.
    _sw, _sh = p.screen()
    disjoint_possible = _sh >= 2 * sys_g["h"] + 40 or _sw >= 2 * sys_g["w"] + 40
    if not disjoint_possible:
        _record(f"boot1:   SKIP disjoint-window cases — screen {_sw}x{_sh} too small "
                f"to separate two {sys_g['w']}x{sys_g['h']} windows")
    elif sys_g["y"] <= term_g["y"] + term_g["h"]:
        fail(f"drag did not clear the terminal (system at y={sys_g['y']})")

    # Click-to-focus both ways. Needs the two windows PULLED APART: clicking a point
    # that both windows cover proves nothing about which one the click reached. Only
    # meaningful on a screen that can separate them (see above).
    if disjoint_possible:
        tx = term_g["x"] + term_g["w"] - 120
        ty = term_g["y"] + term_g["h"] - 120
        p.click(tx, ty)
        if wm()["focus"][0] != term_id:
    # DSK-015: clicking a window focuses and raises it.
            fail(f"clicking the terminal body did not focus it (focus={wm()['focus']})")
        ok("click-to-focus: terminal body click focused it")
        p.click(*cases.body_center(sys_g))
        if wm()["focus"][0] != sys_id:
            fail(f"clicking the system body did not focus it (focus={wm()['focus']})")
        ok("click-to-focus: system body click focused it")

    # Maximise box: fills the screen; second click restores EXACT geometry.
    p.click(*cases.max_box_center(sys_g))
    g3 = wm()["wins"].get(sys_id)
    if g3 is None or not g3["max"]:
        fail(f"maximise box click did not maximise ({g3})")
    ok(f"maximise box maximised the window ({g3['w']}x{g3['h']} max=1)")
    if not (g3["w"] > sys_g["w"] and g3["h"] > sys_g["h"] and g3["x"] == 0 and g3["y"] == 0):
        fail(f"maximised geometry wrong: {g3}")
    ok("maximised window fills from the origin")
    p.click(*cases.max_box_center(g3))
    g4 = wm()["wins"].get(sys_id)
    if g4 is None or g4["max"] or (g4["x"], g4["y"], g4["w"], g4["h"]) != (sys_g["x"], sys_g["y"], sys_g["w"], sys_g["h"]):
    # DSK-013: maximise fills the screen and restore returns the EXACT prior
    # geometry — both halves, or the window drifts on every zoom cycle.
        fail(f"restore did not return the exact geometry ({sys_g} -> {g4})")
    ok("second maximise click restored the exact pre-max geometry")

    # Grip resize: drag the bottom-right grip; the window grows by ~the vector.
    #
    # First make ROOM to grow. The window is wherever the drag case left it, and on a
    # small screen (lemon's 1024x768) its bottom-right corner can already be against the
    # edge — the resize then clamps after a few pixels and looks like a broken window
    # manager (measured: 640x460 -> 702x468, growth cut short by the panel, not by a bug).
    # Park it near the origin so the grip has somewhere to go on ANY screen.
    if g4["x"] > 60 or g4["y"] > 60:
        p.drag(*cases.title_center(g4), 40 - g4["x"], 40 - g4["y"], win_id=sys_id)
        g4 = wm()["wins"].get(sys_id) or g4
    p.drag(*cases.grip_center(g4), 90, 70)
    st = wm_wait(lambda s2: (lambda g: g is not None and g["w"] > g4["w"] + 40 and g["h"] > g4["h"] + 30)(s2["wins"].get(sys_id)))
    g5 = st["wins"].get(sys_id)
    if g5 is None or g5["w"] <= g4["w"] + 40 or g5["h"] <= g4["h"] + 30:
    # DSK-012: windows are resized from a corner grip.
        fail(f"grip resize did not grow the window ({g4} -> {g5})")
    ok(f"grip resize grew the window (+{g5['w']-g4['w']},+{g5['h']-g4['h']})")

    # Close box: the window closes (wm.closed + count back down).
    n_before = wm()["nwins"]
    p.click(*cases.close_box_center(g5))
    st = wm_wait(lambda s2: sys_id in s2["closed"])
    if st["nwins"] != n_before - 1 or sys_id not in st["closed"]:
        fail(f"close box did not close the window (nwins {n_before} -> {st['nwins']})")
    ok("close box closed the window (wm.closed emitted)")


# ── phase 5: close recovery ────────────────────────────────────────────────

def phase5(q):
    """Last-terminal close + F12 recovery — the REAL contract (desktop.zig
    tick(): there is NO automatic recovery terminal; F12 is the recovery path)."""
    _record("boot1: PHASE 5 — last-terminal close + F12 recovery")
    st = wm()
    found = cases.win_by_title(st, "term #0")
    if found is None:
        fail("boot terminal missing at phase 5 start")
    term_id = found[0]
    # Focus the boot terminal, close it.
    p = Pointer(q)
    p.calibrate()
    p.click(*cases.body_center(found[1]))
    if wm()["focus"][0] != term_id:
        fail(f"could not focus the boot terminal (focus={wm()['focus']})")
    type_cmd(q, "exit")
    wait_quiescent(idle_s=0.6, timeout_s=10)
    st = wm_wait(lambda s2: term_id in s2["closed"])
    if term_id not in st["closed"] or cases.win_by_title(st, "term #0") is not None:
        fail(f"exit did not close the last terminal (closed={st['closed']})")
    ok("the last terminal closed (no terminals remain)")

    # F12 — the documented recovery path — opens a fresh terminal from anywhere.
    greetings_before = read_serial().count(TERM_GREETING)
    q.key("f12")
    wait_quiescent(idle_s=0.6, timeout_s=10)
    if read_serial().count(TERM_GREETING) != greetings_before + 1:
        fail("F12 did not open a recovery terminal after the last one closed")
    ok("F12 opened a recovery terminal")
    rec_core = type_cmd(q, "echo recovered-ok")
    if "recovered-ok" not in cases.mirror_text(read_serial(), core=rec_core):
        fail("the recovery terminal did not accept a command")
    ok("the recovery terminal accepts commands")


def main():
    try:
        open(RESULT_LOG, "w").close()
    except OSError:
        pass
    q = qmp.QMP(qmp.SOCK)
    global g_qmp
    g_qmp = q  # fail() dumps vcpu registers through this one shared connection
    phase1(q)
    phase2(q)
    # Completion runs while the boot terminal still has focus and phase 2 has
    # just restored the cwd to /ramdisk — its cases type absolute paths, so the
    # cwd only has to be a real directory.
    phase_complete(q)
    # SMP cross-core phase runs HERE — right after phase 2, while the boot terminal
    # (term #0, core 0) still has focus. Phase 3 ends with the shell-less `system`
    # window focused, so `term` typed there would go nowhere. phase_smp opens and
    # closes its own AP terminal, leaving term #0 focused again for phase 3.
    if SMP:
        phase_smp(q)
    phase3(q)
    phase4(q)
    phase5(q)
    _record(f"boot1: PASS — {passed} assertions green")


if __name__ == "__main__":
    main()
