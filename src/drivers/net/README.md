# `src/drivers/net/` — the network

Ethernet, IP, and everything kudos does over the wire: a DHCP lease, a DNS lookup, a
ping, an HTTP fetch — and the debug link that makes a headless machine debuggable at all.

There is no serial port on this hardware. The network *is* the console: `debug/` carries
the trace bus out and the remote-control channel in, which is why a machine that fails to
get a lease is a machine you cannot see inside.

## The layout

Three layers, and the dependencies only ever point downward:

```
nic  ←  stack  ←  debug
```

| Layer | Concern |
|---|---|
| `nic/` | The cards. `nic` picks one and hides the difference; `intel` is what the two Intel parts share; `e1000` is what QEMU emulates; `igc` is the I226-V on real hardware. `igc_desc` is the I226's descriptor format as pure code — QEMU never runs igc, so this layer has no emulated coverage and a host test is the only thing standing under it. |
| `stack/` | The protocols. `net` is the hub: it owns the send path and the receive demux. `wire` is the pure packet-parsing half of it — every guard in `classifyIp` stops a panic that any host on the LAN could trigger, so it lives where a test can reach it. Around the hub sit `udp` `tcp` `dhcp` (with its pure `dhcp_wire`) and `config`, which holds the address we were leased. |
| `debug/` | The machine's console, over UDP. `netdebug` streams the trace bus out on 9514. `fileserv` answers requests on 9515 — read a file, inject a keystroke, take a screenshot, reboot — and `fileproto` is that protocol as pure, host-tested code. |

The hub does not know its users. `debug/` claims its port by calling `net.listenUdp`, so
nothing in `stack/` imports anything in `debug/` — a diagnostic tool sitting on top of the
network must not be something the network depends on.

## Why so much of this is pure

`igc.zig` touches MMIO, so it cannot compile on a host, so nothing in it can be tested.
That is exactly where facts about real silicon kept ending up — and then getting
rediscovered on real hardware days later. `wire` `dhcp_wire` `igc_desc` `fileproto` exist
so those facts live somewhere `zig build test` can reach them. See CLAUDE.md, "Tests".
