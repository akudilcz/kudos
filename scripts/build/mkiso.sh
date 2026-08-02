#!/bin/sh
# Stage a kernel variant + grub.cfg into an ISO tree and build <variant>.iso.
# Usage: scripts/build/mkiso.sh <variant>          (variant = kudos | kudos-smp)
# ALL build/generated artifacts live under $BUILD_DIR (default `build/`): the kernel is $BUILD_DIR/bin/<variant> (zig's install
# prefix is set to $BUILD_DIR), staged as /boot/kernel.elf inside the ISO, and the
# ISO + its staging dir are written under $BUILD_DIR too. The GRUB menu entry is
# titled after the variant so the two images are distinguishable.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Single build-output root. Overridable, but every caller uses the default so the
# tree stays clean. Kept in sync with the Makefile's -p prefix.
BUILD_DIR="${BUILD_DIR:-build}"

VARIANT="${1:?usage: mkiso.sh <variant>  (kudos | kudos-smp)}"
KERNEL="$BUILD_DIR/bin/$VARIANT"
[ -f "$KERNEL" ] || { echo "mkiso: kernel $KERNEL not found (run zig build first)" >&2; exit 1; }

ISODIR="$BUILD_DIR/isodir-$VARIANT"
rm -rf "$ISODIR"
mkdir -p "$ISODIR/boot/grub"
cp "$KERNEL" "$ISODIR/boot/kernel.elf"

# GSP firmware staging. Decompress the
# nouveau GSP blobs into the ISO and emit a `module2` line per blob; the module id
# strings MUST match src/drivers/gpu/gsp/firmware.zig MODULE_IDS (single source of truth for
# the contract).
#
# GSP_FW_DIR selects the firmware tree. When unset we auto-detect the canonical
# host location (/lib/firmware/nvidia/ad102/gsp — a documented system boundary, so
# a default here is deliberate, not a silent fallback): if that dir exists the iso
# is built WITH firmware "out of the box"; if it does not, no modules are staged
# and `gpu` stops at the honest "ready for GSP firmware" path (no fake-firmware).
# Set GSP_FW_DIR="" explicitly to force the no-firmware build.
GSP_MODULES=""
if [ -z "${GSP_FW_DIR+set}" ]; then
    # GSP_FW_DIR is UNSET (not just empty) -> auto-detect the host firmware tree.
    if [ -d /lib/firmware/nvidia/ad102/gsp ]; then
        GSP_FW_DIR=/lib/firmware/nvidia/ad102/gsp
        echo "mkiso: auto-detected GSP firmware at $GSP_FW_DIR (set GSP_FW_DIR= to disable)"
    fi
fi
if [ -n "$GSP_FW_DIR" ]; then
    [ -d "$GSP_FW_DIR" ] || { echo "mkiso: GSP_FW_DIR '$GSP_FW_DIR' is not a directory" >&2; exit 1; }
    command -v zstd >/dev/null 2>&1 || { echo "mkiso: zstd required to decompress GSP firmware" >&2; exit 1; }
    VER="${GSP_FW_VER:-570.144}"
    mkdir -p "$ISODIR/boot/fw"
    # id  ->  source filename (relative to GSP_FW_DIR). The gsp image lives in the
    # ga102 tree (ad102 symlinks to it); GSP_FW_GSP overrides the gsp image path.
    GSP_IMG="${GSP_FW_GSP:-$GSP_FW_DIR/gsp-$VER.bin.zst}"
    stage_mod() {
        id="$1"; src="$2"
        [ -f "$src" ] || { echo "mkiso: missing GSP blob for '$id': $src" >&2; exit 1; }
        zstd -d -q -f --stdout "$src" > "$ISODIR/boot/fw/$id.bin"
        GSP_MODULES="$GSP_MODULES    module2 /boot/fw/$id.bin $id
"
        echo "  staged $id ($(stat -c%s "$ISODIR/boot/fw/$id.bin") bytes)"
    }
    echo "Staging GSP firmware $VER from $GSP_FW_DIR:"
    stage_mod gsp_rm "$GSP_IMG"
    stage_mod booter_load   "$GSP_FW_DIR/booter_load-$VER.bin.zst"
    stage_mod booter_unload "$GSP_FW_DIR/booter_unload-$VER.bin.zst"
    stage_mod bootloader    "$GSP_FW_DIR/bootloader-$VER.bin.zst"
    stage_mod scrubber      "$GSP_FW_DIR/scrubber-$VER.bin.zst"
fi

# Generate grub.cfg from the committed template, substituting the menu title so
# the entry names the variant, and the GSP module lines (empty unless staged).
# The framebuffer mode is set by the multiboot2 header tag in src/kernel/boot/boot.asm, not
# by gfxmode (see scripts/grub/grub.cfg).
# Substitute @GSP_MODULES@ ONLY when it is the whole placeholder line (^\s*@GSP_MODULES@\s*$)
# — NOT when the token appears inside prose (the template's own comment mentions it,
# and matching that comment would inject `module2` lines at GRUB global scope, before
# any multiboot2 → "you need to load the kernel first"). @VARIANT@ is safe to gsub
# everywhere (it only appears in the menu title + a comment, both harmless).
awk -v variant="$VARIANT" -v mods="$GSP_MODULES" '
    { gsub(/@VARIANT@/, variant) }
    /^[[:space:]]*@GSP_MODULES@[[:space:]]*$/ { printf "%s", mods; next }
    { print }
' scripts/grub/grub.cfg > "$ISODIR/boot/grub/grub.cfg"

grub-mkrescue -o "$BUILD_DIR/$VARIANT.iso" "$ISODIR" >/dev/null 2>&1
echo "Built $ROOT/$BUILD_DIR/$VARIANT.iso"
