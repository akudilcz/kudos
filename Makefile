# Convenience front-end over build.zig + scripts/. Targets only delegate; they
# never reimplement build/run logic. Run `make` (or `make help`) for the list.
#
# The '##' comment after a target is its help text — `make help` scrapes these, so
# the list can never drift from the targets.
#
# EVERY TEST TARGET STARTS WITH `test-`, and the boot suites are named for the boot
# cycle and the machine they run on: test-boot-<N>-<qemu|native>. `make check` is the
# one to run before a branch lands — see scripts/tests/check.sh.

.DEFAULT_GOAL := help
.PHONY: help setup build coverage iso netboot netboot-serve netboot-stop netboot-log watch \
	lemon-setup lemon-boot lemon-heartbeat lemon-status lemon-recover \
	start start-smp start-perf start-gpu gui boot stop rig clean \
	check check-hw check-fast status test test-unit test-usbdisk test-boot-1-qemu test-boot-2-qemu test-guest-qemu \
	test-boot-1-smp-qemu test-boot-2-smp-qemu test-boot-3-qemu \
	test-boot-1-native test-boot-2-native test-boot-3-native test-models shot usbdisk-provision \
	bootlog bootlog-all \
	shaders shaders-setup gltf-validate factory factory-setup test-agent

help: ## show this help
	@echo "kudos — make targets"
	@grep -E '^[a-z][a-zA-Z0-9-]*:.*## ' $(MAKEFILE_LIST) \
		| sed -E 's/^([a-z0-9-]+):.*## /  \1\t/' \
		| expand -t22
	@echo
	@echo "GPU maintenance (run directly, as root):"
	@echo "  scripts/gpu/bind.sh · unbind.sh · health.sh · sbr.sh · scripts/vm/kill-qemu.sh"

# The bootstrap: on a bare machine this is the one target that works, because it
# is what puts `zig` (and nasm/grub/qemu/…) on the PATH the others assume.
setup: ## install the pinned toolchain + host tools (first thing on a fresh machine)
	scripts/setup.sh

# All build/generated artifacts live under build/: zig's install
# prefix (build/bin) and local cache (build/.zig-cache), the ISOs and their
# staging dirs (scripts/build/mkiso.sh via $BUILD_DIR). Nothing generated lands at the
# repo root. The scripts default $BUILD_DIR to `build`, matching -p here.
build: ## compile both kernel variants (kudos + kudos-smp)
	zig build -p build --cache-dir build/.zig-cache

# ── THE SHADER FACTORY ──────────────────────────────────────────────────────────
# kudos has NO shader compiler. Every shader it runs was compiled ahead of time by
# NVIDIA's own compiler — NAK, the backend inside Mesa's NVK — and committed as a blob,
# which is why a clean tree builds and boots with none of this installed.
#
# There is no GPU in this loop either. NVK compiles for Ada against a drm-shim that
# pretends to be one, so a laptop produces the same blobs lemon would.
#
# The compiler lives in a container (scripts/shaders/Dockerfile), pinned by digest. The
# blobs are committed binaries, so the compiler that produced them is part of the source
# and has to be identifiable — and Mesa's NVK needs an LLVM newer than this machine's
# userland can offer regardless. Nothing but docker is installed on the host.
#
# You only need these two targets when a SHADER SOURCE changes. Then: `make shaders`, and
# commit the regenerated blobs alongside the source that produced them.
shaders-setup: ## one-time: build the shader toolchain image (pinned Mesa + NVK, needs docker, ~3 GB)
	scripts/shaders/setup.sh

shaders: ## regenerate the committed SM89 shader blobs from their GLSL (needs shaders-setup)
	scripts/shaders/run.sh

# ── THE COMPILE FACTORY ─────────────────────────────────────────────────────────
# kudos carries NO compiler (spec ARCH-012). The in-kudos agent generates Zig source
# and POSTs it here over the LAN; the factory compiles it off-target into a .kudos
# module the kernel loader verifies before running. Like the shader factory, the
# compiler lives in a digest-pinned container — same zig as scripts/setup.sh pins —
# and the repo is mounted read-only, so the factory has no write path to kudos source.
# Agent-authored module sources persist in the kudos-factory-workspace volume.
factory-setup: ## one-time: build the compile-factory image (pinned zig, needs docker)
	scripts/agent/factory-setup.sh

factory: ## serve the compile factory on :8623 (needs factory-setup; FACTORY_TOKEN gates POSTs)
	scripts/agent/factory-run.sh

