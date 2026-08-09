"""netdebug client — RPC control of a running kudos + reliable file download.

Wire protocol: guest src/drivers/net/debug/fileproto.zig. All reliability lives
here: sequential chunk requests with timeout + retransmit, generation
tracking, whole-file CRC-32 verification, atomic renames into the output
directory. UDP loss/duplication/reordering are handled; a reply is accepted
only if its request_id matches the in-flight request. Injection ops
(key/mouse/shot) retransmit safely: the guest deduplicates by request_id, so
a retried datagram never double-injects.

Bulk ramdisk-mirror (`sync`) was removed once the USB disk replaced the
netdebug file mirror; the surviving download path serves the screenshot flow
(list_files/read_file → _pull_verified).
"""

import binascii
import json
import os
import re
import socket
import struct
import subprocess
import time

MAGIC = 0x31524D4B  # 'KMR1'
PORT = 9515
OP_LIST, OP_LIST_R = 0x01, 0x81
OP_READ, OP_READ_R = 0x02, 0x82
OP_WRITE, OP_WRITE_R = 0x03, 0x83
OP_KEY, OP_KEY_R = 0x04, 0x84
OP_MOUSE, OP_MOUSE_R = 0x05, 0x85
OP_SHOT, OP_SHOT_R = 0x06, 0x86
OP_REBOOT, OP_REBOOT_R = 0x07, 0x87
OP_PING, OP_PING_R = 0x09, 0x89
OP_VERSION, OP_VERSION_R = 0x0A, 0x8A
OP_SHUTDOWN, OP_SHUTDOWN_R = 0x0B, 0x8B
OP_MOUSE_ABS, OP_MOUSE_ABS_R = 0x0C, 0x8C
OP_STATS, OP_STATS_R = 0x0D, 0x8D
OP_RINGTAIL, OP_RINGTAIL_R = 0x0E, 0x8E
OP_MCP, OP_MCP_R = 0x0F, 0x8F
OP_TEXT, OP_TEXT_R = 0x10, 0x90
OP_FOCUS, OP_FOCUS_R = 0x11, 0x91
MCP_RESPONSE_FILE = "mcp-response.json"
# Named (non-character) keys OP_KEY can carry — must match fileproto.KEY_*.
KEY_NONE, KEY_F11, KEY_F12, KEY_F10, KEY_F1 = 0, 1, 2, 3, 4
KEY_UP_ASCII, KEY_DOWN_ASCII = 0x10, 0x11  # kudos carries arrows as control bytes
OP_ERR = 0xFF
ERR_GENERATION = 2
# kudos was well-formed but out of room. The ONLY error where resending the same
# datagram is correct: the request was not recorded as dispatched, so the retry
# is a fresh attempt rather than a re-ACK of something that never happened.
ERR_BUSY = 4

# How long to keep retrying a BUSY request, and how long to pause between tries.
# kudos drains its input ring on every pass of the desktop loop (kHz), so a full
# ring clears in well under a millisecond; a whole second of retries means
# something is genuinely wedged and the caller should hear about it.
BUSY_RETRY_S = 1.0
BUSY_PAUSE_S = 0.01
CHUNK = 1200
TIMEOUT_S = 0.15
RETRIES = 8
READ_WINDOW = 16  # pipelined read_file: chunk requests kept in flight (R68)
SHOT_POLL_S = 0.1  # LIST poll cadence while a SHOT lands (fine-grained: the capture is budgeted at 1 s, so the poll must not dominate the measurement)
SHOT_TIMEOUT_S = 20.0  # a capture is one session-loop iteration away; 20 s is generous

HDR = struct.Struct("<IBBH")


class KmirError(Exception):
    pass


class GenerationChanged(KmirError):
    pass


class Busy(KmirError):
    """kudos had no room for a well-formed request. Retry the same bytes."""

    pass


