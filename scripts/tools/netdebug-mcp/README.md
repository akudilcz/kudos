# netdebug-mcp

The MCP server for the kudos debug channels: it captures
the kudos **netdebug** (UDP broadcast :9514) and speaks the **netdebug RPC**
protocol (UDP :9515, `kmir.py` client) — so an agent pulls traces, downloads
files, injects input, and takes screenshots directly instead of a human
relaying them.

kudos has NO serial port: `src/kernel/debug/klog.zig` is the trace bus, and netdebug
is a sink on it that puts the trace on the LAN as UDP datagrams on port 9514 (framing
owned by `src/drivers/net/debug/netdebug.zig`). Each datagram carries one or more text lines,
each prefixed
`[NNNNNN] ` with a monotonic sequence number, and the first captured line is a
`NETDEBUG-BUILD …` banner tying the trace to a known build.

## How it runs

Registered in the repo's `.mcp.json` as `kudos-netdebug` and launched by
Claude Code on session start via `uv run --script server.py`. The PEP-723
header in `server.py` declares its one dependency (`mcp`), which `uv` resolves
into an ephemeral environment — no global install, no venv to manage. On first
use in a new session Claude Code prompts once to approve the project-scoped
server; after that it auto-starts. After editing/renaming the server, a
running Claude session keeps its old connection — the updated tools appear
after a session restart.

While it runs it is the **sole owner** of UDP :9514 — do not run an integration
suite (`run_emulated.sh` / `run_native.sh` / `run_passthrough.sh`, each of which
starts its own `socat` capture on the same port) at the same time. Whichever binds
second gets `EADDRINUSE` and silently sees nothing.

## Tools

Health / liveness:
- `netdebug_status` — bind state, uptime, total datagrams, current rate,
  seconds since last datagram, sequence-gap/drop counts, and `kudos_streaming`
  (a fresh datagram arrived within the freshness window). Call first.
- `netdebug_ping` — cheap up/down probe: `{alive, listening, has_data}`.
- `netdebug_wait_for_stream` — block until kudos starts streaming (poll after
  a boot).

Trace queries:
- `netdebug_build_banner` — the `NETDEBUG-BUILD` identity (build number, git
  hash, build time) of the captured trace. Confirm which image you're looking at.
- `netdebug_tail` — the most recent N lines.
- `netdebug_grep` — lines matching a regex (e.g. `OVERREAD`, `mirror OFF`, `Xid`).
- `netdebug_frames` — the compositor per-frame `FRAME N nblits=…` dumps,
  grouped, with OVERREAD/exhausted/mirror-OFF lines flagged.
- `netdebug_gaps` — dropped-datagram sequence gaps.
- `netdebug_clear` — reset the buffer before a fresh reproduction.

RPC control (reliable, via `kmir.py` on :9515; guest IP auto-discovered from
the capture or passed as `guest_ip`):
- `netdebug_screenshot` — full-res capture of the live desktop → download →
  local path (default `assets/screenshots/`).
- `netdebug_inject_key` — type ASCII text, exactly-once per character.
- `netdebug_inject_mouse` — relative motion + button mask, exactly-once.

### Control the machine (KMR1 request/response, :9515)
- `netdebug_kudos_status` — kudos's own status line: `build`, `up_ms`, `ticks`,
  `usbdev`, `kbd`, `mouse`, `usbdisk`, and the live HID report counters. A REPLY proves
  the NIC, DHCP, the net stack and interrupts are all alive; compare `ticks` against
  your wall clock to catch a dead IRQ0 on a CPU that is still running.
- `netdebug_kudos_version` — which kudos is actually running: build number, git hash,
  build time. The kernel is fetched over the network at boot, so "is this the image I
  just built" has a real wrong answer.
- `netdebug_kudos_reboot` — reset the machine. ACKs first, acts ~5 s later, so a lost
  ACK still has a live machine to retransmit to.
- `netdebug_kudos_shutdown` — orderly shutdown: kudos tears GSP down (WPR2 destroyed)
  and THEN powers off. **A hard kill with GSP-RM resident wedges the 4090.**
- `netdebug_heartbeat` — drive the bounded 1 Hz PING loop and report the reply rate.

CLI equivalent (no MCP needed): `scripts/debug/netdebug.py {shot,key,mouse}`.

## Test

```
python3 scripts/tools/netdebug-mcp/test_kmir.py   # lossy-loopback protocol test
```
