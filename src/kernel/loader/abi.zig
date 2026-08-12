//! The `.kudos` binary application binary interface (ABI).
//!
//! A `.kudos` file is a flat, position-independent code image the agent's host
//! compile factory produces and the kernel loads and runs. This module is the
//! ONE contract shared by all three parties that must agree byte-for-byte:
//!   - the kernel loader (`src/kernel/loader/runner.zig`), which verifies and executes;
//!   - the host factory (`scripts/agent/`), which stamps the header and CRC;
//!   - every generated binary, which is linked against the same `Api` layout.
//! Because the factory and generated code compile it OUTSIDE the kernel, this
//! module imports std and nothing else — it can carry no kudos dependency, which
//! is why the integrity checksum below lives here rather than reusing the
//! ramdisk CRC in `drivers/storage`.
//!
//! File layout: a fixed `Header` followed by `code_len` bytes of code+data. Byte
//! 0 of that image is the entry point. There is no relocation — the factory
//! rejects any relocation section at build time, so the loader only copies,
//! zeroes the trailing `.bss`,
//! and jumps.

const std = @import("std");

/// First four bytes of every `.kudos` file: "KDOS" in a hex dump (the u32 stored
/// little-endian is 0x4b 0x44 0x4f 0x53).
pub const ABI_MAGIC: u32 = 0x534f_444b;

/// The interface version. The kernel refuses a binary whose version differs; the
/// factory refuses a request whose version differs from its checkout. Bump on a
/// breaking change to `Header`, `Api`, `FeatureApi` or a published capability
/// vtable; within a version those structs grow append-only.
pub const ABI_VERSION: u32 = 2;

/// What a `.kudos` binary is, and therefore which entry signature and capability
/// struct it expects. Values are explicit and non-zero so a zeroed blob fails
/// `verify` as `BadKind` rather than defaulting to a real kind.
pub const Kind = enum(u32) {
    /// A sandboxed application: entry `fn (*const Api) callconv(.c) i32`, run
    /// inline on a terminal session's core so its failure is contained.
    app = 1,
    /// A kernel feature: entry `fn (*const FeatureApi) callconv(.c) i32`, which
    /// registers itself with the running kernel (dock tile, command, hook).
    feature = 2,
};

/// The header at byte 0 of every `.kudos` file. All fields are u32 and
/// naturally aligned, so the factory writes it in one pass and the loader reads
/// it without unaligned access.
pub const Header = extern struct {
    /// `ABI_MAGIC`.
    magic: u32,
    /// `ABI_VERSION`.
    version: u32,
    /// A `Kind`.
    kind: u32,
    /// Bytes of the code+data image immediately following this header.
    code_len: u32,
    /// Total image size once loaded, including the zeroed `.bss` tail that is
    /// not stored in the file. Always `>= code_len`.
    mem_len: u32,
    /// CRC-32 of the `code_len` code bytes following the header (this field is
    /// not part of its own input).
    crc32: u32,
};

/// Byte size of `Header` — the offset of the code image within the file.
pub const HEADER_SIZE: usize = @sizeOf(Header);

/// Upper bound on the private arena a running app may draw from through
/// `Api.alloc`. Generated code is told this budget in the system prompt; the
/// loader hands the app one block of at most this size and reclaims it whole
/// when the app returns.
pub const APP_ARENA_MAX_BYTES: usize = 16 << 20;

