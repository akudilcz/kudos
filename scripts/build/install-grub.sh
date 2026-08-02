#!/bin/sh
# Install kudos into the host's GRUB menu, alongside its other OSes, so it can be
# booted from the existing boot menu instead of a USB stick.
#
# Installs BOTH variants as separate menu entries:
#   "kudos (Build N)"      -> single-core image  (/boot/kudos-kernel.elf)
#   "kudos-smp (Build N)"  -> multi-core image   (/boot/kudos-smp-kernel.elf)
#
# Idempotent (re-run after every rebuild) and additive (never edits existing OS
# entries). Run as root: it writes /boot and /etc/grub.d.
#
# Requires both kernels already built (build/bin/{kudos,kudos-smp}): the build
# is done unprivileged by `make boot` first, because root's non-login shell would
# not find `zig` on the user's PATH. Use `make boot`, not this script directly.
#
# Usage: make boot        (builds, then runs this via sudo)
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Build artifacts live under $BUILD_DIR (default build/). The kernels the
# preceding `zig build` produced are in bin/.
BUILD_DIR="${BUILD_DIR:-build}"

# Each variant: <build-artifact name> -> <staged /boot path>. The single source
# of truth for which images exist and where they are installed.
CUSTOM="/etc/grub.d/40_custom"
DEFAULT="/etc/default/grub"

# Build identity of the image we are about to install (read-only — does NOT
# bump; the number was already set by the preceding `zig build`). Used for the
# GRUB menu title and the summary so the menu shows which build it will boot.
# Read-only: BUILD_NUMBER is the single source of truth and was already set by the
# preceding `zig build` (bump-build.sh). Do NOT bump it here — installing an image is
# not building one.
BUILD_NUM="$(cat "$ROOT/BUILD_NUMBER")"
BUILD_HASH="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- must be root -----------------------------------------------------------
if [ "$(id -u)" != "0" ]; then
    echo "install-grub: must run as root — try 'make boot' (which self-elevates)" >&2
    exit 1
fi

# --- locate the grub config generator (Debian vs others) --------------------
# No silent fallback: pick whichever exists, fail loudly if neither does.
if command -v update-grub >/dev/null 2>&1; then
    GEN="update-grub"
elif command -v grub-mkconfig >/dev/null 2>&1; then
    GEN="grub-mkconfig -o /boot/grub/grub.cfg"
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    GEN="grub2-mkconfig -o /boot/grub2/grub.cfg"
else
    echo "install-grub: no grub config generator found (update-grub / grub-mkconfig / grub2-mkconfig)" >&2
    exit 1
fi

# --- stage the (already-built) kernels --------------------------------------
# The build runs unprivileged in `make boot` before this script; never build
# here (root can't find zig on the user's PATH). Fail loudly if either is missing.
for variant in kudos kudos-smp; do
    src="$ROOT/$BUILD_DIR/bin/$variant"
    dst="/boot/$variant-kernel.elf"
    [ -f "$src" ] || {
        echo "install-grub: $src not found — run 'make boot' (which builds first), not this script directly" >&2
        exit 1
    }
    cp "$src" "$dst"
    echo "install-grub: copied $variant -> $dst"
done

# --- stage the GSP firmware into /boot/kudos-fw (same contract as mkiso.sh) --
# Module id strings MUST match src/drivers/gpu/gsp/firmware.zig MODULE_IDS.
# Without these modules the bare-metal boot skips GPU init ("firmware not
# staged") — the desktop then runs on the GRUB/GOP framebuffer only.
GSP_FW_DIR="${GSP_FW_DIR:-/lib/firmware/nvidia/ad102/gsp}"
GSP_MODULES=""
if [ -d "$GSP_FW_DIR" ]; then
    VER="570.144"
    GSP_IMG="$GSP_FW_DIR/gsp-$VER.bin.zst"
    mkdir -p /boot/kudos-fw
    stage_mod() { # <module-id> <src.zst>
        id="$1"; src="$2"
        [ -f "$src" ] || { echo "install-grub: missing GSP blob for '$id': $src" >&2; exit 1; }
        zstd -d -q -f --stdout "$src" > "/boot/kudos-fw/$id.bin"
        GSP_MODULES="$GSP_MODULES    module2 /boot/kudos-fw/$id.bin $id\n"
        echo "  staged $id ($(stat -c%s "/boot/kudos-fw/$id.bin") bytes)"
    }
    echo "install-grub: staging GSP firmware $VER from $GSP_FW_DIR:"
    stage_mod gsp_rm "$GSP_IMG"
    stage_mod booter_load   "$GSP_FW_DIR/booter_load-$VER.bin.zst"
    stage_mod booter_unload "$GSP_FW_DIR/booter_unload-$VER.bin.zst"
    stage_mod bootloader    "$GSP_FW_DIR/bootloader-$VER.bin.zst"
    stage_mod scrubber      "$GSP_FW_DIR/scrubber-$VER.bin.zst"
