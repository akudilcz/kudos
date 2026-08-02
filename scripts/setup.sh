#!/bin/sh
# Provision a fresh machine to build kudos: the pinned Zig toolchain + the host
# tools the build shells out to. Idempotent — safe to re-run; it installs only
# what is missing.
#
# This sits at the ROOT of scripts/ rather than in one of the concern dirs
# (build/, gpu/, vm/, …) because it is the bootstrap that comes BEFORE any of
# them can run: on a bare machine it is the one script you can execute.
#
#   scripts/setup.sh           install what is missing (apt + Zig), then verify
#   scripts/setup.sh --check   verify only; install nothing (exit 1 if incomplete)
#
# Everything here is derived from what the build actually invokes:
#   nasm            build.zig assembles boot.asm / isr.asm / trampoline.asm
#   grub-mkrescue   scripts/build/mkiso.sh, the ISO
#   xorriso+mtools  grub-mkrescue shells out to BOTH; see the grub-pc-bin note
#   zstd            mkiso.sh decompresses the GSP firmware blobs
#   qemu-system-x86 scripts/vm/run.sh, the emulated boot
#   mkfs.vfat       scripts/tests/make-fat-fixtures.sh (dosfstools)
#   python3         the test drivers + debug channel
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# The pinned toolchain (README "Build & run"). Zig is NOT in the Ubuntu archive at
# the version we need, so it comes from ziglang.org and is checksum-verified.
ZIG_VERSION=0.16.0
ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ZIG_PREFIX="$HOME/.local/share/zig-$ZIG_VERSION"
BIN_DIR="$HOME/.local/bin"

# The Khronos glTF Validator — the reference spec-conformance checker the build
# gate runs over every shipped glTF asset (spec TEST-007). Not in the Ubuntu
# archive; a checksum-verified standalone release, installed to ~/.local/bin
# like zig. The tarball holds a single AOT-compiled `gltf_validator` binary.
GLTF_VALIDATOR_VERSION=2.0.0-dev.3.10
GLTF_VALIDATOR_SHA256=168eba887964125abe17ae97899b38d0b3cfd73c266c78424c194929ddcbc522

# Debian/Ubuntu package -> the command it provides. Checking for the COMMAND (not
# `dpkg -l`) keeps this honest: it is the command the build needs, however it got
# installed.
#
# grub-pc-bin earns its own warning. grub-mkrescue silently omits the legacy-BIOS
# El Torito image when the i386-pc platform modules are absent — it prints nothing
# and exits 0, leaving an EFI-only ISO. scripts/vm/run.sh boots via -cdrom through
# SeaBIOS (legacy BIOS), so that ISO fails to boot with no clue as to why. It is
# the one dependency whose absence produces a BROKEN ARTIFACT rather than an error.
#   socat           every integration runner captures netdebug (:9514) with it
#   dnsmasq         run_emulated.sh's tap needs a DHCP server (KMR1 is unicast:
#                   without a lease the guest is unreachable and the suite is blind)
#   mtools          ALSO scripts/tests/usbdisk.py — it reads the USB stick's FAT
#                   directly, because MOUNTING it makes usb-host passthrough EBUSY
#   pciutils        scripts/gpu/env.sh finds the 4090 by device id (lspci)
#   usbutils        run.sh probes for the USB stick by VID:PID (lsusb)
PKGS="make curl nasm xorriso mtools grub-pc-bin grub-efi-amd64-bin qemu-system-x86 zstd dosfstools python3 socat dnsmasq pciutils usbutils"
CMDS="make curl nasm xorriso mformat grub-mkrescue qemu-system-x86_64 zstd mkfs.vfat python3 socat dnsmasq lspci lsusb"

missing_cmds() {
    for c in $CMDS; do
        command -v "$c" >/dev/null 2>&1 || printf '%s ' "$c"
    done
    # grub-pc-bin ships no command of its own — probe the platform dir directly,
    # or the EFI-only-ISO trap above goes undetected.
    [ -d /usr/lib/grub/i386-pc ] || printf 'grub-pc-bin(i386-pc) '
}

# `uv` runs the netdebug MCP server (.mcp.json). server.py declares its own deps
# inline (PEP 723: mcp>=1.2.0), and `uv run --script` is what resolves them — so
# without uv the MCP simply never starts, and CLAUDE.md's "drive live-hardware
# diagnosis through the netdebug MCP" is an instruction to use a tool that is not
# there. It was missing on BOTH machines and nothing said so. Not in the Ubuntu
# archive; installed to ~/.local/bin like zig.
uv_ok() {
    command -v uv >/dev/null 2>&1
}

zig_ok() {
    command -v zig >/dev/null 2>&1 && [ "$(zig version 2>/dev/null)" = "$ZIG_VERSION" ]
}

gltf_validator_ok() {
    command -v gltf_validator >/dev/null 2>&1
}

# ---- host packages ----------------------------------------------------------
if [ -n "$(missing_cmds)" ]; then
    echo "setup: missing host tools: $(missing_cmds)"
    if [ "$CHECK_ONLY" = 1 ]; then
        :
    elif command -v apt-get >/dev/null 2>&1; then
        echo "setup: installing: $PKGS"
        sudo apt-get update -qq
        sudo apt-get install -y $PKGS
    else
        echo "setup: not an apt system — install the equivalents by hand:" >&2
        echo "       $PKGS" >&2
        exit 1
    fi