# lemon — the remote bare-metal target (scripts/netboot/). lemon FETCHES the build
# from us at boot: its firmware PXE-boots off netboot-serve, so build/netboot/ is
# the only copy and the next reset always runs what is in there. The boot is armed
# ONE-SHOT in firmware (BootNext), so any later reset — panic, self-reboot, power
# cut — falls back to Ubuntu and lemon returns on its own. GSP_FW_DIR= (empty)
# builds the no-firmware tree: the right first boot on new hardware, since the 4090
# is not touched on that path, so it is not left wedged for the next POST.
netboot: build ## stage build/netboot/ (kernel + GRUB netboot image; GSP_FW_DIR= for no firmware)
	scripts/netboot/mknetboot.sh $(VARIANT)

netboot-serve: ## start the netboot server (proxyDHCP + TFTP + HTTP out of build/netboot/)
	scripts/netboot/serve.sh start

netboot-stop: ## stop the netboot server (lemon then cannot boot kudos at all)
	scripts/netboot/serve.sh stop

netboot-log: ## the DHCP/TFTP/HTTP conversation — why a netboot did or did not happen
	scripts/netboot/serve.sh log

# The bring-up image: net + a 1 Hz KMR1 heartbeat, then it reboots itself. No USB,
# no desktop, no GPU — the smallest kudos that can prove it is alive, and the only
# thing that tests power.reboot() on this silicon. GSP_FW_DIR= so the 4090 is never
# touched. Start `make netboot-serve` first.
lemon-heartbeat: ## netboot lemon into the bounded heartbeat image (30 s, then self-reboot)
	zig build -p build --cache-dir build/.zig-cache -Dheartbeat
	GSP_FW_DIR= scripts/netboot/mknetboot.sh $(VARIANT)
	scripts/netboot/lemon.sh boot

lemon-boot: netboot ## netboot lemon into the current build (one-shot; nothing staged on lemon)
	scripts/netboot/lemon.sh boot

lemon-status: ## is lemon running Ubuntu or kudos? what is armed? what are we serving?
	scripts/netboot/lemon.sh status

lemon-recover: ## bring lemon back to Ubuntu now (only works while Linux is up)
	scripts/netboot/lemon.sh recover

lemon-setup: ## once: install lemon's GRUB stub (needed only for the DISK fallback path)
	scripts/netboot/lemon.sh setup

iso: ## build both bootable ISOs (kudos.iso + kudos-smp.iso)
	zig build iso iso-smp -p build --cache-dir build/.zig-cache

# No `iso` prerequisite on either: each branch of --auto builds the image it needs
# (passthrough.sh builds the GPU image over SSH; run.sh builds the soft-display one
# for the local window), so a prerequisite here would only build a third.
start: ## start kudos: 4090 passthrough over SSH, interactive window locally
	scripts/vm/run.sh --auto

start-smp: ## start kudos-smp: same as start but boots the 4-vCPU SMP kernel
	scripts/vm/run.sh --auto --smp

# The GPU run WITHOUT the SSH heuristic, for the one-machine setup: the 4090 in
# this box is the card kudos drives, so the Linux desktop must go down first and
# you cannot be sitting in it. Run it from a text console (Ctrl+Alt+F3) or an SSH
# session; `make stop` gives the desktop back.
start-gpu: ## run kudos on the REAL 4090 in this machine (desktop goes down; make stop restores)
	scripts/vm/passthrough.sh --manage-vfio

start-perf: ## start + measure: one FLIPSTAT 60Hz verdict over netdebug, then run as normal
	zig build iso -Dflip-sample=true -p build --cache-dir build/.zig-cache
	scripts/vm/run.sh --auto --build-opts -Dflip-sample=true

# The window shows the SOFT-DISPLAY image, built here: no GPU reaches a guest except
# by passthrough, and without one a default image publishes no draw device and the
# window stays black. This is the target on a machine with no RTX 4090.
gui: ## the local interactive QEMU window (software rasteriser, 1280x800)
	zig build iso -Dsoft-display -p build --cache-dir build/.zig-cache
	scripts/vm/run.sh --gui

# Bare metal draws on the 4090 and nothing else, so a machine without one boots to
# a black screen unless it is given the software rasteriser: SOFT=1 builds that
# image instead. The kernels are built HERE, unprivileged — root's non-login shell
# would not find zig on your PATH — and only the install runs as root.
boot: ## install both kernels into the host GRUB menu (root; SOFT=1 if this box has no 4090)
	zig build -p build --cache-dir build/.zig-cache $(if $(SOFT),-Dsoft-display)
	sudo scripts/build/install-grub.sh

stop: ## restore the machine: release the 4090, bring the Linux desktop back (root)
	sudo scripts/gpu/restore.sh

rig: ## become a headless test rig: desktop DOWN, 4090 on vfio (run from SSH; undo: make stop)
	scripts/gpu/rig.sh

