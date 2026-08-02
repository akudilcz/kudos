//! The heads-up display's MODEL: what one sample of the machine looks like —
//! the snapshot value, its capacities, and the trace rings — and nothing about
//! how it is drawn. The sampler fills these values; hudview paints them. The
//! public surface stays hudview (`hudview.Snapshot`): callers address the whole
//! HUD through the view module, and this file exists so the value definitions
//! read on their own and the view stays within its budget.

const std = @import("std");
const sampler = @import("sampler");

/// Samples kept per trace: 60 at the sampling period below is the last 30 seconds.
pub const HISTORY: usize = 60;
/// Sampling period, milliseconds. Twice a second satisfies HUD-032 and is slow
/// enough that a sample never shows up inside a frame.
pub const SAMPLE_MS: u64 = 500;
/// Cores the display has room to show individually.
pub const MAX_CORES: usize = 32;
/// Counters the display can show. The registry's own ceiling is 128.
pub const MAX_COUNTERS: usize = 128;
/// Longest task label carried into a snapshot.
pub const TASK_LABEL: usize = 24;
/// Guests the display totals up — the virtualisation subsystem's own ceiling.
pub const MAX_GUESTS: usize = 8;

/// One trace's ring.
pub const Series = sampler.Series(HISTORY);

// ── the snapshot: what one sample of the machine looks like ─────────────────────

/// The columns the counter wall is divided into. The registry's module tags map
/// onto these in the sampler, so the view stays free of kernel types.
pub const Group = enum {
    usb,
    net,
    gpu_ui,
    kernel,

    /// The wall's columns, left to right.
    pub const ALL = [_]Group{ .usb, .net, .gpu_ui, .kernel };

    /// The column heading this group is drawn under.
    pub fn title(self: Group) []const u8 {
        return switch (self) {
            .usb => "USB",
            .net => "NET",
            .gpu_ui => "GPU / UI",
            .kernel => "KERNEL",
        };
    }
};

/// One core's line: how busy it is, and what is on it.
pub const CoreLine = struct {
    online: bool = false,
    is_bsp: bool = false,
    busy_pct: u32 = 0,
    task: [TASK_LABEL]u8 = [_]u8{0} ** TASK_LABEL,
    task_len: u8 = 0,
    activity: [TASK_LABEL]u8 = [_]u8{0} ** TASK_LABEL,
    activity_len: u8 = 0,
    /// Tasks waiting to run on this core (HUD-008).
    runnable: u32 = 0,

    pub fn taskName(self: *const CoreLine) []const u8 {
        return self.task[0..self.task_len];
    }

    pub fn activityName(self: *const CoreLine) []const u8 {
        return self.activity[0..self.activity_len];
    }

    /// Fill the task and activity labels, truncating rather than overrunning.
    pub fn setTask(self: *CoreLine, name: []const u8, activity: []const u8) void {
        const n = @min(name.len, TASK_LABEL);
        @memcpy(self.task[0..n], name[0..n]);
        self.task_len = @intCast(n);
        const a = @min(activity.len, TASK_LABEL);
        @memcpy(self.activity[0..a], activity[0..a]);
        self.activity_len = @intCast(a);
    }
};

/// One diagnostic counter: its total, and how fast it is moving (HUD-019, 020).
pub const CounterLine = struct {
    group: Group = .kernel,
    name: []const u8 = &.{},
    value: u64 = 0,
    per_second: f64 = 0,
};

/// One sample of the machine — the whole input to `draw`.
pub const Snapshot = struct {
    /// Milliseconds since boot at which this sample was taken (HUD-031).
    taken_ms: u64 = 0,
    /// Wall clock, seconds since midnight; null when the clock is unread.
    seconds_since_midnight: ?u64 = null,

    cores_online: u32 = 0,
    cores: [MAX_CORES]CoreLine = [_]CoreLine{.{}} ** MAX_CORES,
    busy_pct: u32 = 0,
    vendor: [12]u8 = [_]u8{' '} ** 12,
    tsc_hz: u64 = 0,

    mem_total: u64 = 0,
    mem_used: u64 = 0,
    heap_arena: u64 = 0,
    heap_used: u64 = 0,
    heap_free: u64 = 0,
    heap_largest: u64 = 0,
    heap_blocks: u64 = 0,
    ramdisk_files: usize = 0,
    ramdisk_bytes: u64 = 0,

    fps: u32 = 0,
    presents: u64 = 0,
    pump_avg_us: u32 = 0,
    pump_max_us: u32 = 0,
    refresh_us: u32 = 0,

    link_up: bool = false,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    tx_dropped: u64 = 0,
    /// Whether anything published a transmit-drop count at all. Absent and zero
    /// are different answers, and the display gives them different words.
    tx_dropped_known: bool = false,
    usb_devices: u8 = 0,
    kbd: bool = false,
    mouse: bool = false,
    usbdisk: bool = false,
    kbd_reports: u64 = 0,
    mouse_reports: u64 = 0,

    vt_available: bool = false,
    guests_running: usize = 0,
    guest_capacity: usize = 0,
    guest_exits: u64 = 0,

    counters: [MAX_COUNTERS]CounterLine = [_]CounterLine{.{}} ** MAX_COUNTERS,
    counter_count: usize = 0,
    /// Fault counters standing above zero — what the alarm reads (HUD-028).
    faults: u32 = 0,
};

/// The four traces, by reference: the view never copies a ring.
pub const Traces = struct {
    frame_ms: *const Series,
    cpu_busy: *const Series,
    heap_free: *const Series,
    net_rx: *const Series,
};

/// State that belongs to the display rather than to the machine.
pub const Options = struct {
    /// Sampling is stopped (HUD-030).
    frozen: bool = false,
    /// An alarm is latched and unacknowledged (HUD-029).
    alarm: bool = false,
    /// Now, so the display can say how old its sample is.
    now_ms: u64 = 0,
};

/// Whether a counter's name says it records something going wrong. A display
/// policy, deliberately: the registry is a neutral list of numbers, and the
/// judgement about which of them are bad belongs to the thing doing the judging.
pub fn isFault(name: []const u8) bool {
    const marks = [_][]const u8{ "drop", "fail", "fault", "orphan", "spurious", "exceeded", "err", "bad" };
    for (marks) |m| {
        if (std.mem.indexOf(u8, name, m) != null) return true;
    }
    return false;
}