/// The capability surface passed to an `app` binary. Every field is a function
/// pointer through which the app reaches the kernel, so the binary links to
/// nothing and cannot name a kernel symbol directly. C calling convention and
/// an opaque `ctx` make the layout stable across the factory/kernel boundary.
/// Grows append-only within an `ABI_VERSION`; `version` lets the app confirm
/// what it was given.
pub const Api = extern struct {
    /// `ABI_VERSION` the kernel built this table with.
    version: u32,
    _reserved: u32 = 0,
    /// Opaque loader context passed back as the first argument of every call.
    ctx: *anyopaque,

    /// Write `len` bytes to the app's terminal.
    print: *const fn (ctx: *anyopaque, s: [*]const u8, len: usize) callconv(.c) void,
    /// Pop one pending key for this app, or return -1 when none is waiting.
    poll_key: *const fn (ctx: *anyopaque) callconv(.c) i32,
    /// Milliseconds since boot.
    millis: *const fn (ctx: *anyopaque) callconv(.c) u64,
    /// Sleep about `ms` milliseconds, yielding the core and returning early if
    /// the app has been cancelled.
    sleep_ms: *const fn (ctx: *anyopaque, ms: u64) callconv(.c) void,
    /// Yield the core cooperatively (for compute loops).
    yield: *const fn (ctx: *anyopaque) callconv(.c) void,
    /// True once the app should stop (its window closed or it was cancelled).
    cancelled: *const fn (ctx: *anyopaque) callconv(.c) bool,
    /// A pseudo-random 64-bit value. NOT cryptographic (a plain xorshift for
    /// visuals/gameplay); the kernel's CSPRNG is deliberately not exposed here.
    rand: *const fn (ctx: *anyopaque) callconv(.c) u64,
    /// Allocate `n` bytes aligned to `1 << log2_align` from the app's arena, or
    /// null when the arena is exhausted. There is no free; the arena is released
    /// whole when the app returns.
    alloc: *const fn (ctx: *anyopaque, n: usize, log2_align: u8) callconv(.c) ?[*]u8,
    /// Read a ramdisk file into `out`; returns bytes read, or -1 if not found.
    file_read: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize, out: [*]u8, cap: usize) callconv(.c) isize,
    /// Write a ramdisk file; returns whether it succeeded.
    file_write: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize, data: [*]const u8, len: usize) callconv(.c) bool,

    /// Bind a kudos capability interface by id and minimum version (see
    /// `Interface`). Returns a pointer to that interface's vtable, or null when
    /// the kernel does not publish it at a compatible version. This is how a
    /// binary reaches richer capabilities than the base `Api` without any
    /// symbol linking: it asks for `{id, version}` and the kernel hands back a
    /// versioned vtable, or refuses. New capabilities are added here, never by
    /// growing this struct in the middle (offsets are ABI).
    get_interface: *const fn (ctx: *anyopaque, id: u32, version: u32) callconv(.c) ?*const anyopaque,
};

/// Well-known capability interface ids requestable through `Api.get_interface`
/// (an app) or `FeatureApi.get_interface` (a feature). The number is the stable
/// identity; each interface carries its own version so a v1 binary keeps working
/// against a kernel that also offers v2. Grows append-only.
///
/// An id here is a NAME, not a promise. The kernel publishes a capability only
/// once someone has judged its vtable fit for the kind of module asking, and that
/// judgement lives in ONE place — `src/console/capabilities.zig`, which is also
/// the only file that can widen it. So a module ALWAYS handles null: the same id
/// can be published to a feature and refused to an app, published to a run with a
/// terminal behind it and refused to one without, or refused on a machine that
/// has no desktop to draw on. `caps` at the shell prints what a running kudos
/// publishes right now.
///
/// Each id below names the kudos interface contract (`src/iface/`) it fronts.
/// That mapping is not decoration: those contracts are Zig-typed — slices, error
/// unions, tagged unions — so none of them can cross the C ABI a module binds
/// through. What is published is a narrow C-ABI MIRROR of a contract, never the
/// contract itself, and the mirror is where the bounds and the copies live.
pub const Interface = enum(u32) {
    /// The module's own windows: create, close, blit, size, focus (`WindowApi`).
    window = 1,
    /// The ramdisk as a namespace: dirs, listing, offset reads (`VfsApi`).
    vfs = 2,
    /// HTTP GET, parked and polled (`NetApi`).
    net = 3,
    /// 3D for a window: an ES 1.1 subset the module records and the desktop
    /// replays on the GPU (`GlApi`).
    gl = 4,
    /// Pointer over the module's focused window (`InputApi`). Keys arrive
    /// through `Api.poll_key`.
    input = 5,
    /// Read-only machine figures: frame timing, named counters (`MetricsApi`).
    metrics = 6,
    /// The desktop's windows — anyone's, not just the module's (`DeskApi`).
    desk = 7,
    /// Guest virtual machines (`GuestsApi`).
    guests = 8,
    /// What the machine is running, read-only (`TaskApi`).
    task = 9,
    /// Placing work on the machine and taking it off (`TaskCtlApi`).
    taskctl = 10,
    _,
};

// ── conventions every vtable below keeps ─────────────────────────────────────
//
// - First fields are `version` then `_reserved`; calls are append-only, so a
//   field's offset is ABI.
// - Every call takes the opaque `ctx` the base `Api` carries, first.
// - Strings in: `(ptr, len)`. Strings out: `(ptr, cap) -> isize` = bytes
//   written, or -1 for "no such thing".
// - Handles are `u32`; 0 means none, and a refused create returns it.
// - `bool` answers "did it happen"; `isize` answers "how many", negative for a
//   refusal that needs distinguishing from zero.
// - A capability NEVER blocks on another core. Anything the system core must do
//   is parked and polled (see `NetApi`).