# ── THE GATE ────────────────────────────────────────────────────────────────────
# `check` is the ITERATION loop and it never reboots lemon: host tests + the QEMU
# suite (which runs inside lemon's Ubuntu, in a VM — no netboot, no reset, no wear).
# It reports stale hardware evidence but does not fail on it.
#
# `check-hw` is the FINAL validation, once there is something worth spending a boot
# on: it also REFUSES unless the native tracks have passed against this exact tree.
# Confidence is built on QEMU; it is CONFIRMED on silicon.
check: ## THE GATE (iterate): runs only what this tree hasn't proven. Does not reboot lemon.
	scripts/tests/check.sh

check-hw: ## THE GATE (final): also requires the native tracks to have passed on this tree
	scripts/tests/check.sh --hw

check-fast: ## host tracks only — skips QEMU too (still register-incremental)
	scripts/tests/check.sh --fast

status: ## the test register: what has passed against THIS tree, what needs a run (~1s)
	@scripts/tests/check.sh status

test: ## run ONE register track and record it: make test T=host:ui (make status lists tracks)
	@[ -n "$(T)" ] || { echo "usage: make test T=<track>   (make status lists the tracks)"; exit 2; }
	scripts/tests/check.sh run $(T)

# ── THE TEST FAMILY ─────────────────────────────────────────────────────────────
# Named for the boot cycle and the machine: test-boot-<N>-<qemu|native>.
test-unit: ## host unit tests; ONLY=<substr> narrows to matching test roots
	zig build test $(if $(ONLY),-Dtest-only=$(ONLY)) -p build --cache-dir build/.zig-cache

coverage: ## host tests under kcov → build/coverage/index.html (full suite, slow; needs kcov)
	scripts/tests/coverage.sh run

# The tightest edit loop: Debug builds ride Zig's self-hosted x86_64 backend and
# incremental compilation, and ONLY=<substr> narrows to the test roots whose
# path contains it. Recompiles land in about a second after the first build.
# CI and `make check` still run the full ReleaseFast suite — Debug here trades
# ReleaseFast-only checks (overflow UB paths) for iteration speed on purpose.
watch: ## rebuild+rerun matching tests on every save: make watch ONLY=hudview
	zig build test --watch -fincremental -Ddebug $(if $(ONLY),-Dtest-only=$(ONLY)) -p build --cache-dir build/.zig-cache

test-usbdisk: ## does the USB stick still match its manifest? (the suites assert against it)
	python3 scripts/tests/usbdisk.py verify

test-agent: ## agent pipeline on the host: factory + loader + full agent loop (needs zig)
	python3 scripts/agent/test_factory.py
	python3 scripts/agent/test_agent.py

test-boot-1-qemu: ## boot-1: shell + WM suite in QEMU (auto-runs on lemon for the stick; NO reboot)
	scripts/tests/run_emulated.sh && scripts/tests/check.sh --stamp qemu-boot-1

# The NESTED track: kudos as a hypervisor, running a Linux guest, inside QEMU.
# The only suite that runs on a developer laptop — no GPU, no USB stick, no lemon
# — because everything it asserts happens below the display: kudos boots, enters
# VMX operation, and the guest's own console comes back over netdebug.
# The guest kernel + initramfs are NOT in the tree (git-ignored, ~2 GiB of build
# to produce): without them the image embeds empty blobs and `vm boot` reports no
# guest staged, which reads as a suite failure rather than a missing input. Say so
# here instead, and name the script that makes them.
test-guest-qemu: ## nested: boot a Linux guest inside kudos under QEMU (laptop-friendly)
	@[ -f assets/virt/bzImage ] && [ -f assets/virt/initramfs.cpio.gz ] || { \
	  echo "no Linux guest staged in assets/virt/ — build it first (a kernel build, ~10 min):"; \
	  echo "    scripts/virt/build_guest.sh"; exit 2; }
	zig build iso -Dtest-hooks -p build --cache-dir build/.zig-cache
	python3 scripts/tests/guest_boot.py

guest-bench: ## how fast is a kudos guest? same workloads native vs QEMU/KVM vs kudos
	zig build iso -Dtest-hooks -p build --cache-dir build/.zig-cache
	python3 scripts/tests/guest_bench.py

test-boot-2-qemu: ## boot-2: the real 4090 under QEMU passthrough; needs `make rig` first
	scripts/tests/run_passthrough.sh

