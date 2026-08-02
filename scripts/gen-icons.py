#!/usr/bin/env python3
# Regenerate src/ui/assets/dock_icons.atlas — the dock's icon coverage atlas,
# baked from the committed Phosphor SVGs (assets/icons/, MIT — see
# LICENSE-phosphor there). Same shape as the font atlas ("KICN" magic, version
# 1, then count fixed W*H 8-bit alpha cells): src/ui/assets/dockicons.zig
# embeds it and expands to luminance-alpha at comptime.
#
# Cells are baked at 2x the on-screen tile glyph size (96 px, drawn at 48) so
# linear sampling keeps the edges crisp — the bitmap never pixellates at the
# size the dock draws it.
#
# ORDER IS ABI: the list below must match dockicons.zig's Icon enum, index for
# index. Add an icon by appending to BOTH, never by reordering.
#
# Requires: python3 + Pillow + rsvg-convert (librsvg2-bin). Run from the repo
# root:  python3 scripts/gen-icons.py
import struct
import subprocess

from PIL import Image

ICONS = [  # (enum name, committed svg)
    ("terminal", "assets/icons/terminal-window-fill.svg"),
    ("system", "assets/icons/gauge-fill.svg"),
    ("clock", "assets/icons/clock-fill.svg"),
    ("calculator", "assets/icons/calculator-fill.svg"),
    ("vm", "assets/icons/cube-fill.svg"),
    ("agent", "assets/icons/robot-fill.svg"),
]
CELL = 96
OUT = "src/ui/assets/dock_icons.atlas"

cells = bytearray()
for name, svg in ICONS:
    png = subprocess.run(
        ["rsvg-convert", "-w", str(CELL), "-h", str(CELL), svg],
        check=True, capture_output=True,
    ).stdout
    import io
    img = Image.open(io.BytesIO(png)).convert("RGBA")
    # Coverage is the alpha channel alone: the dock tints at draw time, so the
    # bake is colour-blind — a black or currentColor path bakes identically.
    cells += img.getchannel("A").tobytes()

hdr = struct.pack("<6I", 0x4B49434E, 1, CELL, CELL, 0, len(ICONS))
open(OUT, "wb").write(bytes(hdr) + bytes(cells))
print(f"icon atlas: cell={CELL}x{CELL} count={len(ICONS)} bytes={len(hdr) + len(cells)} -> {OUT}")
