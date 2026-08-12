#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.2.0"]
# ///
"""netdebug-mcp — an MCP server for the kudos debug channels.

Two channels, one server:
- netdebug CAPTURE (UDP 9514): boot/trace lines, buffered here. A wire loss shows
  as a sequence gap AND is recoverable — kudos retains sent lines, and
  netdebug_recover fetches the missing ones back over the RPC channel (DIAG-023).
- netdebug RPC (UDP 9515, reliable, kmir.py client): input injection and
  screenshot download.

kudos mirrors every serial byte onto the LAN as UDP broadcast datagrams on port
9514 (src+dst); the value and framing are owned by src/drivers/net/debug/netdebug.zig.
Each datagram is exactly ONE text line, prefixed `[NNNNNN] ` with a 6-digit
monotonic sequence number so any dropped datagram is visible as a gap.

This server binds :9514 in a background thread, buffers lines in a ring, tracks
sequence gaps, and exposes query tools so Claude can pull traces directly instead
of a human pasting them — plus health tools to check the listener is live and
whether kudos is actively streaming.

The socket owner is the LISTENER: this server must be the only thing bound to
:9514 while it runs. The integration harnesses (run_emulated.sh, run_native.sh,
run_passthrough.sh) each start their own `socat -u udp-recv:9514` capture, so this
server and a running suite CONTEND for the port — whichever binds second gets
EADDRINUSE and silently sees nothing. It rebroadcasts nothing; it only reads.
"""

import re
import socket
import threading
import time
from collections import deque
from dataclasses import dataclass, field

from mcp.server.fastmcp import FastMCP

# ── configuration (single source of truth for the values this server owns) ──────
PORT = 9514  # MUST match netdebug.PORT (src/drivers/net/debug/netdebug.zig)
RING_CAP = 100_000  # lines retained in memory; a full boot is a few thousand
# kudos is considered "actively streaming" if a datagram arrived within this many
# seconds. The drain is metered at 8 lines / 200 ms once the link settles, so a
# live board emits continuously; a quiet gap this long means it stopped or booted
# away from the netdebug path.
STREAMING_FRESHNESS_S = 5.0
# Wall-clock the process started (monotonic base for uptime).
_START = time.monotonic()

# Matches the `[NNNNNN] ` seq prefix netdebug.writeSeqPrefix emits.
_SEQ_RE = re.compile(rb"^\[(\d{6})\] ?(.*)$", re.S)


@dataclass
class Record:
    """One captured datagram: its wire seq (or None if unprefixed), text, and arrival time."""

    seq: int | None
    text: str  # the line WITHOUT the [NNNNNN] prefix, trailing newline stripped
    raw: str  # the full line as received (prefix included), newline stripped
    t: float  # monotonic arrival time
    # True for a line that was LOST on the wire and fetched back over the RPC
    # channel (netdebug_recover, DIAG-023). It arrives late, so it sits at the
    # ring's tail out of stream order; the flag says why.
    recovered: bool = False


