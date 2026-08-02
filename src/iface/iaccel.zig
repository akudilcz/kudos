//! IAccel — the seam between the GL desktop (`ui/`) and the GPU present path
//! (`drivers/gpu/`). Neither is allowed to import the other, so both publish here
//! instead: the GPU fills in `accel` once its scanout ring is up, the desktop
//! fills in `compositor` during boot, and each reads the other's struct through
//! this module. That keeps the dependency arrows pointing at `iface/` from both
//! sides rather than sideways between two groups.
//!
//! Every hook is optional, and null always means the same thing: "the other side
//! isn't there — do it yourself, or skip it". A machine with no usable GPU leaves
//! `accel` empty (the desktop then renders on the software draw device and shows
//! frames through the firmware framebuffer); GPU teardown clears `accel` again,
//! so teardown stops new calls into a dying card; a call already in flight for
//! this frame still completes.
//!
//! LEAF module: it imports only pure types, so the kernel and the host tests both
//! compile it. Never add a hardware import here.

const idisplay = @import("idisplay");
const input_latency = @import("input_latency");

/// The window identity a whole-desktop GR frame draws under. The GPU compositor
/// (`ui/desktop`) can render the ENTIRE desktop — wallpaper, every window's chrome and
/// content, the dock — as ONE hardware-OpenGL frame instead of a per-window blit list.
/// That frame is a draw target like any other, but it is not a real window surface, so
/// it carries this reserved base as its identity. The GPU driver keys on it to point the
/// frame's delivery at the scanout ring's compose buffer rather than a per-window mirror.
/// A sentinel far outside any real (identity-mapped) surface address so it can never
/// collide with a window's pixel base. Both groups import it from here; neither owns it.
pub const DESKTOP_WIN_BASE: u64 = 0xFFFF_FFFF_FFFF_F000;

/// What the GPU offers the desktop. The GPU driver publishes this once its
/// scanout ring is up and clears it on teardown.
pub const Accel = struct {
    /// May we start drawing the next frame yet? False while the previous frame is
    /// still waiting to be shown on the monitor. The desktop keeps polling input
    /// while this is false instead of blocking, so the pointer stays responsive.
    /// Null means nothing is pacing us and we may always draw.
    flip_ready: ?*const fn () bool = null,

    /// The primary panel's refresh period in microseconds (0 until the scanout
    /// ring is up). The desktop pump reads it to decide when a frame is too
    /// slow to ALSO wait for the previous flip to latch before starting the
    /// next build — the pipelined-start path that keeps a heavy scene at the
    /// panel rate instead of locking to every second vblank.
    refresh_us: u32 = 0,

    /// Move the hardware mouse cursor. The GPU scans the cursor out as a separate
    /// layer, so when this is installed the desktop draws no cursor of its own and
    /// marks no damage for it — moving the mouse then costs zero redrawn frames.
    /// Null means the cursor is drawn in software, like any other pixels.
    cursor: ?*const fn (x: i32, y: i32) void = null,

    /// Start a fresh measurement of how steadily frames are reaching the monitor, and
    /// report whether one was already running. Only present in builds compiled with
    /// the frame-cadence measurement enabled; null otherwise.
    rearm_flip_sample: ?*const fn () bool = null,

    /// Show a whole-desktop frame the GL desktop already drew and de-tiled into
    /// the scanout ring's compose buffer (see `DESKTOP_WIN_BASE`): pace to vblank,
    /// flip that buffer onto scanout, and rotate the ring. Null when no GPU
    /// present ring is up, which also tells the desktop the ring is not yet ready
    /// to accept a whole frame.
    whole_frame_end: ?*const fn () void = null,
};

/// What the compositor offers a GPU. The compositor publishes this during boot.
pub const Compositor = struct {
    /// Draw exactly one desktop frame: poll input, tick, render. GPU bring-up is
    /// single-threaded and would otherwise starve the desktop loop for its whole
    /// duration, so the GPU calls back into here to keep the screen alive while it
    /// works. `force_full_present` redraws everything unconditionally, which is how
    /// the GPU seeds its buffers before the first real frame.
    pump: ?*const fn (force_full_present: bool) void = null,

    /// Resize the desktop to the monitor's real resolution, once the GPU knows what
    /// that is. Firmware hands us a small safe mode at boot; this raises it.
    set_logical_size: ?*const fn (w: usize, h: usize) void = null,

    /// Poll input + USB WITHOUT rendering or presenting a frame. The GPU bring-up
    /// calls this in a bounded settle after GSP is up but BEFORE the first present,
    /// so a slow device that finishes coming up during GSP boot (a keyboard whose
    /// MCU is still initializing) is enumerated while the desktop is not yet shown —
    /// its blocking bring-up therefore lands before the cadence window opens instead
    /// of dropping a frame inside it. Distinct from `pump`, which renders + presents.
    poll_input: ?*const fn () void = null,
};

/// The accelerator's hooks. Empty until a GPU publishes them; empty again after
/// teardown.
pub var accel: Accel = .{};

/// The compositor's hooks. Empty until the desktop is up.
pub var compositor: Compositor = .{};

/// Frame counters, written once a second by the GPU session loop. Nothing renders
/// them on screen — they are a sampling point for the trace bus. `seq == 0` means no
/// GPU session has ever run.
pub var frame_stats: idisplay.FrameStats = .{};

/// PERF-008 input-latency latch, shared across the seam like `frame_stats`: the
/// compositor's input-sampling pass records the oldest receipt TSC of the input
/// each frame consumed; the GPU present path takes it when that frame's flip is
/// armed and turns the delta into the gpu.input_present_* counters. Both sides
/// run on core 0's session loop, serialized, so the latch needs no lock (see
/// input_latency.Latch).
pub var input_latch: input_latency.Latch = .{};
