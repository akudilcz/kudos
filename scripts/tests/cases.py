"""The kudos integration-test case table — the single source of truth for what
commands the suite types and what each must print.

A case is `Case(cmd, expects, track)`:
  cmd      the exact line typed at a `#<core>>` shell prompt
  expects  a TUPLE of substrings that must ALL appear in that command's mirrored
           output — each substring is one assertion (one test). Output reaches
           the harness via the terminal-output mirror (`dbg: term.<core> = …`,
           a -Dtest-hooks build; see src/apps/terminal.zig `putChar`). Keep
           each substring short enough to land inside one <=VAL_CAP (72 B)
           chunk — longer grid lines wrap into `term.<core>+` continuations,
           which mirror_text() re-joins, so up to ~140 B is still safe.
  track    which boot the case runs on:
             "emulated"     — headless VGA boot, no GPU (run_emulated.sh)
             "passthrough"  — real 4090 boot, GPU/desktop (run_passthrough.sh)
             "both"         — runs on both
             "smp"          — SMP-kernel boots ONLY, any machine. Orthogonal to
                              the machine axis above: these run IN ADDITION to the
                              emulated/passthrough cases whenever the boot is the
                              multi-core kernel (cases_for(..., smp=True)), and
                              never on the single-core kernel.

Adding a regression case is one Case(...) line; adding an assertion to an
existing case is one string in its tuple. Both drivers import CASES and the
parsing/assertion helpers below, so the two tracks stay in lockstep.

Every expected string below was verified against the shell/localcmd source
(src/console/shell.zig, localcmd.zig) or a live run — do not guess new ones.

Rules encoded here:
  - Destructive commands (reboot/shutdown/exit) are NOT in CASES — the drivers
    run them last as an explicit phase (exit → close-recovery behavior).
  - Window-opening commands run on BOTH tracks (the window + WM records exist
    without a GPU; only the rendered pixels need the 4090) — pixel-level and
    present-timing assertions stay passthrough-only.
  - `net` beyond argument-validation is emulated-loose/passthrough-real: the
    QEMU user NIC answers DHCP so `net ip` reports up, but DNS/ping reach the
    outside world, so only their usage lines are asserted unconditionally.
"""

from collections import namedtuple

Case = namedtuple("Case", ["cmd", "expects", "track"])