@dataclass
class Capture:
    """Thread-safe ring of captured records plus liveness counters.

    One lock guards everything. The listener thread appends; tool calls read.
    """

    lock: threading.Lock = field(default_factory=threading.Lock)
    ring: deque[Record] = field(default_factory=lambda: deque(maxlen=RING_CAP))
    total: int = 0  # LINES received since start (a datagram may pack many; pre-eviction)
    total_datagrams: int = 0  # UDP datagrams received (each packs 1..N coalesced lines)
    last_arrival: float | None = None  # monotonic time of most recent datagram
    last_seq: int | None = None  # most recent parsed seq (for gap detection)
    gaps: list[tuple[int, int]] = field(default_factory=list)  # (after_seq, missing_count)
    dropped_total: int = 0  # sum of missing datagrams inferred from seq gaps
    recovered_total: int = 0  # lines fetched back over RPC (netdebug_recover)
    unrecoverable_total: int = 0  # lines kudos no longer retained when asked
    bind_error: str | None = None  # non-None if the socket failed to bind
    recent: deque[float] = field(default_factory=lambda: deque(maxlen=RING_CAP))  # arrival times for rate
    source_ip: str | None = None  # where the trace comes FROM — kudos itself, learned per datagram

    def add(self, raw_bytes: bytes) -> None:
        # A datagram now PACKS multiple newline-delimited lines (netdebug coalesces up
        # to DATAGRAM_CAP bytes per UDP frame for high-rate tracing). Split on '\n'
        # and process each non-empty line individually so seq numbers, gap detection
        # and the ring stay per-LINE (not per-datagram). Backward-compatible: a
        # single-line datagram splits to one line.
        now = time.monotonic()
        with self.lock:
            self.total_datagrams += 1
        for line in raw_bytes.split(b"\n"):
            if line:  # skip the empty trailing field after the final '\n'
                self._add_line(line, now)

    def _add_line(self, raw_bytes: bytes, now: float) -> None:
        m = _SEQ_RE.match(raw_bytes)
        if m:
            seq = int(m.group(1))
            body = m.group(2).decode("utf-8", "replace").rstrip("\n")
        else:
            seq = None
            body = raw_bytes.decode("utf-8", "replace").rstrip("\n")
        raw = raw_bytes.decode("utf-8", "replace").rstrip("\n")
        with self.lock:
            self.total += 1
            self.last_arrival = now
            self.recent.append(now)
            if seq is not None:
                # Gap detection. seq is monotonic and wraps at 10**6 (SEQ_DIGITS).
                if self.last_seq is not None and seq != self.last_seq:
                    expected = (self.last_seq % 1_000_000) + 1
                    if expected == 1_000_000:
                        expected = 0
                    if seq != expected and seq > self.last_seq:
                        missing = seq - expected
                        if 0 < missing < 100_000:  # ignore wrap/reboot resets
                            self.gaps.append((self.last_seq, missing))
                            self.dropped_total += missing
                self.last_seq = seq
            self.ring.append(Record(seq=seq, text=body, raw=raw, t=now))


CAP = Capture()


