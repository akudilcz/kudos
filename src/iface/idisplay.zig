//! IDisplay — owner of `FrameStats`, the frame/performance counter block the GPU
//! session loop writes each second and `iaccel.frame_stats` exposes. A pure LEAF
//! under src/iface/ — no hardware import, so the kernel and host tests both
//! compile it. There is no display vtable here: the GL desktop draws every pixel
//! through `idraw`, and delivery is `iaccel.Accel.whole_frame_end` / the
//! framebuffer present.

/// Frame/performance counters ("FPS tracking"): written by the present/session
/// loop each second. No on-screen HUD renders them — they are kept as a sampling
/// point a future netdebug emit can read. `seq`==0 = never written.
pub const FrameStats = struct {
    seq: u32 = 0, // bumped on every update; 0 = never written
    fps: u32 = 0, // completed vsynced flips in the last second
    pump_avg_us: u32 = 0,
    pump_max_us: u32 = 0,
    inputs_per_s: u32 = 0, // HID reports (mouse + keyboard) in the last second
};