# The SMP variants: the SAME driver + shared cases.py, but booting kudos-smp.iso on 4
# vCPUs. KUDOS_SMP=1 flips the runner to build/boot the multi-core kernel; the driver
# then adds the SMP proofs (APs online, per-core `ps`), the cross-core echo (boot-1),
# and — for free — runs the 60 Hz idle + under-load cadence phases on many cores (boot-2).
test-boot-1-smp-qemu: ## boot-1 on the 4-vCPU SMP kernel: APs online, per-core terminals, cross-core echo (NO reboot)
	KUDOS_SMP=1 scripts/tests/run_emulated.sh

test-boot-2-smp-qemu: ## boot-2 on the SMP kernel: GPU/desktop + 60 Hz idle & under-load on many cores; needs `make rig`
	KUDOS_SMP=1 scripts/tests/run_passthrough.sh

# boot-3 is its own track, not a variant: kudos-smp is the kernel under test and the
# driver (boot3_native.py) stresses the SCHEDULER — placement/oversubscription, deadline
# sleep + tick under load, session churn, guest vCPUs, cadence throughout — with a
# no-silent-loss counter watch per phase. The qemu twin proves the suite's logic (8
# vCPUs, in-kernel -Dverify-script stages first); no GPU asserts and no lemon reboot.
test-boot-3-qemu: ## boot-3 smoke: SMP scheduling stress on QEMU -smp 8 (NO reboot, no GPU asserts)
	scripts/tests/run_boot3_qemu.sh

# The NATIVE tracks: the same cases and assertions, run on lemon's BARE METAL. Injection
# is KMR1 (:9515), readback is netdebug (:9514) — there is no emulator to ask. Every bug
# that has actually cost us a trip to lemon (a DHCP lease thrown away, SuperSpeedPlus
# babble, a bulk TRB straddling 64 KiB) was invisible under QEMU; these are the tracks
# that catch them. Netbooted one-shot — the run always returns lemon to Ubuntu.
test-boot-1-native: ## boot-1 on lemon's bare metal, no GPU firmware
	scripts/tests/run_native.sh

test-boot-2-native: ## boot-2 on lemon's bare metal: GSP + the 4090 running natively
	scripts/tests/run_native.sh --gpu

test-boot-3-native: ## boot-3 on lemon's bare metal: kudos-smp + GSP, the SMP scheduling stress suite
	scripts/tests/run_native.sh --smp

test-models: ## sweep every .glb on the stick through a live kudos (real 4090; needs `make rig`)
	scripts/tests/run_model_sweep.sh

shot: ## ONE command: screenshot a model on the 4090 in QEMU passthrough (auto-rigs; MODEL=x.glb optional)
	scripts/tests/shot.sh $(MODEL)

gltf-validate: ## validate every shipped glTF asset (glbcheck + the required Khronos gltf_validator; spec TEST-007)
	scripts/tests/gltf-validate.sh

usbdisk-provision: ## write the manifest's files onto the USB stick (mutates it; not a test)
	python3 scripts/tests/usbdisk.py provision

# THE FLIGHT RECORDER. kudos mirrors its whole trace to /usbdisk/bootlog.txt — an 8 MiB
# ring on the USB stick, appended across boots. Unlike netdebug it needs NO listener and
# survives a crash, a wedge, and a power cut: if the machine died before the network came
# up, or died in a way that took the network with it, this is the only record there is.
# Read straight off the stick with mtools — nothing is mounted, so it does not disturb
# the next passthrough run.
bootlog: ## the last boot's full kernel trace, off the USB stick (the flight recorder)
	python3 scripts/debug/bootlog.py pull --last

bootlog-all: ## every boot in the ring (~50 boots of history), oldest first
	python3 scripts/debug/bootlog.py pull

# BACK TO A FRESH CHECKOUT. Everything generated goes, wherever it landed: the
# build tree and both zig caches, the test register inside build/verified, the
# python bytecode, the transient validator reports, the downloaded screenshots,
# and the staged Linux guest (assets/virt/ — rebuild with scripts/virt/build_guest.sh,
# a full kernel build, so `make test-guest-qemu` is the one target this costs).
# What it never touches: files git tracks, and local configuration that is not
# generated — .env, .claude/, .vscode/. `make setup` restores the .zig-cache
# symlink; nothing else needs restoring, `make build` rebuilds it all.
clean: ## back to a fresh checkout: every generated artifact, cache and register
	rm -rf build .zig-cache zig-out assets/screenshots
	rm -rf assets/virt/build assets/virt/bzImage assets/virt/initramfs.cpio.gz \
	       assets/virt/ssh/bzImage assets/virt/ssh/initramfs.cpio.gz
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
	@# The glTF validator's per-asset reports. Deleted only where they are
	@# GENERATED — some are committed, and a clean must never remove a file the
	@# checkout would give you back.
	@git ls-files --others --ignored --exclude-standard -- 'assets/**/*.report.json' \
	  | xargs -r rm -f