def _listener() -> None:
    """Bind :9514 and drain datagrams into the ring forever. Runs as a daemon thread."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", PORT))
    except OSError as e:
        with CAP.lock:
            CAP.bind_error = (f"{e} (is an integration suite already capturing on :{PORT}? "
                              f"each run_*.sh binds its own socat)")
        return
    while True:
        try:
            data, addr = sock.recvfrom(2048)
        except OSError:
            continue
        if data:
            # The datagram's source IS kudos — remember it, so gap recovery (and
            # any RPC tool called without an ip) has a target with no discovery.
            with CAP.lock:
                CAP.source_ip = addr[0]
            CAP.add(data)


mcp = FastMCP("kudos-netdebug")


def _rate_per_s(window: float = 10.0) -> float:
    """Datagrams/second over the trailing `window` seconds."""
    now = time.monotonic()
    with CAP.lock:
        n = sum(1 for t in CAP.recent if now - t <= window)
    return round(n / window, 2)


def _snapshot(rec: Record) -> dict:
    return {"seq": rec.seq, "text": rec.text, "age_s": round(time.monotonic() - rec.t, 3)}


# ── health / liveness tools ─────────────────────────────────────────────────────
@mcp.tool()
def netdebug_status() -> dict:
    """Health of the netdebug listener AND whether kudos is actively streaming.

    Returns bind state, uptime, total datagrams captured, current datagram rate,
    seconds since the last datagram, sequence-gap/drop counts, and a
    `kudos_streaming` flag (true if a datagram arrived within the freshness
    window). Call this first to confirm the capture path is live before querying
    traces.
    """
    now = time.monotonic()
    with CAP.lock:
        bind_error = CAP.bind_error
        total = CAP.total  # lines
        total_datagrams = CAP.total_datagrams  # UDP frames (each packs 1..N lines)
        last_arrival = CAP.last_arrival
        buffered = len(CAP.ring)
        gaps = len(CAP.gaps)
        dropped = CAP.dropped_total
        last_seq = CAP.last_seq
    since = round(now - last_arrival, 2) if last_arrival is not None else None
    listening = bind_error is None
    streaming = listening and since is not None and since <= STREAMING_FRESHNESS_S
    return {
        "listening": listening,
        "bind_error": bind_error,
        "port": PORT,
        "uptime_s": round(now - _START, 1),
        "kudos_streaming": streaming,
        "seconds_since_last_datagram": since,
        "line_rate_per_s": _rate_per_s(),
        "total_lines": total,
        "total_datagrams": total_datagrams,
        "buffered_lines": buffered,
        "last_seq": last_seq,
        "sequence_gaps": gaps,
        "datagrams_dropped_est": dropped,
        "health": (
            "not_listening" if not listening
            else "no_data_yet" if last_arrival is None
            else "streaming" if streaming
            else "idle"
        ),
    }


@mcp.tool()
def netdebug_ping() -> dict:
    """Cheap liveness check: is the listener thread bound and has it ever seen data?

    Returns {alive, listening, has_data}. Use for a fast up/down probe without the
    full status payload.
    """
    with CAP.lock:
        listening = CAP.bind_error is None
        has_data = CAP.total > 0
    return {"alive": True, "listening": listening, "has_data": has_data}


@mcp.tool()
def netdebug_wait_for_stream(timeout_s: float = 30.0) -> dict:
    """Block up to `timeout_s` until kudos starts streaming (a fresh datagram arrives).

    Useful right after you ask the user to boot: poll instead of guessing. Returns
    {streaming, waited_s, total_datagrams}.
    """
    deadline = time.monotonic() + max(0.0, timeout_s)
    start = time.monotonic()
    while time.monotonic() < deadline:
        with CAP.lock:
            last = CAP.last_arrival
        if last is not None and (time.monotonic() - last) <= STREAMING_FRESHNESS_S:
            break
        time.sleep(0.25)
    with CAP.lock:
        last = CAP.last_arrival
        total_lines = CAP.total
        total_datagrams = CAP.total_datagrams
    streaming = last is not None and (time.monotonic() - last) <= STREAMING_FRESHNESS_S
    return {"streaming": streaming, "waited_s": round(time.monotonic() - start, 2), "total_lines": total_lines, "total_datagrams": total_datagrams}


# ── trace query tools ───────────────────────────────────────────────────────────
@mcp.tool()
def netdebug_build_banner() -> dict:
    """The build-identity banner kudos emits as the first netdebug line of every trace.

    kudos prints `NETDEBUG-BUILD kudos build #N gHASH built <utc>` the moment netdebug
    starts (src/drivers/net/debug/netdebug.zig), so every capture is tied to a known image.
    Returns the parsed {build_number, git_hash, built, raw} of the MOST RECENT
    banner seen (a reboot emits a fresh one), or {found:false} if none captured yet.
    Check this before trusting a trace — it confirms which build you're looking at.
    """
    rx = re.compile(r"NETDEBUG-BUILD kudos build #(\d+) g(\S+) built (\S+)")
    with CAP.lock:
        recs = list(CAP.ring)
    last = None
    for r in recs:
        m = rx.search(r.text)
        if m:
            last = (m, r)
    if last is None:
        return {"found": False, "note": "no NETDEBUG-BUILD banner captured yet — kudos may not have (re)started netdebug"}
    m, r = last
    return {
        "found": True,
        "build_number": int(m.group(1)),
        "git_hash": m.group(2),
        "built": m.group(3),
        "raw": r.text,
        "age_s": round(time.monotonic() - r.t, 1),
    }


@mcp.tool()
def netdebug_tail(lines: int = 50) -> dict:
    """The most recent `lines` captured netdebug lines, oldest-first.

    Returns {count, lines:[{seq,text,age_s}]}. This is your default "what's
    happening right now" view.
    """
    n = max(1, min(lines, RING_CAP))
    with CAP.lock:
        recs = list(CAP.ring)[-n:]
    return {"count": len(recs), "lines": [_snapshot(r) for r in recs]}


@mcp.tool()
def netdebug_grep(pattern: str, max_matches: int = 200, ignore_case: bool = True) -> dict:
    """Return captured lines whose text matches a regex `pattern` (searched newest-first, returned oldest-first).

    Use for pinning specific events: "OVERREAD", "mirror OFF", "GMMU", "Xid",
    "exhausted", "FRAME". Returns {count, truncated, lines:[{seq,text,age_s}]}.
    """
    flags = re.IGNORECASE if ignore_case else 0
    try:
        rx = re.compile(pattern, flags)
    except re.error as e:
        return {"error": f"bad regex: {e}"}
    with CAP.lock:
        recs = list(CAP.ring)
    out = [r for r in recs if rx.search(r.text)]
    truncated = len(out) > max_matches
    if truncated:
        out = out[-max_matches:]
    return {"count": len(out), "truncated": truncated, "lines": [_snapshot(r) for r in out]}


@mcp.tool()
def netdebug_frames(last_n: int = 8) -> dict:
    """Extract the compositor per-frame traces (COMPOSITE_DEBUG in present.zig).

    Groups lines by `FRAME <n>` headers and returns the last `last_n` frames, each
    with its header line and the blit-geometry lines that follow it (until the next
    FRAME or a non-composite line). Flags any line containing OVERREAD / exhausted /
    mirror OFF so drag artifacts surface immediately.
    Returns {frame_count, frames:[{frame, header, blits:[...], flags:[...]}]}.
    """
    with CAP.lock:
        recs = list(CAP.ring)
    frames: list[dict] = []
    cur: dict | None = None
    frame_hdr = re.compile(r"FRAME\s+(\d+)\s+nblits=")
    alert = re.compile(r"OVERREAD|exhausted|mirror OFF|GMMU|Xid", re.IGNORECASE)
    for r in recs:
        t = r.text
        m = frame_hdr.search(t)
        if m:
            if cur is not None:
                frames.append(cur)
            cur = {"frame": int(m.group(1)), "header": t, "blits": [], "flags": []}
            if alert.search(t):
                cur["flags"].append(t)
            continue
        if cur is not None:
            # A blit line is an indented/continuation composite line; stop the group
            # at anything that clearly isn't part of the frame dump.
            if "blit" in t.lower() or "OVERREAD" in t or "src" in t.lower() or t.startswith(" "):
                cur["blits"].append(t)
                if alert.search(t):
                    cur["flags"].append(t)
            elif alert.search(t):
                cur["flags"].append(t)
            else:
                frames.append(cur)
                cur = None
    if cur is not None:
        frames.append(cur)
    n = max(1, last_n)
    return {"frame_count": len(frames), "frames": frames[-n:]}


@mcp.tool()
def netdebug_gaps() -> dict:
    """Sequence-number gaps detected in the capture (dropped datagrams).

    Each netdebug line carries a monotonic seq; a jump means datagrams were lost on
    the wire (NIC TX ring / socket overrun). Returns {gap_count, datagrams_dropped_est,
    gaps:[{after_seq, missing}]}. A clean capture has zero gaps.
    """
    with CAP.lock:
        gaps = list(CAP.gaps)
        dropped = CAP.dropped_total
        recovered = CAP.recovered_total
        unrecoverable = CAP.unrecoverable_total
    return {
        "gap_count": len(gaps),
        "datagrams_dropped_est": dropped,
        "recovered_total": recovered,
        "unrecoverable_total": unrecoverable,
        "gaps": [{"after_seq": a, "missing": m} for a, m in gaps],
        "hint": "netdebug_recover fetches the missing lines back over RPC" if gaps else "",
    }


# Most lines one recovery call will pull back, so a huge gap cannot hold a tool
# call hostage: what remains is reported and the next call continues.
RECOVER_BUDGET_LINES = 500


@mcp.tool()
def netdebug_recover(guest_ip: str = "") -> dict:
    """Fill the capture's sequence gaps by asking kudos for the missing lines
    back (DIAG-023).

    Wire loss is recoverable now: kudos RETAINS every trace line it sent, and the
    RPC channel (retransmitted, deduplicated) serves them again by sequence
    number. Recovered lines are appended to the ring flagged `recovered` — they
    arrive late, so they sit out of stream order, but grep/tail/frames see them.
    A line kudos no longer retained is permanently lost; it is counted, reported
    here, and the gap is retired rather than re-asked forever.
    """
    with CAP.lock:
        pending = list(CAP.gaps)
    if not pending:
        return {"recovered": 0, "permanent": 0, "gaps_remaining": 0}
    client = _client(guest_ip)
    recovered = 0
    permanent = 0
    budget = RECOVER_BUDGET_LINES
    retired: list[tuple[int, int]] = []
    for after_seq, missing in pending:
        if budget <= 0:
            break
        want = min(missing, budget)
        got_lines: list[bytes] = []
        offset = 0
        while offset < want:
            first = (after_seq + 1 + offset) % 1_000_000
            n = min(want - offset, 9)  # kmir.RESEND_MAX_LINES
            try:
                text = client.resend(first, n)
            except Exception as e:  # noqa: BLE001 — a dead machine ends recovery, with the reason
                return {"recovered": recovered, "permanent": permanent,
                        "gaps_remaining": len(pending) - len(retired),
                        "error": f"rpc failed at seq {first}: {e}"}
            got_lines.extend(l.encode() for l in text.split("\n") if l)
            offset += n
        now = time.monotonic()
        with CAP.lock:
            for line in got_lines:
                m = _SEQ_RE.match(line)
                if not m:
                    continue
                CAP.ring.append(Record(
                    seq=int(m.group(1)),
                    text=m.group(2).decode("utf-8", "replace").rstrip("\n"),
                    raw=line.decode("utf-8", "replace").rstrip("\n"),
                    t=now,
                    recovered=True,
                ))
            CAP.recovered_total += len(got_lines)
            CAP.unrecoverable_total += want - len(got_lines)
        recovered += len(got_lines)
        permanent += want - len(got_lines)
        budget -= want
        retired.append((after_seq, missing))
    with CAP.lock:
        CAP.gaps = [g for g in CAP.gaps if g not in retired]
        remaining = len(CAP.gaps)
    return {"recovered": recovered, "permanent": permanent, "gaps_remaining": remaining}


def _client(guest_ip: str):
    """A netdebug RPC client (kmir.py) for `guest_ip`, auto-discovering the
    guest when it is empty: newest 'lease ip X' line in the netdebug capture,
    then kmir's dnsmasq-lease / ARP discovery."""
    import kmir

    ip = guest_ip or None
    if ip is None:
        # The strongest hint costs nothing: the capture's datagrams NAME their
        # sender, and the sender is kudos.
        with CAP.lock:
            ip = CAP.source_ip
    if ip is None:
        with CAP.lock:
            for rec in reversed(CAP.ring):
                m = re.search(r"lease ip (\d+\.\d+\.\d+\.\d+)", rec.text)  # any subnet: QEMU tap OR lemon's LAN
                if m:
                    ip = m.group(1)
                    break
    return kmir.Client(kmir.discover_ip(ip))


