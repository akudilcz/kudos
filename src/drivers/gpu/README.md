# `src/drivers/gpu/` — the GPU stack

Hosts a discrete NVIDIA GPU (GeForce RTX 4090, Ada Lovelace) under kudos: GSP-RM
firmware boot, channels, copy engine, display, and the present path that puts the
compositor on real panels.

**Status: it works, on real silicon.** GSP-RM boots, the desktop composites and
presents at 3440x1440, and `make test-boot-2-native` drives the whole thing on lemon's
bare metal — 103 assertions, including a steady-60 Hz FLIPSTAT verdict both idle and
under five spinning GL windows. (This file used to say "design only — no code yet",
which stopped being true a long time ago.)

**Scope:** deliberately NOT a conformant OpenGL. The 3D layer (`src/drivers/gl/`) is a
hand-picked slice of the API — enough to clear the screen and draw shaded, textured,
lit triangles — not a Mesa replacement and not a CTS-passing `libGL`.

Code here is grounded in the pinned NVIDIA `open-gpu-kernel-modules` source and its
matching GSP firmware version, cross-checked step by step against nouveau's bring-up
sequence — which is what made the GSP boot tractable at all.

## The layout

Five layers, a strictly downhill dependency chain, and an orchestrator on top:

```
base ← gsp ← core ← display ← present ← gpu.zig
```

| Layer | Concern |
|---|---|
| `base/` | Leaves with no policy: `log` `shim` `mmio` `calc` `nvrm` `gspfw` `gmmu_fmt` `hostpush` `fblayout`. High fan-in — everything above depends on these, and they depend on nothing here. |
| `gsp/` | Boot NVIDIA's signed firmware and speak its RPC: `gsp` `msgq` `falcon` `falconfw` `fwsec` `vbios` `elf` `radix3` `wpr2dump` `firmware` `rm` `top`. |
| `core/` | The card: memory, channels, engines — `vram` `gmmu` `chan` `fifo` `ctxdma` `push` `ce` `msi`. On Ada every channel is allocated *through* a GSP-RM RPC, which is why `core` sits above `gsp`. |
| `display/` | Drive the panels: `disp` `modeset` `dp` `edid`. |
| `present/` | Put the desktop on the screen: `present` `present_real` `mirror_table` `overlay_plane` `tri_ring` `flip_pacing` `flip_stats` `fps_window`. |
| root | `gpu.zig` (the bring-up orchestrator), plus `prof` `screenshot` `usbshot`, which sit *above* present because they consume it. |

Much of this is PURE and host-tested — `calc`, `gmmu_fmt`, `edid`, `modeset`, `dp`,
`overlay_plane`, `flip_stats`, `flip_pacing`, `tri_ring`, `fps_window`, `mirror_table`,
`prof` — because a fact about real silicon that can be a pure function belongs where
`zig build test` reaches it, not in an MMIO-bound file. See CLAUDE.md "Tests".
