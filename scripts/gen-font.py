#!/usr/bin/env python3
# Regenerate src/ui/assets/font_roboto.atlas — the MONOSPACE alpha-coverage
# atlas src/ui/screen/font.zig embeds (format: header magic "KFNT" version 1,
# then count fixed W*H 8-bit cells).
#
# Requires: python3 + Pillow. Run from the repo root:
#   python3 scripts/gen-font.py
#
# The cell is derived from Roboto Mono at SIZE (ceil of the monospace advance x
# ascent+descent — 9x19 at SIZE=14, matching the committed header). Glyph
# pixels vary slightly across font rasterizer versions, so a regenerated atlas
# is NOT byte-identical to the committed one: after regenerating, verify the
# desktop text visually (the same bless-and-commit flow as the render goldens).
from math import ceil
import struct

from PIL import Image, ImageFont, ImageDraw

FONT = "src/ui/assets/RobotoMono-Regular.ttf"
SIZE = 14
FIRST, COUNT = 32, 95
OUT = "src/ui/assets/font_roboto.atlas"

font = ImageFont.truetype(FONT, SIZE)
asc, desc = font.getmetrics()
H = asc + desc
W = ceil(font.getlength("M"))  # monospace: every advance is the same
cells = bytearray()
for i in range(COUNT):
    ch = chr(FIRST + i)
    img = Image.new("L", (W, H), 0)
    ImageDraw.Draw(img).text((0, 0), ch, font=font, fill=255)
    cells += img.tobytes()
hdr = struct.pack("<6I", 0x4B464E54, 1, W, H, FIRST, COUNT)
out = bytes(hdr) + bytes(cells)
open(OUT, "wb").write(out)
print(f"mono atlas: cell={W}x{H} count={COUNT} bytes={len(out)} -> {OUT}")