@mcp.tool()
def netdebug_inject_key(text: str, guest_ip: str = "") -> dict:
    """Type `text` into the focused window of the running kudos desktop (ASCII
    only — no arrows/modifiers; '\n' presses Enter).

    Delivery is confirmed, not assumed: kudos replies with how much of the string
    it had room for, and this resends the remainder until every byte is in. A
    machine that is momentarily full costs a retry; it never costs a silently
    truncated command.

    Use netdebug_select_window first when it matters WHERE the text lands.

    Returns {typed} (character count).
    """
    return {"typed": _client(guest_ip).inject_text(text)}


@mcp.tool()
def netdebug_select_window(title: str, guest_ip: str = "") -> dict:
    """Focus the front-most visible kudos window whose title CONTAINS `title`,
    and return the title that ended up focused.

    Injected keys go to whatever holds focus, so this is what makes typing
    deterministic — the alternative is clicking a title bar at coordinates that
    change whenever a window moves. Pass an empty `title` to ask where focus is
    without moving it.

    Raises if nothing matches: a miss leaves focus alone rather than guessing,
    because typing a command into the wrong window is worse than typing it
    nowhere.

    Returns {focused}.
    """
    client = _client(guest_ip)
    if not title:
        return {"focused": client.focused_window()}
    return {"focused": client.focus_window(title)}