else
    echo "setup: host tools OK"
fi

# ---- zig --------------------------------------------------------------------
if zig_ok; then
    echo "setup: zig $ZIG_VERSION OK ($(command -v zig))"
elif [ "$CHECK_ONLY" = 1 ]; then
    echo "setup: zig $ZIG_VERSION MISSING (have: $(zig version 2>/dev/null || echo none))"
else
    ARCH="$(uname -m)"
    [ "$ARCH" = "x86_64" ] || { echo "setup: unsupported arch $ARCH (need x86_64)" >&2; exit 1; }

    TARBALL="zig-x86_64-linux-$ZIG_VERSION.tar.xz"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    echo "setup: fetching zig $ZIG_VERSION"
    curl -fsSL -o "$TMP/$TARBALL" "https://ziglang.org/download/$ZIG_VERSION/$TARBALL"

    echo "$ZIG_SHA256  $TMP/$TARBALL" | sha256sum -c - >/dev/null \
        || { echo "setup: zig tarball CHECKSUM MISMATCH — refusing to install" >&2; exit 1; }

    mkdir -p "$HOME/.local/share" "$BIN_DIR"
    tar -xf "$TMP/$TARBALL" -C "$HOME/.local/share"
    rm -rf "$ZIG_PREFIX"
    mv "$HOME/.local/share/zig-x86_64-linux-$ZIG_VERSION" "$ZIG_PREFIX"
    ln -sfn "$ZIG_PREFIX/zig" "$BIN_DIR/zig"
    echo "setup: installed zig $ZIG_VERSION -> $BIN_DIR/zig"
fi

# ---- uv (the netdebug MCP's launcher) ---------------------------------------
if uv_ok; then
    echo "setup: uv OK ($(command -v uv))"
elif [ "$CHECK_ONLY" = 1 ]; then
    echo "setup: uv MISSING — the netdebug MCP cannot start without it"
else
    echo "setup: fetching uv"
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$BIN_DIR" sh
    echo "setup: installed uv -> $BIN_DIR/uv"
fi

# ---- gltf_validator (the glTF spec-conformance gate) ------------------------
if gltf_validator_ok; then
    echo "setup: gltf_validator OK ($(command -v gltf_validator))"
elif [ "$CHECK_ONLY" = 1 ]; then
    echo "setup: gltf_validator MISSING — the glTF asset gate (TEST-007) cannot run"
else
    ARCH="$(uname -m)"
    [ "$ARCH" = "x86_64" ] || { echo "setup: unsupported arch $ARCH for gltf_validator" >&2; exit 1; }
    GV_TARBALL="gltf_validator-$GLTF_VALIDATOR_VERSION-linux64.tar.xz"
    GV_URL="https://github.com/KhronosGroup/glTF-Validator/releases/download/$GLTF_VALIDATOR_VERSION/$GV_TARBALL"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    echo "setup: fetching gltf_validator $GLTF_VALIDATOR_VERSION"
    curl -fsSL -o "$TMP/$GV_TARBALL" "$GV_URL"
    echo "$GLTF_VALIDATOR_SHA256  $TMP/$GV_TARBALL" | sha256sum -c - >/dev/null \
        || { echo "setup: gltf_validator tarball CHECKSUM MISMATCH — refusing to install" >&2; exit 1; }
    mkdir -p "$BIN_DIR"
    tar -xf "$TMP/$GV_TARBALL" -C "$TMP"
    install -m 0755 "$TMP/gltf_validator" "$BIN_DIR/gltf_validator"
    echo "setup: installed gltf_validator $GLTF_VALIDATOR_VERSION -> $BIN_DIR/gltf_validator"
fi

# ---- verify -----------------------------------------------------------------
FAIL=0
[ -n "$(missing_cmds)" ] && { echo "setup: STILL MISSING: $(missing_cmds)" >&2; FAIL=1; }
zig_ok || { echo "setup: zig $ZIG_VERSION not on PATH" >&2; FAIL=1; }
uv_ok || { echo "setup: uv not on PATH — the netdebug MCP will not start" >&2; FAIL=1; }
gltf_validator_ok || { echo "setup: gltf_validator not on PATH — the glTF asset gate (TEST-007) cannot run" >&2; FAIL=1; }

# A zig under ~/.local/bin that is not on PATH is the classic silent failure.
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) [ -x "$BIN_DIR/zig" ] && {
           echo "setup: WARNING — $BIN_DIR is not on your PATH; add it:" >&2
           echo "       export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
           FAIL=1
       } ;;
esac

# Route default-path zig invocations (bare `zig build`, ZLS) into build/:
# the repo-root .zig-cache is a symlink to build/.zig-cache, created here and
# kept alive by `make clean`. Idempotent; replaces a stray real directory.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -L "$ROOT/.zig-cache" ] || rm -rf "$ROOT/.zig-cache"
mkdir -p "$ROOT/build/.zig-cache"
ln -sfn build/.zig-cache "$ROOT/.zig-cache"

[ "$FAIL" = 0 ] || exit 1
echo "setup: ready — 'make build' then 'make iso'"