CASES = [
    # ── help: the list itself documents every command — assert each entry ──
    Case("help", (
        "help            this list",
        "clear           clear the screen",
        "echo TEXT       print TEXT",
        "cd [PATH]",
        "ls [PATH]",
        "cat PATH        print a file",
        "lspci           list pci devices",
        "net SUBCOMMAND  network: ip | dns NAME | ping HOST | fetch URL [NAME]",
        "mem             free / total RAM",
        "ps              list cores",
        "prime N         load THIS core",
        "rt N            real-time task on THIS core",
        "term            open a new terminal app",
        "system          open the system monitor app",
        "show PATH [max] open a spinning 3D model window",
        "ai [PROMPT]     talk to the AI agent",
        "F12             open a new terminal",
        "flipstat        re-arm the present-cadence sample",
        "exit            close this terminal window",
        "reboot          restart the machine",
    ), "both"),

    # ── echo ────────────────────────────────────────────────────────────
    Case("echo integration-ok", ("integration-ok",), "both"),
    Case("echo a-b_c=1,2", ("a-b_c=1,2",), "both"),  # shifted/symbol typing path

    # ── memory ──────────────────────────────────────────────────────────
    Case("mem", ("free ", "MiB / ", "MiB total"), "both"),

    # ── PCI: assert the emulated devices BY ID (vendor:device + class) ──
    Case("lspci", (
        "8086:100e",   # e1000 NIC
        "class 02.00", # …is a network controller
        "1b36:000d",   # qemu-xhci USB3 controller
        "class 0c.03", # …is a USB controller
        "1234:1111",   # stdvga
        "class 03.00", # …is a display controller
    ), "emulated"),
    Case("lspci", (":",), "passthrough"),  # real HW: presence only (IDs differ)

    # APP-003: the shell navigates and reads the file system — listings,
    # content and errors, across both mounted volumes.
    # ── VFS + ramdisk: listings, content, errors ────────────────────────
    # STO-002: one namespace over every mounted store — both volumes must
    # appear under the same root, and files read through it from each.
    Case("ls /", ("ramdisk/", "usbdisk/"), "both"),
    Case("ls /ramdisk", (
        "welcome.txt", "motd.txt",
        "teapot.glb  (456024 bytes)",  # exact size: the seed embedded whole
        "duck.glb  (120484 bytes)",
    ), "both"),
    Case("ls", ("teapot.glb",), "both"),  # bare ls = the cwd (/ramdisk)
    Case("cat /ramdisk/motd.txt", ("everything in RAM", "the kudos way"), "both"),
    Case("cat welcome.txt", (  # relative path resolution against the cwd
        "welcome to kudos",
        "grub multiboot2",
        "/ramdisk lives in RAM",
        "F12 opens a terminal, F10 the AI agent",
    ), "both"),
    Case("cat", ("usage: cat PATH",), "both"),
    Case("cat /ramdisk/nope.txt", ("error: no such file '/ramdisk/nope.txt'",), "both"),
    Case("ls /nope", ("error: no such directory '/nope'",), "both"),
    Case("ls /ramdisk/motd.txt", ("error: not a directory",), "both"),
    Case("cd /nope", ("error: no such directory '/nope'",), "both"),
    Case("cd /ramdisk/motd.txt", ("' is a file",), "both"),

    # ── USB disk really works: mount + listings + CONTENT + relative cd ──
    Case("ls /usbdisk", ("hello.txt  (36 bytes)", "models/", "scenes/"), "both"),
    Case("cat /usbdisk/hello.txt", ("hello from the real kudos usb stick",), "both"),
    Case("ls /usbdisk/models", ("rabbit.glb",), "both"),
    # DSK-003: the desktop background is chosen from a PNG on the USB stick. The
    # success line prints only after the path resolved ON /usbdisk and the bytes
    # decoded as a PNG — the error arms above it print instead when either fails.
    # Proven on boot-1 (emulated): "OK 'background /usbdisk/pic.png'".
    Case("background /usbdisk/pic.png", ("background: /usbdisk/pic.png",), "both"),

    Case("cd /usbdisk", (), "both"),
    Case("cd", ("/usbdisk",), "both"),        # no-arg cd prints cwd → proves it
    Case("cd models", (), "both"),            # RELATIVE cd on the usb volume
    Case("cd", ("/usbdisk/models",), "both"),
    Case("cd /ramdisk", (), "both"),          # restore for later relative cases

    # ── scheduler/system info ────────────────────────────────────────────
    # The loaded-module command is dispatched by the shell, and says why it
    # cannot run something rather than failing quietly. This proves DISPATCH
    # only — not that a real module executes, which needs a .kudos staged where
    # a live shell can reach it — so the requirement for running one stays on
    # the reqtrace ratchet, deliberately uncited. (Naming its ID here would
    # read as a citation to the trace gate, which cannot tell a discussion of
    # a requirement from a claim to verify it.)
    Case("run", ("usage: run",), "both"),
    Case("run no-such-app", ("run: ",), "both"),
    # AGT-009: an agent-generated app (AGT-008) that faults is contained to its own
    # session. `run crashy` executes a REAL .kudos module staged on the stick and
    # faults inside it; the very next command proves this session still answers —
    # containment is the shell surviving its own app, not a message about it.
    Case("run crashy", (), "both"),
    Case("echo alive-after-crash", ("alive-after-crash",), "both"),

    # APP-005: the shell exposes the event counters too, not only tasks/memory/
    # PCI — `stats PREFIX` filters the same registry KMR1's OP_STATS dumps, and
    # is the view for a machine with no collector attached. A prefix that
    # matches nothing must say so rather than printing an empty success.
    Case("stats net.", ("net.", " = "), "both"),
    Case("stats zz.nothing", ("no matching counters",), "both"),

    # DIAG-001: the system reports its own health and state — mem and ps
    # must answer with real numbers on every track.
    Case("ps", ("CORE", "ROLE", "CPU%", "TASKS"), "both"),
    # SMP kernel only: `ps` walks every online core (cmdPs, shell.zig) — core 0 is
    # the "system" process, each AP hosts a pinned "terminal". Proof the APs came
    # online AND host their own terminals. The single-core kernel prints a
    # "(single-core: cooperative loop)" sentinel and NEVER a #1 row, so this case
    # cannot pass there — its own built-in mutation check.
    Case("ps", ("#0", "system", "#1", "terminal"), "smp"),

    # ── network ──────────────────────────────────────────────────────────
    # APP-004: the shell ships network diagnostics — ip / dns / ping / fetch.
    Case("net ip", ("network:",), "both"),          # up (slirp/tap) or loud DOWN
    Case("net bogus", ("net: unknown subcommand 'bogus'",), "both"),
    Case("net dns", ("usage: net dns NAME",), "both"),
    Case("net ping", ("usage: net ping HOST",), "both"),

    # ── local commands: CPU load + real-time (usage + real run) ─────────
    Case("prime 5000", (
        "prime: searching this core for a prime >= 5000",
        "prime: found",
        "primes scanned",
    ), "both"),
    Case("prime", ("usage: prime N",), "both"),
    Case("prime abc", ("usage: prime N",), "both"),
    Case("rt 5", (
        "rt: 10 Hz, 5 periods",
        "rt: jitter min/mean/max",
        "ns; drift = ",
        "us over 5 periods",
    ), "both"),
    Case("rt", ("usage: rt N",), "both"),

    # ── show: argument validation everywhere; window-opening on both ────
    Case("show", ("usage: show PATH [max]",), "both"),
    Case("show motd.txt", ("is not a .glb model",), "both"),
    Case("show nope.glb", ("not found in the cwd, /ramdisk, or /usbdisk",), "both"),

    # ── flipstat: loud error when there is nothing to measure ───────────
    # Two distinct reasons it cannot sample, and the shell names the one that is
    # actually true. Boot 1 is emulated: there is no GPU at all, so no present path
    # ever published the re-arm hook — and saying "rebuild with -Dflip-sample" there
    # would be a lie, because that build would not help either. (Boot 2 has the real
    # 4090 and builds WITH -Dflip-sample; the driver re-arms for its 60 Hz test.)
    Case("flipstat", ("error: no GPU present path is running",), "emulated"),

    # ── unknown command ─────────────────────────────────────────────────
    Case("definitelynotacommand",
         ("error: unknown command 'definitelynotacommand' (try 'help')",), "both"),
]