@mcp.tool()
def netdebug_inject_mouse(dx: int, dy: int, buttons: int = 0, guest_ip: str = "") -> dict:
    """Inject relative mouse motion (pixels pre-acceleration) and a button
    mask (bit0 left, bit1 right, bit2 middle) into the running kudos desktop.
    Rides the real HID path, so pointer acceleration applies. Exactly-once.

    Returns {dx, dy, buttons}.
    """
    _client(guest_ip).inject_mouse(dx, dy, buttons)
    return {"dx": dx, "dy": dy, "buttons": buttons}


@mcp.tool()
def netdebug_screenshot(out_dir: str = "assets/screenshots", guest_ip: str = "") -> dict:
    """Capture the LIVE kudos desktop at full native resolution: trigger a
    SHOT, wait for screenshot.png to land in the guest ramdisk (generation
    bump), download + CRC-verify it (~15 MB, expect ~10 s), and return the
    local path. Fails loudly after ~20 s if the capture never lands.

    Returns {path}.
    """
    return {"path": _client(guest_ip).screenshot(out_dir)}


@mcp.tool()
def netdebug_clear() -> dict:
    """Discard the buffered capture and reset counters (start a fresh window).

    Call before asking the user to reproduce something so the next query shows only
    the new run. Does NOT stop the listener. Returns {cleared, previously_buffered}.
    """
    with CAP.lock:
        prev = len(CAP.ring)
        CAP.ring.clear()
        CAP.recent.clear()
        CAP.gaps.clear()
        CAP.dropped_total = 0
        CAP.last_seq = None
        # keep total / last_arrival so liveness history survives a clear
    return {"cleared": True, "previously_buffered": prev}