else
    echo "install-grub: no GSP firmware at $GSP_FW_DIR — entries boot without GPU support" >&2
fi

# --- write the additive menu entries into 40_custom -------------------------
# Back up the pristine file once so removing kudos later restores it cleanly.
[ -f "$CUSTOM.kudos-bak" ] || cp "$CUSTOM" "$CUSTOM.kudos-bak"

# Emit one menuentry for a variant. Titled with the build number so the menu
# shows which image (and which build) it boots. The body is identical between
# variants except the title and the kernel path it locates and loads.
emit_entry() { # <variant>  ->  menuentry block on stdout
    variant="$1"
    printf '\nmenuentry "%s (Build %s)" {\n' "$variant" "$BUILD_NUM"
    printf '    insmod all_video\n'
    printf '    insmod multiboot2\n'
    printf '    insmod part_gpt\n'
    printf '    insmod ext2\n'
    printf '    # Locate whichever partition holds this kudos kernel and make it $root.\n'
    printf '    search --no-floppy --set=root --file /boot/%s-kernel.elf\n' "$variant"
    printf '    # A linear framebuffer is required — the kernel has no text console.\n'
    printf '    set gfxmode=1920x1080x32,1280x1024x32,1024x768x32,auto\n'
    printf '    set gfxpayload=keep\n'
    printf '    multiboot2 /boot/%s-kernel.elf\n' "$variant"
    # GSP firmware modules (empty when no firmware tree was found).
    printf '%b' "$GSP_MODULES"
    printf '    boot\n'
    printf '}\n'
}

# Rebuild 40_custom from its pristine backup + our entries every run, so
# re-running never appends duplicate kudos entries (idempotent).
{
    cat "$CUSTOM.kudos-bak"
    emit_entry "kudos"
    emit_entry "kudos-smp"
} > "$CUSTOM"
chmod 755 "$CUSTOM"
echo "install-grub: wrote \"kudos\" and \"kudos-smp\" (Build $BUILD_NUM) entries to $CUSTOM"

# --- make the menu visible (without changing the default OS) -----------------
# Many installs hide the menu (timeout 0) and boot straight to the first OS; the
# kudos entry is useless if the menu never shows. Back up /etc/default/grub once.
[ -f "$DEFAULT.kudos-bak" ] || cp "$DEFAULT" "$DEFAULT.kudos-bak"
set_default() { # key value: set or append KEY=value in /etc/default/grub
    key="$1"; val="$2"
    if grep -qE "^[#[:space:]]*$key=" "$DEFAULT"; then
        sed -i "s|^[#[:space:]]*$key=.*|$key=$val|" "$DEFAULT"
    else
        printf '%s=%s\n' "$key" "$val" >> "$DEFAULT"
    fi
}
set_default GRUB_TIMEOUT_STYLE menu
set_default GRUB_TIMEOUT 10
echo "install-grub: menu set to show for 10s (GRUB_DEFAULT unchanged)"

# --- regenerate grub.cfg ----------------------------------------------------
echo "install-grub: regenerating grub.cfg ($GEN)…"
$GEN

echo
echo "install-grub: done. Reboot and pick \"kudos\" (single-core) or \"kudos-smp\""
echo "  (multi-core) — both \"(Build $BUILD_NUM)\" — from the GRUB menu."
echo "  build:   #$BUILD_NUM (g$BUILD_HASH)"
echo "  kernels: /boot/kudos-kernel.elf, /boot/kudos-smp-kernel.elf"
echo "  to undo: restore $CUSTOM.kudos-bak and $DEFAULT.kudos-bak,"
echo "           rm /boot/kudos-kernel.elf /boot/kudos-smp-kernel.elf, re-run $GEN"
