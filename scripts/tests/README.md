# scripts/tests/ — the kudos integration regression suite

Automated end-to-end tests of the running OS. Readback comes from the
`-Dtest-hooks` instrumentation kudos itself emits, over netdebug (:9514): the
terminal-output mirror (`dbg: term.<core> = …`, terminal.zig `putChar`), the WM
state mirror (`dbg: wm.*`, desktop.zig `emitWmState`: window count, focus,
per-window geometry/maximise, pointer on button edges), and the perf records
(`FLIPSTAT`/`FLIPREC`, present.zig).

**Start with `make check`.** It is the gate — see `check.sh` below and CLAUDE.md
"Verification". Every test target is `make test-*`.

## The gate

| file | role |
|------|------|
| `check.sh` | `make check` — the ITERATION gate and the TEST REGISTER (`build/verified/`): every expensive track records the content digest of the paths it covers when it passes, and only STALE tracks re-run — a green re-run costs seconds. `status` (`make status`) reads the register without running anything; `run <track>` (`make test T=<track>`) runs one track and records it; `--hw` (`make check-hw`) is the FINAL gate: it also REFUSES unless every native track has passed against this exact tree; `--fast` skips the QEMU track; `--stamp NAME` is how a passing run records itself; `FORCE=1` ignores the register. It reports stale hardware evidence without failing on it. |
| `mutcheck.sh` | The mutation gate, one register track PER ROW of `mutations.txt` (`build/verified/mut/`): a row re-runs only when its target, matched test files, or the row itself change. `--only SUBSTR` narrows; `--status` is the register line. |

The stamp is a digest of the WORKING TREE, not the commit — an uncommitted edit to
`xhci.zig` invalidates it too, or the gate would be theatre.

## The tracks

| file | role |
|------|------|
| `cases.py` | THE case table (command, expected substrings, track) + shared record parsers. One line per regression. **Shared by every track**, so a regression cannot pass on one and hide on another. |
| `run_emulated.sh` | `make test-boot-1-qemu`: build `-Dtest-hooks`, bring up a tap + dnsmasq (readback is the network — there is no serial port), boot headless QEMU, drive `boot1_emulated.py`. Single-instance locked. Needs the physical USB stick, so it runs on lemon. |
| `boot1_emulated.py` | Boot-1 driver: 5 phases — devices, every no-GPU command, windows/hotkeys/history, mouse-driven WM (closed-loop via `wm.ptr`), close-recovery. QMP injection (`scripts/debug/qmp.py`). |
| `run_passthrough.sh` | `make test-boot-2-qemu`: REQUIRES a rigged machine (`make rig`). Builds `-Dtest-hooks -Dflip-sample`, captures netdebug, drives passthrough + `boot2_passthrough.py`. Tears down the GUEST only — `make stop` restores the desktop. |
| `boot2_passthrough.py` | Boot-2 driver: GSP bring-up, idle 60 Hz FLIPSTAT, the PERF-002/PERF-014 boot milestones (`bootmark.py`), every command, five models rendering at once (incl. off the USB disk), 60 Hz UNDER LOAD via the `flipstat` re-arm, WM-under-GPU + screenshot artifact, stress thrash. |
| `run_native.sh` | The NATIVE tracks on lemon's bare metal: no flag → `test-boot-1-native`, `--gpu` → `test-boot-2-native`, `--smp` → `test-boot-3-native` (the kudos-smp kernel). Netboots one-shot and **always returns lemon to Ubuntu**, pass or fail. Stamps the tree on success. |
| `boot1_native.py` | Boot-1-native driver — imports `boot1_emulated` and re-points it at KMR1 injection + netdebug readback, so the cases run unchanged. |
| `run_boot3_qemu.sh` | `make test-boot-3-qemu`: the boot-3 smoke twin — kudos-smp on 8 vCPUs, all slirp (KMR1 in via hostfwd, trace out via the loopback), the `-Dverify-script` in-kernel stages gating the boot, then the driver's phases with no GPU asserts. No stick, no lemon. |
| `boot3_native.py` | Boot-3 driver (both machines, `BOOT3_TRACK`): the SMP scheduling stress phases — INSTRUMENTS (every probe the suite leans on is itself asserted; a dead FLIPSTAT/SHOT/KMR1 fails by name), LOAD (placement/oversubscription + tick + rt under load + cadence), GUEST (exactly-once `vm boot`, PERF-017), CHURN (session spaces + TLB shootdowns), WAKE STORM — plus a no-silent-loss counter sweep per phase, one printed seed (`BOOT3_SEED`), and `BOOT3_SOAK_MIN` soak loops. |
| `kmr1_input.py` | The native injector: KMR1 over UDP (:9515), shaped like `qmp.py` so the emulated phases run untouched. Uses `OP_MOUSE_ABS` — kudos ACCELERATES relative motion, so a drag written as coordinates must bypass the curve to land on them. |
| `run_model_sweep.sh` / `model_sweep.py` | `make test-models`: every `.glb`/`.gltf` on the stick through a live 4090 kudos; refuses to run without the six TEST-005 geometry-tier models staged. |
| `cadence.py` | The ONE home for reading + judging a `FLIPSTAT` verdict — the passthrough and native drivers share it so "smooth 60 Hz" means one thing. |
| `bootmark.py` | The ONE home for the boot milestones: the PERF-002 `boot-to-first-present … PASS/OVER` verdict and the PERF-014 async-bind-path check, shared the same way. |
| `schedclock.py` | The ONE home for the scheduler-clock verdicts: the `rt` jitter/drift report (KRN-008) and tick-vs-wall advance from PING status + heartbeat (KRN-012). Self-testing (`make check` runs it). |
| `counters.py` | The ONE home for reading `dbg:` counter records and the no-silent-loss set — any increment across a boot-3 phase is a failure. Self-testing (`make check` runs it). |
| `usbdisk.py` | `make test-usbdisk` / `make usbdisk-provision`. The stick is a TEST FIXTURE — `cases.py` asserts against its contents. Pins them by sha256, read via mtools **without mounting** (a mount makes usb-host passthrough fail with EBUSY). |
| `make-fat-fixtures.sh` | Regenerates `test/drivers/storage/fixtures/fat*.img.gz` for the host FAT tests. |

All artifacts are PERSISTENT (`build/logs/`, not tmpfs): the full runner output plus
one line per assertion, written as they pass — so a crash mid-run shows exactly how
far it got.

## Adding a test

One `Case("cmd", ("expected", …), "both")` line in `cases.py` for command output.
Behavioral tests (windows, timing, mouse) extend the phase functions in the drivers,
asserting against `wm.*` / `FLIPSTAT` records.

If what you learned came from **real silicon** and can be written as a pure function,
it does not belong here at all — put it in the host-tested module and give it a
regression test named for the incident. See CLAUDE.md "Verification".