# ── KMR1 request/response: asking kudos, not just listening to it ───────────────
# netdebug (:9514) is a one-way broadcast — it tells you what kudos SAYS. These ask
# kudos a question and require an answer, which is a different and stronger fact: a
# reply proves the machine took an interrupt, ran its network stack, and got a frame
# back out. A silent netdebug stream is ambiguous (wedged? link down? log gate off?)
# and that ambiguity has cost this project physical power cycles. A ping that stops
# answering is not ambiguous.


def _parse_status(line: str) -> dict:
    """`build=2604 up_ms=1580 ticks=158 usbdev=3 kbd=1 …` → a dict of ints, with the
    raw line kept so a field we do not know about yet is never silently dropped."""
    out = {"raw": line}
    for kv in line.split():
        if "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        try:
            out[k] = int(v)
        except ValueError:
            out[k] = v
    return out


@mcp.tool()
def netdebug_kudos_status(guest_ip: str = "") -> dict:
    """Ask the running kudos how it is (KMR1 PING) — the request/response liveness probe.

    Returns the parsed status: build, up_ms, ticks, and the USB summary (usbdev, kbd,
    mouse, usbdisk, kbd_rep, mouse_rep). `ticks` is the IRQ0 counter: compare it with
    your own wall clock and a CPU that still runs while its interrupts are DEAD stops
    being invisible. Raises if kudos does not answer — that is a fact, not an error to
    paper over.
    """
    return _parse_status(_client(guest_ip).ping())


@mcp.tool()
def netdebug_kudos_version(guest_ip: str = "") -> dict:
    """Which kudos is ACTUALLY running: build number, git hash, build time (KMR1 VERSION).

    The kernel is fetched over the network at boot, so "is the machine running the image
    I just built" has a real wrong answer — a stale file served out of build/netboot/.
    Ask the running kernel; it is the only authority.
    """
    return _parse_status(_client(guest_ip).version())


@mcp.tool()
def netdebug_kudos_reboot(guest_ip: str = "") -> dict:
    """Reset the machine (KMR1 REBOOT): kudos ACKs, then resets ~5 s later.

    The delay is deliberate — the ACK is one UDP datagram, and if it is lost the
    retransmit needs a machine still alive to answer it. On lemon the reset lands back
    in Ubuntu via the boot one-shot, so this is how you END A RUN with nobody in the room.
    """
    _client(guest_ip).reboot()
    return {"accepted": True, "note": "kudos ACKed; it resets ~5s from now"}