/// Every capability this ABI DEFINES, paired with the vtable a binder gets back.
/// Comptime-only, and the one place an id is tied to its struct — documentation
/// generated from this list (the agent's system prompt, `src/agent/prompt.zig`)
/// therefore cannot drift from what a module actually binds, and a capability
/// added without a vtable fails to compile here rather than shipping undocumented.
///
/// Defined is not published: an `Interface` id may be reserved with no row here
/// yet (its adapter is unwritten), and a row here is still subject to the grant
/// table in `src/console/capabilities.zig`.
pub const CAPABILITIES = [_]struct { id: Interface, version: u32, vtable: type }{
    .{ .id = .window, .version = 1, .vtable = WindowApi },
    .{ .id = .vfs, .version = 1, .vtable = VfsApi },
    .{ .id = .net, .version = 1, .vtable = NetApi },
    .{ .id = .gl, .version = 1, .vtable = GlApi },
    .{ .id = .input, .version = 1, .vtable = InputApi },
    .{ .id = .metrics, .version = 1, .vtable = MetricsApi },
    .{ .id = .desk, .version = 1, .vtable = DeskApi },
    .{ .id = .guests, .version = 1, .vtable = GuestsApi },
    .{ .id = .task, .version = 1, .vtable = TaskApi },
    .{ .id = .taskctl, .version = 1, .vtable = TaskCtlApi },
};

/// Ceiling on a window's content size. A larger request is clamped.
pub const WINDOW_MAX_W: u32 = 1024;
pub const WINDOW_MAX_H: u32 = 768;
/// Windows one module may own at once.
pub const WINDOW_MAX_COUNT: u32 = 4;
/// Longest window title kept.
pub const WINDOW_TITLE_MAX: usize = 48;

/// How a window's content arrives, fixed at create.
pub const WINDOW_PIXELS: u32 = 0;
pub const WINDOW_SCENE: u32 = 1;

/// The `Interface.window` capability vtable, version 1: the module's OWN
/// windows, up to WINDOW_MAX_COUNT of them, addressed by handle.
///
/// The module owns no pixels the kernel trusts: it fills its own BGRA buffer and
/// `blit` COPIES into the compositor's surface, on the module's core. A SCENE
/// window takes no blits — its content is recorded through `GlApi` instead.
/// Closing is a handshake: the user's close box sets `closed`, the module
/// returns, and the desktop tears the window down.
pub const WindowApi = extern struct {
    version: u32,
    _reserved: u32 = 0,
    /// Open a window `w`x`h` (clamped) titled `title`, taking pixels or a
    /// recorded scene. Returns its handle, or 0 (no desktop, or this module
    /// already owns WINDOW_MAX_COUNT).
    create: *const fn (ctx: *anyopaque, title: [*]const u8, title_len: usize, w: u32, h: u32, mode: u32) callconv(.c) u32,
    /// Close a window this module owns.
    close: *const fn (ctx: *anyopaque, handle: u32) callconv(.c) void,
    /// True once the window is gone or going — the render loop's cue to return.
    closed: *const fn (ctx: *anyopaque, handle: u32) callconv(.c) bool,
    /// Current content size, which changes when the user resizes.
    size: *const fn (ctx: *anyopaque, handle: u32, out_w: *u32, out_h: *u32) callconv(.c) bool,
    /// Whether keystrokes are currently going to this window.
    focused: *const fn (ctx: *anyopaque, handle: u32) callconv(.c) bool,
    /// Rename a window.
    retitle: *const fn (ctx: *anyopaque, handle: u32, title: [*]const u8, title_len: usize) callconv(.c) bool,
    /// Copy `w`x`h` tightly-packed BGRA pixels in and mark the window dirty.
    /// Ignored for a scene window or a block bigger than the content.
    blit: *const fn (ctx: *anyopaque, handle: u32, pixels: [*]const u32, w: u32, h: u32) callconv(.c) void,
    /// How many windows this module owns.
    count: *const fn (ctx: *anyopaque) callconv(.c) u32,
    /// The i-th window's handle, or 0 past the end.
    at: *const fn (ctx: *anyopaque, i: u32) callconv(.c) u32,
};