# Destructive / session-mutating — never in CASES. Drivers run these as explicit
# final phases (e.g. exit → the close+recovery behavior; reboot ends the boot).
DESTRUCTIVE = ("exit", "shutdown", "reboot")


def cases_for(track, smp=False):
    """The cases that run on `track`, in order.

    Tracks: "emulated" (QEMU), "passthrough" (real 4090 under QEMU), "native" (lemon's
    bare metal). "native" takes the REAL-HARDWARE variants — the same ones passthrough
    uses — because the thing that differs is the silicon, not the hypervisor: `lspci` on
    lemon prints an I226-V (8086:125c), not QEMU's e1000 (8086:100e), so asserting the
    emulator's PCI IDs there would be testing the emulator.

    `smp` is the orthogonal kernel axis: when the boot is the multi-core kernel, the
    "smp"-track cases run IN ADDITION to the machine's cases. They never run on the
    single-core kernel (where they cannot pass).
    """
    hw = "passthrough" if track == "native" else track
    sel = [c for c in CASES if c.track == hw or c.track == "both"]
    if smp:
        sel += [c for c in CASES if c.track == "smp"]
    return sel


def count_assertions(track, smp=False):
    """How many individual assertions the track carries (for reporting)."""
    return sum(len(c.expects) for c in cases_for(track, smp))