@mcp.tool()
def netdebug_kudos_shutdown(guest_ip: str = "") -> dict:
    """Power the machine OFF (KMR1 SHUTDOWN): kudos ACKs, then powers off ~5 s later.

    DANGER on a remote rig: a powered-off machine cannot be woken over the network —
    someone has to walk to it and press the button. Use netdebug_kudos_reboot to end a
    run unless you specifically mean "off".
    """
    _client(guest_ip).shutdown()
    return {"accepted": True, "note": "kudos ACKed; it POWERS OFF ~5s from now (no remote wake)"}


@mcp.tool()
def netdebug_heartbeat(secs: float = 30.0, hz: float = 1.0, reboot_at: float = -1.0,
                       guest_ip: str = "") -> dict:
    """Drive kudos at `hz` for `secs` and report what came back — the bring-up verdict.

    One shot per beat, NO retransmits: a retry that eventually succeeds HIDES the loss,
    and loss is the signal. Each beat gets one question and one chance to answer.

    `reboot_at` (seconds, -1 = never) sends a REBOOT request mid-run and keeps pinging
    through it: replies must continue for ~5 s and then stop dead. That is the one test
    of the remote-reset path that matters — a machine that resets BEFORE it ACKs is one
    whose reboot you can never confirm.

    Returns {replies, misses, beats, drift_s, first, last, usb, timeline}. `drift_s` is
    kudos's up_ms against the host wall clock: it should hold near zero, and a growing
    negative drift means the IRQ0 tick is dying while the CPU still runs.
    """
    import kmir  # lazy, like _client: the MCP must start even if the guest tooling is absent

    client = _client(guest_ip)
    client.sock.settimeout(0.5)
    kmir.RETRIES, kmir.TIMEOUT_S = 1, 0.5  # one shot per beat; see above

    t0, period = time.time(), 1.0 / hz
    replies = misses = 0
    beat = 0
    first = last = None
    ref = None  # (host_t, kudos_up_s) at first reply — kudos was up before we started
    drift = 0.0
    timeline: list[dict] = []
    did_reboot = False

    while time.time() - t0 < secs:
        deadline = t0 + (beat + 1) * period
        beat += 1
        sent = time.time()
        try:
            st = _parse_status(client.ping())
            rtt = time.time() - sent
            replies += 1
            last = st
            if first is None:
                first = st
            if "up_ms" in st:
                up = st["up_ms"] / 1000.0
                if ref is None:
                    ref = (sent, up)
                else:
                    drift = (up - ref[1]) - (sent - ref[0])
            timeline.append({"beat": beat, "rtt_ms": round(rtt * 1000, 1),
                             "drift_s": round(drift, 2), "status": st.get("raw", "")})
            if reboot_at >= 0 and not did_reboot and (sent - t0) >= reboot_at:
                did_reboot = True
                client.reboot()
                timeline.append({"beat": beat, "event": "REBOOT requested (ACKed) — "
                                 "expect ~5s more replies, then a reset"})
        except Exception:  # kmir.KmirError, and any transport failure = a miss, not a crash
            misses += 1
            timeline.append({"beat": beat, "status": "NO REPLY"})

        sleep = deadline - time.time()
        if sleep > 0:
            time.sleep(sleep)

    usb = {}
    if last:
        usb = {k: last.get(k) for k in
               ("usbdev", "kbd", "mouse", "usbdisk", "kbd_rep", "mouse_rep")
               if k in last}
    return {"replies": replies, "misses": misses, "beats": beat,
            "drift_s": round(drift, 2), "first": first, "last": last,
            "usb": usb, "timeline": timeline[-60:]}


def main() -> None:
    t = threading.Thread(target=_listener, name="netdebug-udp", daemon=True)
    t.start()
    mcp.run()  # stdio transport


if __name__ == "__main__":
    main()