// The `gl` capability's enums, spelled as the OpenGL ES 1.1 spec spells them.
// A module imports nothing, so the values it passes live here; `iface/iscene.zig`
// restates them kernel-side and a test pins the two sets equal.
pub const GL_MODELVIEW: u32 = 0x1700;
pub const GL_PROJECTION: u32 = 0x1701;
pub const GL_TRIANGLES: u32 = 0x0004;
pub const GL_TRIANGLE_STRIP: u32 = 0x0005;
pub const GL_TRIANGLE_FAN: u32 = 0x0006;
pub const GL_LINES: u32 = 0x0001;
pub const GL_DEPTH_TEST: u32 = 0x0B71;
pub const GL_CULL_FACE: u32 = 0x0B44;
pub const GL_LIGHTING: u32 = 0x0B50;
pub const GL_CW: u32 = 0x0900;
pub const GL_CCW: u32 = 0x0901;
pub const GL_LESS: u32 = 0x0201;
pub const GL_LEQUAL: u32 = 0x0203;

/// The `Interface.gl` capability vtable, version 1: 3D for a SCENE window, as an
/// ES 1.1 subset the module records and the desktop replays on the GPU. The
/// module never holds a GL context (it runs on another core, and the context is
/// only valid inside the desktop's frame), so every call copies into kernel
/// staging and is validated before replay: a bad argument costs the frame,
/// counted, never a wild GL call.
///
/// `frame(handle)` starts recording for a window; ops record; `end_frame`
/// publishes and paces the module to the compositor. With GL_LIGHTING enabled
/// the desktop supplies its lamp and `color` sets the material. There is no
/// per-vertex colour — a lit per-vertex-colour draw wedges the 4090.
pub const GlApi = extern struct {
    version: u32,
    _reserved: u32 = 0,
    /// Begin a frame for a scene window; false if the handle is not one of this
    /// module's scene windows.
    frame: *const fn (ctx: *anyopaque, handle: u32) callconv(.c) bool,
    /// GL_DEPTH_TEST, GL_CULL_FACE, GL_LIGHTING.
    enable: *const fn (ctx: *anyopaque, cap: u32) callconv(.c) void,
    disable: *const fn (ctx: *anyopaque, cap: u32) callconv(.c) void,
    /// GL_MODELVIEW or GL_PROJECTION.
    matrix_mode: *const fn (ctx: *anyopaque, mode: u32) callconv(.c) void,
    load_identity: *const fn (ctx: *anyopaque) callconv(.c) void,
    /// 16 floats, column-major, copied by the call.
    load_matrix: *const fn (ctx: *anyopaque, m: *const [16]f32) callconv(.c) void,
    mult_matrix: *const fn (ctx: *anyopaque, m: *const [16]f32) callconv(.c) void,
    /// Degrees, like glRotatef.
    rotate: *const fn (ctx: *anyopaque, angle_deg: f32, x: f32, y: f32, z: f32) callconv(.c) void,
    translate: *const fn (ctx: *anyopaque, x: f32, y: f32, z: f32) callconv(.c) void,
    scale: *const fn (ctx: *anyopaque, x: f32, y: f32, z: f32) callconv(.c) void,
    /// The material colour subsequent draws use.
    color: *const fn (ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
    /// `n` positions (n*3 floats, copied); draws index these until replaced.
    vertices: *const fn (ctx: *anyopaque, xyz: [*]const f32, n: u32) callconv(.c) void,
    /// `n` per-vertex normals (n*3 floats, copied) for lit shading.
    normals: *const fn (ctx: *anyopaque, xyz: [*]const f32, n: u32) callconv(.c) void,
    /// GL_TRIANGLES / _STRIP / _FAN / GL_LINES.
    draw_arrays: *const fn (ctx: *anyopaque, mode: u32, first: u32, count: u32) callconv(.c) void,
    /// `n` u16 indices (copied) into the current vertex data.
    draw_elements: *const fn (ctx: *anyopaque, mode: u32, idx: [*]const u16, n: u32) callconv(.c) void,
    clear_color: *const fn (ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
    depth_func: *const fn (ctx: *anyopaque, func: u32) callconv(.c) void,
    front_face: *const fn (ctx: *anyopaque, mode: u32) callconv(.c) void,
    /// Publish the frame and start the next. Blocks (yielding, bounded) while a
    /// frame ahead of the compositor — this is the pacing.
    end_frame: *const fn (ctx: *anyopaque) callconv(.c) void,
};

/// What `TaskApi.at` fills. Fixed-width fields; the label is its own call, so a
/// name length is not baked into the ABI.
pub const TaskInfo = extern struct {
    /// A TASK_* value.
    state: u32,
    /// Core the task is on.
    core: u32,
    /// Cumulative on-CPU milliseconds.
    cpu_ms: u64,
    /// Whether this is the task currently running on that core.
    current: u32,
    _reserved: u32 = 0,
};

pub const TASK_UNKNOWN: u32 = 0;
pub const TASK_RUNNING: u32 = 1;
pub const TASK_READY: u32 = 2;
pub const TASK_BLOCKED: u32 = 3;
pub const TASK_DONE: u32 = 4;

/// The `Interface.task` capability vtable, version 1: what the machine is
/// running. Read-only, so it is published to every module.
///
/// Rows are addressed by INDEX into a snapshot `count` takes: kudos tasks have no
/// kernel-visible identity, and inventing one here would promise a handle the
/// scheduler does not keep. Call `count`, then `at`/`label` for i < count.
pub const TaskApi = extern struct {
    version: u32,
    _reserved: u32 = 0,
    /// Take a snapshot across the online cores; returns its row count.
    count: *const fn (ctx: *anyopaque) callconv(.c) u32,
    /// Fill `out` for row `i`; false past the end.
    at: *const fn (ctx: *anyopaque, i: u32, out: *TaskInfo) callconv(.c) bool,
    /// Copy row `i`'s name into `out`; -1 past the end.
    label: *const fn (ctx: *anyopaque, i: u32, out: [*]u8, cap: usize) callconv(.c) isize,
    /// The core this module is running on.
    self_core: *const fn (ctx: *anyopaque) callconv(.c) u32,
};

/// The `Interface.taskctl` capability vtable, version 1: put a module on the
/// machine, take it off. Its own id rather than calls on `TaskApi`, so the grant
/// table alone decides who may control (a feature) versus observe (anyone).
pub const TaskCtlApi = extern struct {
    version: u32,
    _reserved: u32 = 0,
    /// Run compiled module `name` detached, with a window grant. Returns a spawn
    /// id for `stop`, or 0 (no free slot, no such module, bad image).
    spawn: *const fn (ctx: *anyopaque, name: [*]const u8, name_len: usize) callconv(.c) u32,
    /// Ask a module this interface spawned to stop. Only those — never the
    /// desktop or another session's work.
    stop: *const fn (ctx: *anyopaque, id: u32) callconv(.c) bool,
};

/// Longest path `VfsApi` accepts, matching the kernel's own path bound.
pub const VFS_PATH_MAX: usize = 64;

/// The `Interface.vfs` capability vtable, version 1: the RAM file system as a
/// NAMESPACE — directories, listing, sized and offset reads — beyond the base
/// `Api`'s flat whole-file `file_read`/`file_write`. Paths are absolute
/// (`/ramdisk/...`) or relative to `/ramdisk`. Deliberately RAMDISK-ONLY: the
/// other mounted stores ride hardware transports owned by the system core, and
/// a module runs on its own — a path outside `/ramdisk` is simply refused.
/// Append-only within a version (the offsets are ABI).
pub const VfsApi = extern struct {
    /// The interface version this vtable implements (`1`).
    version: u32,
    _reserved: u32 = 0,
    /// The file's size in bytes, or -1 when it does not exist.
    size: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize) callconv(.c) i64,
    /// Copy up to `cap` bytes of the file starting at byte `offset` into `out`.
    /// Returns bytes copied (0 at or past the end), or -1 when no such file —
    /// the offset is what lets a module walk a file larger than its buffer.
    read: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize, offset: u32, out: [*]u8, cap: usize) callconv(.c) isize,
    /// Create or replace the file with exactly these bytes.
    write: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize, data: [*]const u8, len: usize) callconv(.c) bool,
    /// Delete a file (never a directory — that is `rmdir`).
    remove: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize) callconv(.c) bool,
    /// Create a directory (parents included, as `write_file` does for files).
    mkdir: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize) callconv(.c) bool,
    /// Delete an EMPTY directory.
    rmdir: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize) callconv(.c) bool,
    /// Write the directory's entries into `out`, one per line, directories
    /// suffixed `/`. Returns the bytes used, or -1 when no such directory.
    /// Truncated at `cap` on a boundary between lines, never mid-name.
    list: *const fn (ctx: *anyopaque, path: [*]const u8, path_len: usize, out: [*]u8, cap: usize) callconv(.c) isize,
};