# ── mirror-record parsing (shared by both drivers) ────────────────────────
#
# A mirror line on either capture channel looks like one of:
#   dbg: term.0 = <text>          (netdebug :9514 — every track)
#   [000123] dbg: term.0 = <text> (netdebug 9514 capture — passthrough track)
#   dbg: term.0+ = <text>         (a >VAL_CAP continuation chunk of a long line)
# The WM state mirror uses the same shape with wm.* keys:
#   dbg: wm.nwins = 3
#   dbg: wm.focus = 2:duck.glb
#   dbg: wm.win2 = x=100 y=80 w=640 h=520 max=0 t=duck.glb
#   dbg: wm.closed = 2
#   dbg: wm.ptr = x=512 y=400 b=1

import re

_MIRROR_RE = re.compile(r"dbg: term\.(\d+)(\+?) = (.*)$")
_WM_RE = re.compile(r"dbg: (wm\.[a-z_0-9]+) = (.*)$")


def parse_mirror_lines(text):
    """Yield (core:int, wrapped:bool, payload:str) for every term.<core> record
    in a capture blob, in file order. Non-mirror lines are skipped."""
    for raw in text.splitlines():
        m = _MIRROR_RE.search(raw)
        if m:
            yield int(m.group(1)), m.group(2) == "+", m.group(3)


def mirror_text(capture, core):
    """All mirrored output from terminal `core` in `capture`, newline-joined.
    A `term.<core>+` record is a mid-line cap-overflow flush whose CONTINUATION
    FOLLOWS in the next record (terminal.zig mirrorFlush) — so a `+` chunk opens
    or extends a pending line, and only a plain record closes one. Real newlines
    separate distinct lines."""
    out = []
    pending = ""
    for c, wrapped, payload in parse_mirror_lines(capture):
        if c != core:
            continue
        if wrapped:
            pending += payload
        else:
            out.append(pending + payload)
            pending = ""
    if pending:
        out.append(pending)
    return "\n".join(out)


def wm_records(capture):
    """All WM state records in `capture`, in order, as (key, value) pairs —
    e.g. ("wm.focus", "2:duck.glb"), ("wm.nwins", "3")."""
    out = []
    for raw in capture.splitlines():
        m = _WM_RE.search(raw)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


def wm_last(capture, key):
    """The latest value of one wm.* key in `capture`, or None."""
    val = None
    for k, v in wm_records(capture):
        if k == key:
            val = v
    return val


_WIN_VAL_RE = re.compile(r"x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+) max=([01]) t=(.*)$")
_PTR_VAL_RE = re.compile(r"x=(-?\d+) y=(-?\d+) b=(\d+)$")


def wm_state(capture):
    """Replay every wm.* record in order into the CURRENT window-manager state:
    {"nwins": int|None, "focus": (id, title)|None,
     "wins": {id: {"x","y","w","h","max","t"}}, "closed": [ids in order],
     "ptr": (x, y, buttons)|None }."""
    st = {"nwins": None, "focus": None, "wins": {}, "closed": [], "ptr": None}
    for k, v in wm_records(capture):
        if k == "wm.nwins":
            st["nwins"] = int(v)
        elif k == "wm.focus":
            wid, _, title = v.partition(":")
            st["focus"] = (int(wid), title)
        elif k == "wm.closed":
            wid = int(v)
            st["closed"].append(wid)
            st["wins"].pop(wid, None)
        elif k == "wm.ptr":
            m = _PTR_VAL_RE.match(v)
            if m:
                st["ptr"] = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
        elif k.startswith("wm.win"):
            m = _WIN_VAL_RE.match(v)
            if m:
                st["wins"][int(k[len("wm.win"):])] = {
                    "x": int(m.group(1)), "y": int(m.group(2)),
                    "w": int(m.group(3)), "h": int(m.group(4)),
                    "max": m.group(5) == "1", "t": m.group(6),
                }
    return st


