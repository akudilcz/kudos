#!/usr/bin/env python3
"""Anti-aliasing conformance metric (spec DSK-009).

kudos anti-aliases window chrome ONLY through the GPU's 8x MSAA — the tessellated
rounded-rect body, the traffic-light discs and every angled stroke are rasterised
with coverage the ROP resolves in `f_resolve_msaa8`. The software rasteriser
(`soft.zig`) is deliberately single-sample, so the host render-oracle cannot see
AA: it must be measured on a real GPU frame. This module is that measurement.

Two halves, matching the gate's "cheapest signal first" rule:

  * `edge_aa_score` + the `--selftest` here are PURE and run on the laptop (no
    hardware, no image library): they prove the metric SEPARATES an aliased edge
    from an anti-aliased one, so a broken metric fails loudly in `check-fast`.
  * `boot2_passthrough.py` imports `edge_aa_score`/`AA_MIN_SCORE` and applies them
    to a captured 4090 frame — the actual DSK-009 conformance, on the GPU track.

The score is intermediate / (intermediate + hard_jumps) over a high-contrast edge:
an aliased edge steps straight from background to foreground between adjacent
pixels (all "hard jumps", no partial-coverage pixel between) and scores ~0; an
anti-aliased edge inserts partial-coverage pixels along the transition and scores
well above the floor. A real 4090 traffic-light disc measures ~0.36; the floor is
0.12, comfortably between it and the aliased 0.0.
"""

# The conformance floor: 0.12 sits well clear of both the measured MSAA8 score and
# the aliased 0.0, so hardware/sample-position variation cannot flip the verdict.
AA_MIN_SCORE = 0.12

# Below this background-to-foreground luminance spread a crop has no edge worth
# judging (a blank or same-colour region) — the caller must treat it as "no edge
# here", never as a pass.
MIN_CONTRAST = 40.0

# Fraction of the background..foreground span that walls off the "clearly
# background" and "clearly foreground" bands; the strip between them is partial
# coverage (an anti-aliased pixel).
_BAND = 0.25


def edge_aa_score(gray):
    """Score AA presence along a high-contrast edge in `gray` (a 2-D list of
    luminance rows), in [0, 1]. Returns (score, info); score is None when the crop
    holds no high-contrast edge (spread < MIN_CONTRAST) so the caller fails loud
    rather than reading a meaningless 0. `info` is (bg, fg, span, hard, inter)."""
    h = len(gray)
    w = len(gray[0]) if h else 0
    flat = sorted(v for row in gray for v in row)
    n = len(flat)
    if n == 0:
        return None, (0.0, 0.0, 0.0, 0, 0)
    bg = flat[int(0.05 * n)]
    fg = flat[int(0.95 * n)]
    span = fg - bg
    if span < MIN_CONTRAST:
        return None, (bg, fg, span, 0, 0)
    lo = bg + _BAND * span
    hi = fg - _BAND * span

    # Partial-coverage pixels sitting ON the edge: a mid-luminance pixel touching
    # an extreme (so we count the transition band, not mid-toned interior fill).
    inter = 0
    for j in range(h):
        row = gray[j]
        for i in range(w):
            v = row[i]
            if not (lo < v < hi):
                continue
            touches_extreme = False
            for dj in (-1, 0, 1):
                y = j + dj
                if y < 0 or y >= h:
                    continue
                grow = gray[y]
                for di in (-1, 0, 1):
                    x = i + di
                    if 0 <= x < w and (grow[x] <= lo or grow[x] >= hi):
                        touches_extreme = True
                        break
                if touches_extreme:
                    break
            if touches_extreme:
                inter += 1

    # Hard jumps: adjacent background/foreground pixels with nothing between —
    # what an aliased edge is made entirely of.
    hard = 0
    for j in range(h):
        row = gray[j]
        for i in range(w):
            v = row[i]
            if v <= lo:
                if i + 1 < w and row[i + 1] >= hi:
                    hard += 1
                if j + 1 < h and gray[j + 1][i] >= hi:
                    hard += 1
            elif v >= hi:
                if i + 1 < w and row[i + 1] <= lo:
                    hard += 1
                if j + 1 < h and gray[j + 1][i] <= lo:
                    hard += 1

    denom = inter + hard
    score = 0.0 if denom == 0 else inter / denom
    return score, (bg, fg, span, hard, inter)


def luminance_crop(rgb_image, x0, y0, w, h):
    """A 2-D luminance grid (Rec. 601) from a PIL RGB image over the given box,
    clamped to the image so an edge near a screen border still measures."""
    iw, ih = rgb_image.size
    px = rgb_image.load()
    x0 = max(0, min(x0, iw - 1))
    y0 = max(0, min(y0, ih - 1))
    x1 = max(x0 + 1, min(x0 + w, iw))
    y1 = max(y0 + 1, min(y0 + h, ih))
    grid = []
    for y in range(y0, y1):
        row = []
        for x in range(x0, x1):
            r, g, b = px[x, y][:3]
            row.append(0.299 * r + 0.587 * g + 0.114 * b)
        grid.append(row)
    return grid


# ── host self-test: the metric must separate aliased from anti-aliased ──────────

def _synth_disc(radius, aa, fg=255.0, bg=26.0):
    """A disc rendered hard-edged (aa=False, one sample at the pixel centre) or
    anti-aliased (aa=True, coverage from an 8x8 supersample)."""
    size = 2 * radius + 6
    c = size / 2.0
    S = 8
    grid = []
    for j in range(size):
        row = []
        for i in range(size):
            if aa:
                cov = 0
                for sy in range(S):
                    for sx in range(S):
                        px = i + (sx + 0.5) / S
                        py = j + (sy + 0.5) / S
                        if (px - c) ** 2 + (py - c) ** 2 <= radius * radius:
                            cov += 1
                a = cov / (S * S)
            else:
                a = 1.0 if (i + 0.5 - c) ** 2 + (j + 0.5 - c) ** 2 <= radius * radius else 0.0
            row.append(bg + (fg - bg) * a)
        grid.append(row)
    return grid


def _selftest():
    failures = []
    for r in (5, 7, 12, 20):
        aliased, ai = edge_aa_score(_synth_disc(r, aa=False))
        antialiased, ni = edge_aa_score(_synth_disc(r, aa=True))
        # An aliased edge must score at/near zero — well under the floor.
        if aliased is None or aliased >= AA_MIN_SCORE * 0.5:
            failures.append(f"r={r}: aliased disc scored {aliased} (must be < {AA_MIN_SCORE*0.5})")
        # An anti-aliased edge must clear the conformance floor with margin.
        if antialiased is None or antialiased <= AA_MIN_SCORE:
            failures.append(f"r={r}: antialiased disc scored {antialiased} (must be > {AA_MIN_SCORE})")
        print(f"  r={r:2d}  aliased={aliased:.3f}  antialiased={antialiased:.3f}")
    # A blank, contrast-free crop must report "no edge", never a pass.
    blank, _ = edge_aa_score([[30.0] * 16 for _ in range(16)])
    if blank is not None:
        failures.append(f"blank crop scored {blank} (must be None — no edge)")
    if failures:
        print("aa_metric selftest FAILED:")
        for f in failures:
            print("  -", f)
        return 1
    print(f"aa_metric selftest PASS (floor {AA_MIN_SCORE}: aliased << floor << antialiased)")
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(_selftest())