/// Longest URL `NetApi.fetch_begin` accepts.
pub const NET_URL_MAX: usize = 256;

/// `NetApi.fetch_poll` answers. Values are explicit — they are ABI.
pub const NET_IDLE: u32 = 0;
pub const NET_IN_FLIGHT: u32 = 1;
pub const NET_DONE: u32 = 2;
pub const NET_FAILED: u32 = 3;

/// The `Interface.net` capability vtable, version 1: HTTP GET, asynchronous by
/// construction. A module never touches the network stack — it PARKS a fetch
/// (the system core performs it one bounded step per frame) and polls. The
/// body lands as a ramdisk file the module then reads through the base `Api`
/// or `VfsApi`, so a download of any size crosses no extra boundary. One
/// fetch in flight at a time (the stack holds one connection).
/// Append-only within a version (the offsets are ABI).
pub const NetApi = extern struct {
    /// The interface version this vtable implements (`1`).
    version: u32,
    _reserved: u32 = 0,
    /// Whether the machine is on the network at all (a lease is held). A fetch
    /// begun while offline fails rather than waiting for a cable.
    online: *const fn (ctx: *anyopaque) callconv(.c) bool,
    /// Start fetching `url` (plain http://) into `/ramdisk/<name>`. False when
    /// a fetch is already in flight, the URL or name is over its bound, or the
    /// name is not a plain file name.
    fetch_begin: *const fn (ctx: *anyopaque, url: [*]const u8, url_len: usize, name: [*]const u8, name_len: usize) callconv(.c) bool,
    /// The parked fetch's state: NET_IDLE (none), NET_IN_FLIGHT, NET_DONE (the
    /// file is written), NET_FAILED.
    fetch_poll: *const fn (ctx: *anyopaque) callconv(.c) u32,
    /// Acknowledge a DONE/FAILED result, freeing the slot for the next fetch.
    fetch_end: *const fn (ctx: *anyopaque) callconv(.c) void,
};