def discover_ip(explicit=None):
    """Guest IP: explicit arg -> dnsmasq lease on the kudoslog tap."""
    if explicit:
        return explicit
    for lease_path in ("/var/lib/misc/dnsmasq.leases", "/var/lib/dnsmasq/dnsmasq.leases"):
        try:
            with open(lease_path) as f:
                leases = [ln.split() for ln in f if ln.strip()]
            for parts in reversed(leases):
                if len(parts) >= 3 and parts[2].startswith("10.55.0."):
                    return parts[2]
        except OSError:
            continue
    # Fall back to the ARP/neighbour table on the tap.
    try:
        out = subprocess.run(["ip", "neigh", "show", "dev", "kudoslog"],
                             capture_output=True, text=True, check=False).stdout
        m = re.search(r"(10\.55\.0\.\d+)", out)
        if m:
            return m.group(1)
    except OSError:
        pass
    raise KmirError("cannot discover the kudos IP (no dnsmasq lease, no ARP entry); pass it explicitly")


class Client:
    def __init__(self, ip, port=PORT):
        self.addr = (ip, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(TIMEOUT_S)
        self.rid = int.from_bytes(os.urandom(2), "little")

    def _rpc(self, payload_body, op):
        """Send one request; return the reply body (after the 8-B header).
        Retransmits the identical datagram on timeout; discards replies whose
        request_id doesn't match (stale/duplicated)."""
        self.rid = (self.rid + 1) & 0xFFFF
        pkt = HDR.pack(MAGIC, op, 0, self.rid) + payload_body
        for _ in range(RETRIES):
            self.sock.sendto(pkt, self.addr)
            deadline = time.time() + TIMEOUT_S
            while time.time() < deadline:
                try:
                    data, _ = self.sock.recvfrom(2048)
                except socket.timeout:
                    break
                if len(data) < HDR.size:
                    continue
                magic, rop, _flags, rid = HDR.unpack_from(data)
                if magic != MAGIC or rid != self.rid:
                    continue  # stray/stale
                if rop == OP_ERR:
                    code = data[HDR.size] if len(data) > HDR.size else 0
                    if code == ERR_GENERATION:
                        raise GenerationChanged()
                    if code == ERR_BUSY:
                        raise Busy()
                    raise KmirError(f"guest error code {code}")
                return data[HDR.size:]
        raise KmirError(f"no reply after {RETRIES} attempts (op 0x{op:02x})")

    def _rpc_until_accepted(self, payload_body, op):
        """_rpc, but waiting out a machine that is momentarily out of room.

        A BUSY reply is not a failure — it is kudos saying it did NOT take the
        request, which is the whole point of the reply existing. Retrying is the
        correct response, and the retry sends the same bytes because nothing was
        recorded as dispatched."""
        deadline = time.time() + BUSY_RETRY_S
        while True:
            try:
                return self._rpc(payload_body, op)
            except Busy:
                if time.time() >= deadline:
                    raise KmirError(
                        f"kudos stayed busy for {BUSY_RETRY_S}s (op 0x{op:02x}) — "
                        "its input ring is not draining"
                    )
                time.sleep(BUSY_PAUSE_S)

    def mcp(self, request):
        """Send one MCP JSON-RPC request to kudos (AGT-011/AGT-013) and return
        the parsed JSON-RPC response. kudos writes the response to
        MCP_RESPONSE_FILE on the ramdisk and replies with its generation; we
        then pull that file with the ordinary windowed READ. `request` is a
        dict or a JSON string."""
        if isinstance(request, dict):
            request = json.dumps(request)
        body = self._rpc(request.encode(), OP_MCP)
        (generation,) = struct.unpack_from("<I", body, 0)
        # The response file now exists at this generation; find its size via LIST
        # then pull it. A notification (no id) writes an empty response — kudos
        # returns generation 0 and there is nothing to read.
        if generation == 0:
            return None
        meta = next((f for f in self.list_files()
                     if f["name"] == MCP_RESPONSE_FILE), None)
        if meta is None:
            raise KmirError("MCP response file missing after OP_MCP")
        raw = self.read_file(MCP_RESPONSE_FILE, meta["generation"], meta["size"])
        return json.loads(raw)

    def list_files(self):
        body = self._rpc(b"", OP_LIST)
        (count,) = struct.unpack_from("<H", body, 0)
        off = 2
        files = []
        for _ in range(count):
            (nlen,) = struct.unpack_from("<H", body, off)
            off += 2
            name = body[off:off + nlen].decode()
            off += nlen
            gen, size, crc = struct.unpack_from("<III", body, off)
            off += 12
            files.append({"name": name, "generation": gen, "size": size, "crc32": crc})
        return files

    def read_file(self, name, generation, size, window=READ_WINDOW):
        """Pull one file completely, keeping up to `window` chunk requests in
        flight (reads are stateless on the guest, so pipelining is safe and
        fills the link instead of paying one RTT per 1200-byte chunk — spec
        R68's full-available-bandwidth transfer). Raises GenerationChanged on
        a mid-pull rewrite and KmirError on persistent loss."""
        nb = name.encode()
        out = bytearray(size)
        got = [False] * ((size + CHUNK - 1) // CHUNK) if size else []
        remaining = len(got)
        inflight = {}  # rid -> [offset, deadline, pkt, attempts]
        next_chunk = 0
        t0 = time.time()
        retransmits = 0

        def send(chunk_idx):
            self.rid = (self.rid + 1) & 0xFFFF
            off = chunk_idx * CHUNK
            body = struct.pack("<H", len(nb)) + nb + struct.pack(
                "<IIH", generation, off, CHUNK)
            pkt = HDR.pack(MAGIC, OP_READ, 0, self.rid) + body
            self.sock.sendto(pkt, self.addr)
            inflight[self.rid] = [chunk_idx, time.time() + TIMEOUT_S, pkt, 1]

        while remaining:
            while next_chunk < len(got) and len(inflight) < window:
                if not got[next_chunk]:
                    send(next_chunk)
                next_chunk += 1
            try:
                data, _ = self.sock.recvfrom(2048)
            except socket.timeout:
                data = None
            now = time.time()
            if data and len(data) >= HDR.size:
                magic, rop, _flags, rid = HDR.unpack_from(data)
                if magic == MAGIC and rid in inflight:
                    if rop == OP_ERR:
                        code = data[HDR.size] if len(data) > HDR.size else 0
                        if code == ERR_GENERATION:
                            raise GenerationChanged()
                        raise KmirError(f"guest error code {code}")
                    if rop == OP_READ_R:
                        gen, off, ln = struct.unpack_from("<IIH", data, HDR.size)
                        chunk_idx = inflight[rid][0]
                        if gen != generation:
                            raise GenerationChanged()
                        if off == chunk_idx * CHUNK and not got[chunk_idx]:
                            payload = data[HDR.size + 10:HDR.size + 10 + ln]
                            out[off:off + len(payload)] = payload
                            got[chunk_idx] = True
                            remaining -= 1
                        del inflight[rid]
            # Retransmit anything that timed out (same datagram: the guest
            # dedups by request_id, so a late twin never double-counts).
            for rid, ent in list(inflight.items()):
                if now >= ent[1]:
                    if ent[3] >= RETRIES:
                        raise KmirError(
                            f"{name}: chunk at {ent[0] * CHUNK} lost after {RETRIES} attempts")
                    self.sock.sendto(ent[2], self.addr)
                    ent[1] = now + TIMEOUT_S
                    ent[3] += 1
                    retransmits += 1
        # The transfer-rate evidence for PERF-013 (full-available-bandwidth
        # screenshot transfer): callers read this after a pull and put the
        # number where their harness reports.
        dt = max(time.time() - t0, 1e-6)
        self.last_pull = {
            "bytes": size,
            "seconds": dt,
            "mib_s": (size / dt) / (1024 * 1024),
            "retransmits": retransmits,
        }
        return bytes(out)

    def inject_key(self, ascii_byte, named=KEY_NONE):
        """Press one key on kudos (exactly-once; the guest dedups retries).

        `ascii_byte` is the character (0 if the key has none); `named` is a KEY_*
        code for keys with no character at all — F11/F12, which the window-manager
        tests need. Arrow keys are NOT named: kudos carries Up/Down as ASCII control
        bytes (keyboard.KEY_UP = 0x10), so they go through as plain characters."""
        if not 0 <= ascii_byte <= 0xFF:
            raise KmirError(f"KEY ascii out of range: {ascii_byte}")
        self._rpc_until_accepted(struct.pack("<BB", ascii_byte, named), OP_KEY)

    def inject_text(self, text):
        """Type a whole string on kudos, and do not return until every byte of it
        has been accepted (DIAG-020).

        One key per datagram made a 144-character command line 144 round trips —
        144 chances to lose a byte, each one turning the command into a DIFFERENT
        command rather than a failed one. This sends the line in CHUNK-sized
        pieces and resumes from the count kudos reports, so a full input ring
        costs a retry instead of a corrupt command."""
        data = text.encode() if isinstance(text, str) else bytes(text)
        sent = 0
        deadline = time.time() + BUSY_RETRY_S
        while sent < len(data):
            piece = data[sent:sent + CHUNK]
            body = self._rpc_until_accepted(piece, OP_TEXT)
            if len(body) < 2:
                raise KmirError("TEXT reply carried no count")
            took = struct.unpack_from("<H", body)[0]
            if took == 0:
                # Zero is not a failure — it is the same "no room right now"
                # ERR_BUSY reports for a single key, expressed as a count. Wait
                # for the desktop to drain and ask again.
                if time.time() >= deadline:
                    raise KmirError(
                        f"kudos took 0 more bytes for {BUSY_RETRY_S}s at offset {sent} "
                        f"of {len(data)} — its input ring is not draining"
                    )
                time.sleep(BUSY_PAUSE_S)
                continue
            sent += took
            # The budget measures a STALL, not the whole transfer: a long paste
            # into a slow guest is progress, and must not time out for being big.
            deadline = time.time() + BUSY_RETRY_S
        return sent

    def focus_window(self, needle, timeout_s=2.0):
        """Focus the front-most visible window whose title contains `needle`, and
        return the title that ended up focused (DIAG-021).

        Injected keys go wherever focus happens to be, so every remote typing
        session starts by deciding which window that is. The alternative — click
        the title bar — needs coordinates that change whenever a window moves.

        The desktop applies the change on its own core, so this asks and then
        confirms by re-reading until the title matches or the budget expires."""
        title = self._rpc(needle.encode(), OP_FOCUS).decode("utf-8", "replace")
        deadline = time.time() + timeout_s
        while needle not in title:
            if time.time() >= deadline:
                raise KmirError(
                    f"no window matching '{needle}' took focus within {timeout_s}s "
                    f"(focus is on '{title}')"
                )
            time.sleep(BUSY_PAUSE_S)
            title = self.focused_window()
        return title

    def focused_window(self):
        """The title of the window a keystroke would go to right now (DIAG-022).
        An empty needle is the query form: it reports without changing focus."""
        return self._rpc(b"", OP_FOCUS).decode("utf-8", "replace")

    def inject_mouse(self, dx, dy, buttons):
        """Relative pointer motion + button mask (bit0 L, bit1 R, bit2 M).

        NOTE: kudos runs RELATIVE motion through a pointer-acceleration curve, so the
        cursor does not move by exactly (dx, dy). For test automation that needs the
        pointer somewhere specific, use inject_mouse_abs."""
        self._rpc(struct.pack("<hhB", dx, dy, buttons), OP_MOUSE)

    def inject_mouse_abs(self, x, y, buttons=0):
        """Put the pointer AT (x, y) — absolute, bypassing pointer acceleration.

        This is the same path kudos's USB tablet takes, and it is what a test harness
        wants: a drag written as coordinates must land on those coordinates, not wherever
        an acceleration curve decides."""
        self._rpc(struct.pack("<hhB", x, y, buttons), OP_MOUSE_ABS)

    def trigger_shot(self):
        """Ask kudos to capture a full-res screenshot into its ramdisk (async:
        the ack means 'queued'; completion = screenshot.png generation bump)."""
        self._rpc(b"", OP_SHOT)

    def reboot(self):
        """Reset the machine. kudos ACKs this and resets ~5 s later, so a successful
        return means 'the reboot was accepted', not 'the reboot has finished'.

        The delay is deliberate: the ACK is one UDP datagram, and if it is lost the
        retransmit needs a machine still alive to answer it."""
        self._rpc(b"", OP_REBOOT)

    def shutdown(self):
        """Power the machine OFF (ACK now, poweroff ~5 s later).

        DANGER on a remote rig: a powered-off machine cannot be woken over the
        network — someone has to press the button. Use reboot() to end a run; on
        lemon that lands back in Ubuntu via the one-shot, with nobody in the room."""
        self._rpc(b"", OP_SHUTDOWN)

    def ping(self):
        """Liveness probe. Returns kudos's status line (`build=… up_ms=… ticks=…`).

        This is a REQUEST/RESPONSE pair, and that is the point: a reply proves the
        machine took an interrupt, ran the net stack, and got a frame back out. The
        netdebug stream going quiet is ambiguous (wedge? link down? gated log?); a
        ping that stops answering is not. Compare `ticks` against your own wall
        clock to catch the failure that costs power cycles: a CPU that still runs
        while IRQ0 is dead."""
        return self._rpc(b"", OP_PING).decode("utf-8", "replace")

    def dump_stats(self):
        """Ask kudos to dump every diagnostics counter onto the :9514 trace
        stream (dbg: <mod>.<name> = <v> lines). The ACK comes back here; the
        data arrives on the trace, where the collector is already listening."""
        self._rpc(b"", OP_STATS)

    def dump_ringtail(self, kib=64):
        """Ask kudos to replay the newest `kib` KiB of its in-memory diag ring
        onto the trace stream — the flight-recorder dump (records land in the
        ring even when their module's gate is off)."""
        self._rpc(struct.pack("<H", kib), OP_RINGTAIL)

    def version(self):
        """Which kudos is actually running: `build=N git=<hash> built=<time>`.

        The kernel is fetched over the network at boot, so a stale image served out
        of build/netboot/ is a real failure mode — and one that costs a whole boot to
        discover any other way. Ask the running kernel; it is the only authority."""
        return self._rpc(b"", OP_VERSION).decode("utf-8", "replace")

    def write_file(self, name, data):
        """Create/overwrite one small ramdisk file (whole file ≤ CHUNK bytes
        in a single datagram). Returns the file's new generation."""
        nb = name.encode()
        if len(data) > CHUNK:
            raise KmirError(f"WRITE is single-datagram, <= {CHUNK} B; got {len(data)}")
        r = self._rpc(struct.pack("<H", len(nb)) + nb + data, OP_WRITE)
        (gen,) = struct.unpack_from("<I", r, 0)
        return gen

    def _pull_verified(self, meta, out_dir):
        """Download one listed file, CRC-verify, and atomically place it in
        out_dir. Returns the local path."""
        name = meta["name"]
        for _attempt in range(2):  # one re-pull on a mid-transfer rewrite
            try:
                data = self.read_file(name, meta["generation"], meta["size"])
            except GenerationChanged:
                meta = next((x for x in self.list_files() if x["name"] == name), None)
                if meta is None:
                    raise KmirError(f"{name} vanished from the ramdisk mid-pull")
                continue
            if binascii.crc32(data) & 0xFFFFFFFF != meta["crc32"] or len(data) != meta["size"]:
                raise KmirError(f"{name}: CRC/size mismatch after download")
            partial = os.path.join(out_dir, ".partial")
            os.makedirs(partial, exist_ok=True)
            tmp = os.path.join(partial, name.replace("/", "_"))
            with open(tmp, "wb") as fh:
                fh.write(data)
            local = os.path.join(out_dir, name)
            os.replace(tmp, local)
            return local
        raise KmirError(f"{name}: generation kept moving; gave up after 2 pulls")

    def screenshot(self, out_dir):
        """Full screenshot flow: trigger + wait + download. See screenshot_timed
        for the capture-only duration (the PERF-012 quantity: the download is
        transport, not capture)."""
        path, _ = self.screenshot_timed(out_dir)
        return path

    def screenshot_timed(self, out_dir):
        """Trigger a capture, wait for it to LAND in the ramdisk (generation
        bump on screenshot.png — capture complete), then download + verify.
        Returns (local path, capture seconds). The capture time is trigger to
        generation bump and so overstates by at most one poll interval."""
        os.makedirs(out_dir, exist_ok=True)
        before = next((f["generation"] for f in self.list_files()
                       if f["name"] == "screenshot.png"), None)
        t0 = time.time()
        self.trigger_shot()
        deadline = time.time() + SHOT_TIMEOUT_S
        while True:
            time.sleep(SHOT_POLL_S)
            meta = next((f for f in self.list_files()
                         if f["name"] == "screenshot.png"), None)
            if meta is not None and meta["generation"] != before:
                capture_s = time.time() - t0
                break
            if time.time() > deadline:
                raise KmirError(
                    f"screenshot did not land within {SHOT_TIMEOUT_S:.0f}s "
                    f"(generation stuck at {before}); is the GPU session loop running?")
        return self._pull_verified(meta, out_dir), capture_s
