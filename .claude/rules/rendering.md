---
paths:
  - "src/drivers/gl/**"
  - "src/drivers/gpu/**"
  - "src/ui/**"
  - "src/widgets/**"
---

# Rendering: GPU product, soft-display dev builds

GPU-only: the desktop renders on the RTX 4090 through `gles → kgl → idraw` and nowhere else;
with that GPU present the kernel never rasterises the desktop on the CPU (ARCH-015). "Shown"
means the **first present** (PERF-001), at a smooth 60 Hz from that instant. The firmware
framebuffer gives geometry only, no pixels; QEMU runs GPU passthrough. `drivers/gl/soft.zig`
has exactly two consumers — the host-test fixture, and `drivers/gl/softdisplay.zig`, which on
`-Dsoft-display` (off by default, RND-012/013) publishes it when no GPU is coming, its
in-place delivery into the firmware framebuffer being the present. Only `softdisplay.zig` and
`test/` may import `soft`.