/// The `Interface.input` capability vtable, version 1: the pointer, for the
/// module's OWN window while that window has focus. Keystrokes already arrive
/// through the base `Api.poll_key`; this adds where the pointer sits in the
/// window's content rectangle and which buttons are down — sampled state, not
/// an event queue, because a pointer is a position (the newest sample is the
/// truth and stale ones are worthless).
/// Append-only within a version (the offsets are ABI).
pub const InputApi = extern struct {
    version: u32,
    _reserved: u32 = 0,
    /// The pointer's latest position in `handle`'s CONTENT coordinates (origin
    /// its top-left) and button mask (bit 0 left, 1 right, 2 middle). False when
    /// the pointer is elsewhere or that window is unfocused — input follows
    /// focus, always.
    pointer: *const fn (ctx: *anyopaque, handle: u32, out_x: *i32, out_y: *i32, out_buttons: *u8) callconv(.c) bool,
};

/// `DeskApi.window` actions. Values are ABI; they mirror the desktop's own
/// action set (the five things a person does with a title bar and the dock).
pub const DESK_FOCUS: u32 = 1;
pub const DESK_MAXIMISE: u32 = 2;
pub const DESK_MINIMISE: u32 = 3;
pub const DESK_RESTORE: u32 = 4;
pub const DESK_CLOSE: u32 = 5;

/// The `Interface.desk` capability vtable, version 1 — FEATURE modules only:
/// the desktop as the agent's tools see it. A feature extends the running
/// machine (MOD-003) and its commands act for the person invoking them, so it
/// may do what that person's own hands could; an app module is refused this
/// whole interface (its reach ends at its own window).
/// Append-only within a version (the offsets are ABI).
pub const DeskApi = extern struct {
    /// The interface version this vtable implements (`1`).
    version: u32,
    _reserved: u32 = 0,
    /// Ask the desktop for one window action (a DESK_* value) on the window
    /// whose title contains `needle` (empty = the focused window). False when
    /// the action value is unknown or a request is already waiting — the
    /// desktop applies one per input pass.
    window: *const fn (ctx: *anyopaque, action: u32, needle: [*]const u8, needle_len: usize) callconv(.c) bool,
    /// Copy the desktop's window list — one line per window, the same text the
    /// agent's list_windows reads — into `out`. Returns the bytes used.
    windows: *const fn (ctx: *anyopaque, out: [*]u8, cap: usize) callconv(.c) usize,
};

