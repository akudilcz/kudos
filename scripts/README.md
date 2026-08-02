# scripts/ — grouped by purpose; the path tells you why it exists

Single-purpose scripts, one directory per concern. The Makefile is the
front-end and only delegates here. Sourced identity (`gpu/env.sh`) is the one
definition of the 4090's PCI identity — no other script hardcodes a BDF.

## setup.sh — the bootstrap (the one script at this level)
`make setup`: the pinned Zig 0.16.0 (checksum-verified, into `~/.local/bin`) +
the host tools the build shells out to. It sits ABOVE the concern dirs rather
than inside one because it is what makes them runnable — on a bare machine it is
the only script that works. Idempotent; `--check` verifies without installing.
The dependency table (and the `grub-pc-bin` silent-EFI-only-ISO trap) is in the
top-level README.

## build/ — producing the artifacts
- `bump-build.sh` — build identity: bumps BUILD_NUMBER and prints
  `<number> <githash> <timestamp>` (build.zig runs it at configure time).
- `mkiso.sh <variant>` — stage kernel + `grub/grub.cfg` → `build/<variant>.iso`.
- `install-grub.sh` — install both variants into the host GRUB menu (`make boot`).
- `vendor-tls.py [check|update]` — the kernel's TLS client is the pinned
  toolchain's own `std.crypto.tls.Client`, copied in and patched (std's
  verified-CA path wants a `std.Io`, which a kernel has no business
  implementing). `update` regenerates `src/drivers/net/stack/tlsclient.zig` from
  the toolchain after a Zig upgrade — read the diff, then test. `check` runs in
  the gate: a toolchain that moves the file fails there rather than leaving the
  kernel on an older TLS implementation nobody noticed.

## gpu/ — who owns the 4090, and its health
- `env.sh` — sourced identity (BDF/IDs + `gpu_vfio_group()`).
- `rig.sh` — `make rig`: desktop DOWN, card to vfio — the machine becomes a
  headless test rig (via systemd-run, so it survives killing its own session).
- `restore.sh` — `make stop`: the way back — guest gone, card to nvidia,
  desktop up. Idempotent, safe anytime.