def win_by_title(state, title_tail):
    """(id, geom) of the first live window whose title tail matches, else None."""
    for wid, g in state["wins"].items():
        if g["t"] == title_tail:
            return wid, g
    return None


# Window chrome geometry — the macOS-style gles chrome (src/ui/wm/chrome.zig):
# TITLE_H=28, three traffic lights down the LEFT of the title bar at x = TL_X0 + i*TL_PITCH,
# y = TL_Y, order close(0) / minimise(1) / zoom=maximise(2). Resize is still the window's
# own bottom-right grip (src/ui/wm/window.zig: BORDER=1, GRIP=20). Click targets are
# computed from wm.win records.
BORDER, TITLE_H, GRIP = 1, 28, 20
TL_X0, TL_PITCH, TL_Y = 20, 24, 14
TL_R = 7  # drawn radius of a traffic-light disc (chrome.zig TL_R) — its curved,
          # high-contrast edge is the DSK-009 anti-aliasing target.


def disc_centers(g):
    """Screen centres of the three traffic-light discs, close/minimise/zoom."""
    return [(g["x"] + TL_X0 + i * TL_PITCH, g["y"] + TL_Y) for i in range(3)]


def close_box_center(g):
    # The red (close) traffic light — leftmost.
    return g["x"] + TL_X0, g["y"] + TL_Y


def max_box_center(g):
    # The green (zoom / maximise) traffic light — third from the left.
    return g["x"] + TL_X0 + 2 * TL_PITCH, g["y"] + TL_Y


def title_center(g):
    # The centred-title geometry the chrome case asserts (DSK-007).
    # A drag point on the title bar, clear of the traffic lights (which end near x=67).
    # The lights are on the LEFT now, so the clear grab area is the RIGHT of the bar.
    return g["x"] + max(90, g["w"] - 30), g["y"] + TL_Y


def body_center(g):
    return g["x"] + g["w"] // 2, g["y"] + TITLE_H + (g["h"] - TITLE_H) // 2


def grip_center(g):
    return g["x"] + g["w"] - BORDER - GRIP // 2, g["y"] + g["h"] - BORDER - GRIP // 2


class CaseFailure(Exception):
    """One case's expected substring was absent from the mirrored output."""


def assert_case(case, mirror):
    """Raise CaseFailure naming the FIRST missing expectation. An empty expects
    tuple is a type-only case (asserted elsewhere, e.g. via the next prompt)."""
    for expect in case.expects:
        if expect not in mirror:
            raise CaseFailure(
                f"command {case.cmd!r}: expected substring {expect!r} not found "
                f"in mirrored output"
            )


# ── self-test: `python3 scripts/tests/cases.py` (check.sh runs it) ──────────

def _selftest_mirror_wrap():
    """The wrap direction is load-bearing: a `+` record's continuation FOLLOWS
    it. Read backwards, every wrapped ps row disappears from the parse (the
    boot-3 LOAD phase then reports fewer cores than the kernel printed)."""
    capture = "\n".join([
        "[0001] dbg: term.11 = #0   whole row",
        "[0002] dbg: term.11+ = #1   wraps mid-",
        "[0003] dbg: term.11 = word tail",
        "[0004] dbg: term.11 = legend",
        "[0005] dbg: term.3 = other terminal",
    ])
    got = mirror_text(capture, core=11)
    want = "#0   whole row\n#1   wraps mid-word tail\nlegend"
    assert got == want, f"mirror_text wrap re-join broken:\n{got!r}\n!=\n{want!r}"


if __name__ == "__main__":
    _selftest_mirror_wrap()
    print("cases: self-tests pass")