/// `GuestsApi.state` answers — ivirt's guest lifecycle, as ABI values.
pub const GUEST_ABSENT: u32 = 0;
pub const GUEST_FETCHING: u32 = 1;
pub const GUEST_BOOTING: u32 = 2;
pub const GUEST_RUNNING: u32 = 3;
pub const GUEST_HALTED: u32 = 4;
pub const GUEST_FAILED: u32 = 5;

/// The `Interface.guests` capability vtable, version 1 — FEATURE modules only:
/// observe the machine's guest virtual machines and stop one. Deliberately no
/// boot call in v1 — booting needs an image choice, and the shell's `vm`
/// command owns that conversation.
/// Append-only within a version (the offsets are ABI).
pub const GuestsApi = extern struct {
    /// The interface version this vtable implements (`1`).
    version: u32,
    _reserved: u32 = 0,
    /// How many guest slots the machine has (slots, not running guests).
    count: *const fn (ctx: *anyopaque) callconv(.c) u32,
    /// Slot `id`'s lifecycle state as a GUEST_* value; GUEST_ABSENT for a slot
    /// out of range, which needs no extra error shape.
    state: *const fn (ctx: *anyopaque, id: u32) callconv(.c) u32,
    /// Ask the guest in slot `id` to stop (the `vm stop` path). A no-op for an
    /// empty slot.
    request_stop: *const fn (ctx: *anyopaque, id: u32) callconv(.c) void,
};

/// Longest counter name `MetricsApi.counter_name` will report, including the
/// subsystem prefix. Bounds the buffer a module has to offer for one name.
pub const METRICS_NAME_MAX: usize = 48;

/// One frame-timing snapshot, filled by `MetricsApi.frame_stats`. Mirrors the
/// block the present loop keeps (`iface/idisplay.zig`'s `FrameStats`) as fixed-
/// width C-ABI fields, because the contract's own struct is a Zig type a module
/// cannot bind. `seq` is 0 when the machine has never presented a frame — an
/// absent answer, which is not the same as a machine running at 0 fps.
pub const FrameStats = extern struct {
    seq: u32,
    fps: u32,
    pump_avg_us: u32,
    pump_max_us: u32,
    inputs_per_s: u32,
    _reserved: u32 = 0,
};

/// The `Interface.metrics` capability vtable, version 1: what the machine is
/// doing, read-only. Every call is a pure read of state some other subsystem
/// already keeps, so this is the one capability with nothing to bound but its
/// output buffers — which is why it is published to every kind of module.
/// Append-only; a new call goes at the end (the offsets are ABI).
pub const MetricsApi = extern struct {
    /// The interface version this vtable implements (`1`).
    version: u32,
    _reserved: u32 = 0,
    /// Fill `out` with the current frame timing. False when the machine has no
    /// frame statistics at all.
    frame_stats: *const fn (ctx: *anyopaque, out: *FrameStats) callconv(.c) bool,
    /// How many named counters exist right now. The count GROWS as subsystems
    /// register theirs, so an index is only valid against the count that was just
    /// read.
    counter_count: *const fn (ctx: *anyopaque) callconv(.c) u32,
    /// Copy counter `i`'s full `<subsystem>.<name>` key into `out` (up to `cap`,
    /// at most `METRICS_NAME_MAX`) and return its length, or -1 when `i` is past
    /// the end.
    counter_name: *const fn (ctx: *anyopaque, i: u32, out: [*]u8, cap: usize) callconv(.c) isize,
    /// Read the counter with this exact key into `out`. False when no counter has
    /// that name — a missing counter and a counter reading zero are different
    /// answers.
    counter: *const fn (ctx: *anyopaque, name: [*]const u8, name_len: usize, out: *u64) callconv(.c) bool,
};

/// The capability surface passed to a `feature` binary, whose entry is
/// `register`. A feature runs with broader reach than an app: it installs
/// itself into the running kernel and returns. Minimal in this ABI version and
/// grows append-only; feature callbacks run wherever the kernel later invokes
/// them, with full kernel trust.
pub const FeatureApi = extern struct {
    /// `ABI_VERSION` the kernel built this table with.
    version: u32,
    _reserved: u32 = 0,
    /// Opaque loader context passed back as the first argument of every call.
    ctx: *anyopaque,

    /// Emit a diagnostic line to the kernel trace.
    log: *const fn (ctx: *anyopaque, s: [*]const u8, len: usize) callconv(.c) void,
    /// Register a shell command: `name` invokes `run`, which receives the same
    /// opaque `ctx` plus the argument string. Returns whether registration took.
    register_command: *const fn (
        ctx: *anyopaque,
        name: [*]const u8,
        name_len: usize,
        run: *const fn (ctx: *anyopaque, args: [*]const u8, args_len: usize) callconv(.c) void,
    ) callconv(.c) bool,
    /// Bind a capability interface by id and minimum version — the SAME registry
    /// and the same `{id, version}` question an app asks through
    /// `Api.get_interface`, answered against a feature's wider grant. One
    /// mechanism for both kinds of module: the difference in trust is a row in the
    /// grant table, not a second way of reaching the system.
    get_interface: *const fn (ctx: *anyopaque, id: u32, version: u32) callconv(.c) ?*const anyopaque,
};

