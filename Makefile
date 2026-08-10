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
.PHONY: help setup build iso netboot netboot-serve netboot-stop netboot-log watch \
	lemon start gui boot stop rig clean \
	check check-hw check-fast status test test-unit test-usbdisk test-agent \
	test-boot test-guest-qemu guest-bench test-models shot usbdisk-provision \
	bootlog shaders shaders-setup factory factory-setup

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
# lemon, by verb. `boot` netboots it into the current build one-shot (nothing is
# staged on lemon and the next reset falls back to Ubuntu on its own);
# `heartbeat` netboots the bring-up image instead — net plus a 1 Hz KMR1
# heartbeat, then it reboots itself: the smallest kudos that can prove it is
# alive, and the only thing that tests power.reboot() on this silicon. Start
# `make netboot-serve` first.
lemon: ## lemon: make lemon DO=boot|status|recover|heartbeat|setup
	@case "$(or $(DO),status)" in \
	  boot)      $(MAKE) netboot && scripts/netboot/lemon.sh boot ;; \
	  status)    scripts/netboot/lemon.sh status ;; \
	  recover)   scripts/netboot/lemon.sh recover ;; \
	  setup)     scripts/netboot/lemon.sh setup ;; \
	  heartbeat) zig build -p build --cache-dir build/.zig-cache -Dheartbeat && \
	             GSP_FW_DIR= scripts/netboot/mknetboot.sh $(VARIANT) && \
	             scripts/netboot/lemon.sh boot ;; \
	  *) echo "make lemon DO=boot|status|recover|heartbeat|setup" >&2; exit 2 ;; \
	esac

iso: ## build both bootable ISOs (kudos.iso + kudos-smp.iso)
	zig build iso iso-smp -p build --cache-dir build/.zig-cache

# No `iso` prerequisite on either: each branch of --auto builds the image it needs
# (passthrough.sh builds the GPU image over SSH; run.sh builds the soft-display one
# for the local window), so a prerequisite here would only build a third.
start: ## start kudos: 4090 passthrough over SSH, window locally. SMP=1 · GPU=1 (this box's 4090) · PERF=1 (one 60Hz verdict)
	@if [ -n "$(PERF)" ]; then \
	  zig build iso -Dflip-sample=true -p build --cache-dir build/.zig-cache && \
	  scripts/vm/run.sh --auto --build-opts -Dflip-sample=true; \
	elif [ -n "$(GPU)" ]; then \
	  scripts/vm/passthrough.sh --manage-vfio; \
	else \
	  scripts/vm/run.sh --auto $(if $(SMP),--smp); \
	fi

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

# THE BOOT SUITES, as two coordinates rather than eight targets: WHICH cycle
# (B=1 shell+WM, 2 GPU/desktop, 3 the SMP scheduler stress) and WHERE it runs
# (ON=qemu emulated, smp the 4-vCPU kernel, native lemon's bare metal). The
# combinations that are register tracks run THROUGH the register, so passing
# records evidence; the rest call their runner directly.
#
# QEMU is where confidence is built — boot-1 runs inside lemon's Ubuntu in a VM,
# no netboot and no wear. Native is where it is CONFIRMED: injection is KMR1
# (:9515) and readback is netdebug (:9514), because there is no emulator to ask,
# and every bug that has actually cost a trip to lemon (a DHCP lease thrown away,
# SuperSpeedPlus babble, a bulk TRB straddling 64 KiB) was invisible under QEMU.
# ON=native netboots one-shot and always returns lemon to Ubuntu.
test-boot: ## a boot suite: make test-boot B=1|2|3 ON=qemu|smp|native (default B=1 ON=qemu; B=2 needs `make rig`)
	@B="$(or $(B),1)"; ON="$(or $(ON),qemu)"; \
	case "$$B/$$ON" in \
	  1/qemu)   scripts/tests/check.sh run qemu-boot-1 ;; \
	  1/smp)    KUDOS_SMP=1 scripts/tests/run_emulated.sh ;; \
	  1/native) scripts/tests/check.sh run boot-1-native ;; \
	  2/qemu)   scripts/tests/run_passthrough.sh ;; \
	  2/smp)    KUDOS_SMP=1 scripts/tests/run_passthrough.sh ;; \
	  2/native) scripts/tests/check.sh run boot-2-native ;; \
	  3/qemu)   scripts/tests/run_boot3_qemu.sh ;; \
	  3/native) scripts/tests/check.sh run boot-3-native ;; \
	  *) echo "no such suite: B=$$B ON=$$ON  (B=1|2|3, ON=qemu|smp|native; boot-3 IS the SMP kernel, so it has no smp variant)" >&2; exit 2 ;; \
	esac

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
	  echo "    scripts/virt/build_guest.sh staged"; exit 2; }
	zig build iso -Dtest-hooks -p build --cache-dir build/.zig-cache
	python3 scripts/tests/guest_boot.py

guest-bench: ## how fast is a kudos guest? same workloads native vs QEMU/KVM vs kudos
	zig build iso -Dtest-hooks -p build --cache-dir build/.zig-cache
	python3 scripts/tests/guest_bench.py

test-models: ## sweep every .glb on the stick through a live kudos (real 4090; needs `make rig`)
	scripts/tests/run_model_sweep.sh

shot: ## ONE command: screenshot a model on the 4090 in QEMU passthrough (auto-rigs; MODEL=x.glb optional)
	scripts/tests/shot.sh $(MODEL)

usbdisk-provision: ## write the manifest's files onto the USB stick (mutates it; not a test)
	python3 scripts/tests/usbdisk.py provision

# THE FLIGHT RECORDER. kudos mirrors its whole trace to /usbdisk/bootlog.txt — an 8 MiB
# ring on the USB stick, appended across boots. Unlike netdebug it needs NO listener and
# survives a crash, a wedge, and a power cut: if the machine died before the network came
# up, or died in a way that took the network with it, this is the only record there is.
# Read straight off the stick with mtools — nothing is mounted, so it does not disturb
# the next passthrough run.
bootlog: ## the last boot's kernel trace off the USB stick (ALL=1: every boot in the ring, oldest first)
	python3 scripts/debug/bootlog.py pull $(if $(ALL),,--last)

# BACK TO A FRESH CHECKOUT. Everything generated goes, wherever it landed: the
# build tree and both zig caches, the test register inside build/verified, the
# python bytecode, the transient validator reports, the downloaded screenshots,
# and the staged Linux guest (assets/virt/ — rebuild with scripts/virt/build_guest.sh staged,
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