- `bind.sh` / `unbind.sh` — the vfio primitives. bind WAITS until nothing
  holds the GPU device nodes (the async GNOME release after `isolate` — the
  2026-07-11 #2 host hang) and verifies the bind took.
- `health.sh` — check/reset the card in place; `sbr.sh` — last-resort PCIe
  Secondary Bus Reset for a GSP-wedged card.

## vm/ — the guest lifecycle
- `run.sh` — boot a variant in QEMU (`--gui`, `--smp`, `--passthrough`,
  `--no-tail`; `--auto` picks passthrough-over-SSH vs local GUI). EVERY run
  passes the PHYSICAL USB stick through whole (usb-host; identity in
  `gpu/env.sh`) — there is no emulated stick image; the stick must be plugged
  in and gets unmounted from the host automatically.
- `passthrough.sh` — build + run on the real card. Pre-bound mode by default
  (expects `make rig`); `--manage-vfio` owns bind/unbind for manual sessions.
- `kill-qemu.sh` — graceful-then-hard guest stop: KMR1 OP_SHUTDOWN (:9515) → kudos
  raises `shutdown_requested` → the GPU session loop tears GSP down (WPR2 destroyed,
  GSP-RM unloaded) → poweroff. Hard kill ONLY if kudos never answers, because a hard
  kill with GSP-RM resident wedges the 4090. The ONE way to stop kudos; everything
  else calls this.

## netboot/ — lemon, the remote bare-metal target
lemon FETCHES the build from us at boot; nothing is installed on it.
- `mknetboot.sh` — stage `build/netboot/` (kernel + GRUB netboot image).
  `GSP_FW_DIR=` (empty) stages NO firmware — the no-GPU tree.
- `serve.sh {start|stop|status|log}` — the netboot server (TFTP + HTTP out of
  `build/netboot/`). `log` shows the DHCP/TFTP/HTTP conversation: why a netboot did
  or did not happen.
- `lemon.sh {setup|boot|status|recover}` — arm and drive lemon. The boot is armed
  ONE-SHOT, so ANY later reset (panic, self-reboot, power cut) lands back in Ubuntu
  and lemon returns on its own, with nobody in the room.
Backs `make netboot*`, `make lemon-*`, and the native test tracks.

## debug/ — the channels into a running kudos
- `qmp.py` — QMP injection for EMULATED runs (PS/2 keys, relative mouse,
  screendump). Also imported as a module by the boot-1 driver.
- `netdebug.py` — CLI over the KMR1 RPC (:9515): screenshot, key/mouse inject. The
  no-MCP fallback; prefer the netdebug MCP (`scripts/tools/netdebug-mcp/`), which
  does all of this and reads the :9514 trace as well.
- `bootlog.py {pull|seed|read}` — THE FLIGHT RECORDER. kudos mirrors its whole trace
  into `/usbdisk/bootlog.txt`, an 8 MiB ring on the stick appended across boots (~50
  boots of history). Unlike netdebug it needs NO listener and survives a crash, a wedge
  and a power cut — if the machine died before the network came up, or died in a way
  that took the network with it, this is the only record that exists.
  - `pull [--last]` (`make bootlog` / `make bootlog-all`) — read it straight off the
    stick with mtools, NOTHING MOUNTED. `read` needs a mountpoint, and mounting the
    stick is exactly what makes usb-host passthrough fail with EBUSY — so `pull` is the
    one that does not sabotage the next run.
  - `seed <mount> [MiB]` — create/reset the fixed-size ring (once, or to wipe history).

To watch the raw :9514 trace without the MCP: `socat -u udp-recv:9514 -`. Only ONE
process can bind that port — the MCP and a running integration suite contend for it.

## tests/ — the integration regression suite (see tests/README.md)
Every test target is `make test-*`. `make check` is the ITERATION gate (host tests +
QEMU; never reboots lemon); `make check-hw` is the FINAL one.
- `layering.sh` — CLAUDE.md's architecture rules, made executable: a group importing
  sideways, a driver embedding a UI asset, a `.zig` nested too deep, or prose under
  `src/`. Runs first in `check` (no build, no hardware, no excuse). A rule that only
  lives in a document is a rule that comes back.
- `check.sh` — `check` runs the layering gate, the host tests and the QEMU suite, and reports stale
  hardware evidence without failing on it. `--hw` (`make check-hw`) also REFUSES unless
  the native tracks have passed against this exact tree. Each passing native track
  stamps a digest of the source it covers into `build/verified/`, so the gate knows
  what is stale with no cron and no CI. Confidence is built on QEMU; it is CONFIRMED
  on silicon.
- Runners: `run_emulated.sh` (`test-boot-1-qemu`) · `run_passthrough.sh`
  (`test-boot-2-qemu`, needs `make rig`) · `run_native.sh` (`test-boot-1-native`,
  `--gpu` → `test-boot-2-native`) ·
  `run_model_sweep.sh` (`test-models`).
- Drivers: `boot1_emulated.py` · `boot1_native.py` · `boot2_passthrough.py` ·
  `model_sweep.py`. Injection: `qmp.py` (emulated) /
  `kmr1_input.py` (native, KMR1-over-UDP with the same API).
- `cases.py` — THE case table, shared by every track, so a regression cannot pass
  on one and hide on another.
- `usbdisk.py {verify|provision}` (`make test-usbdisk` / `make usbdisk-provision`)
  — the USB stick is a test fixture; this pins it. `make-fat-fixtures.sh`
  regenerates `test/drivers/storage/fixtures/fat*.img.gz` for the host FAT tests.
- All artifacts land in `build/logs/` (persistent — survives a power-cycle).

## tools/ · grub/ · shaders/
- `tools/netdebug-mcp/` — the `kudos-netdebug` MCP server + `kmir.py` (the KMR1
  client library `debug/netdebug.py` also uses).
- `grub/grub.cfg` — the ISO's GRUB template (`@VARIANT@`/`@GSP_MODULES@`).
- `shaders/` — GLSL → SPIR-V → NAK dump factory for `src/drivers/gl/shaders/`.