/// Why a `.kudos` image was rejected. Every case is distinct so the loader and
/// the factory can report exactly which invariant failed rather than a generic
/// "bad binary".
pub const VerifyError = error{
    /// Fewer bytes than a `Header`.
    TooSmall,
    /// `magic` is not `ABI_MAGIC` — not a `.kudos` file.
    BadMagic,
    /// `version` is not `ABI_VERSION`.
    BadVersion,
    /// `kind` is not a known `Kind`.
    BadKind,
    /// `mem_len < code_len`, or the file is shorter than `HEADER_SIZE + code_len`.
    BadLengths,
    /// `crc32` does not match the code bytes.
    BadCrc,
};

/// A verified image, ready for the loader to place in memory. `code` is a slice
/// into the caller's blob (no copy here); the loader allocates `mem_len` bytes,
/// copies `code` to the front, and zeroes the `mem_len - code.len` tail.
pub const Loadable = struct {
    kind: Kind,
    code: []const u8,
    mem_len: usize,
};

/// Validate a `.kudos` blob's header and code CRC without allocating. Pure, so
/// the same check is exercised on the host and used by the kernel loader.
pub fn verify(blob: []const u8) VerifyError!Loadable {
    if (blob.len < HEADER_SIZE) return error.TooSmall;
    const h: Header = .{
        .magic = std.mem.readInt(u32, blob[0..4], .little),
        .version = std.mem.readInt(u32, blob[4..8], .little),
        .kind = std.mem.readInt(u32, blob[8..12], .little),
        .code_len = std.mem.readInt(u32, blob[12..16], .little),
        .mem_len = std.mem.readInt(u32, blob[16..20], .little),
        .crc32 = std.mem.readInt(u32, blob[20..24], .little),
    };
    if (h.magic != ABI_MAGIC) return error.BadMagic;
    if (h.version != ABI_VERSION) return error.BadVersion;
    const kind = std.enums.fromInt(Kind, h.kind) orelse return error.BadKind;
    if (h.mem_len < h.code_len) return error.BadLengths;
    const end = HEADER_SIZE + @as(usize, h.code_len);
    if (blob.len < end) return error.BadLengths;
    const code = blob[HEADER_SIZE..end];
    if (crc32(code) != h.crc32) return error.BadCrc;
    return .{ .kind = kind, .code = code, .mem_len = h.mem_len };
}

/// Serialise a header for `code` in front of it, returning the header bytes.
/// The factory stamps files exactly this way; a host test asserts round-trip
/// against `verify`, and the factory's Python `binascii.crc32` must match
/// `crc32` below.
pub fn writeHeader(out: *[HEADER_SIZE]u8, kind: Kind, code: []const u8, mem_len: usize) void {
    std.debug.assert(mem_len >= code.len);
    std.mem.writeInt(u32, out[0..4], ABI_MAGIC, .little);
    std.mem.writeInt(u32, out[4..8], ABI_VERSION, .little);
    std.mem.writeInt(u32, out[8..12], @intFromEnum(kind), .little);
    std.mem.writeInt(u32, out[12..16], @intCast(code.len), .little);
    std.mem.writeInt(u32, out[16..20], @intCast(mem_len), .little);
    std.mem.writeInt(u32, out[20..24], crc32(code), .little);
}

/// CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) — the `.kudos` code
/// integrity check. Identical to Python's `binascii.crc32`, so the host factory
/// and this loader agree on every byte. Self-contained on purpose: this module
/// carries no kudos import (see the file header).
pub fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFF_FFFF;
    for (data) |b| c = crc_table[(c ^ b) & 0xff] ^ (c >> 8);
    return c ^ 0xFFFF_FFFF;
}

const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        t[i] = c;
    }
    break :blk t;
};
