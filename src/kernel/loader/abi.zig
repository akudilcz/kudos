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
/// factory refuses a request whose version differs from its checkout. Bump only
/// on a breaking change to `Header`, `Api`, or `FeatureApi` — those structs grow
/// append-only within a version.
pub const ABI_VERSION: u32 = 1;

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

/// Well-known capability interface ids requestable through `Api.get_interface`.
/// The number is the stable identity; each interface carries its own version so
/// a v1 binary keeps working against a kernel that also offers v2. Grows
/// append-only.
pub const Interface = enum(u32) {
    /// A 2D drawing surface for an app that renders its own window.
    draw = 1,
    /// The virtual file system beyond the app's ramdisk sandbox.
    vfs = 2,
    /// The network stack (sockets / fetch).
    net = 3,
    _,
};

/// Ceiling on a `draw` window's dimensions — bounds the compositor-owned surface
/// and its per-frame GPU upload. A larger request is clamped to this.
pub const DRAW_MAX_W: u32 = 1024;
pub const DRAW_MAX_H: u32 = 768;

/// The `Interface.draw` capability vtable, version 1: the surface an app uses to
/// render its OWN window. A binary reaches it via `get_interface(@intFromEnum(
/// Interface.draw), 1)`, and the kernel hands it back ONLY for a windowed launch;
/// a plain terminal app receives null and stays text-only. Windowing is therefore
/// opt-in and gated separately from the base `Api` — a blob that never binds
/// `draw` cannot open a window, and one that does still gets nothing else (no
/// `vfs`, no `net`).
///
/// The app owns no pixels the kernel trusts. It calls `open` once for a window
/// sized w×h (clamped to DRAW_MAX_W/H), then repeatedly fills its OWN BGRA buffer
/// and calls `blit` to COPY it into the window surface the compositor owns; the
/// compositor uploads that surface to the GPU at frame time. `ctx` is the same
/// opaque loader context every `Api` call receives. Fields are append-only — a
/// new call is added at the end, never inserted (the offsets are ABI).
pub const DrawApi = extern struct {
    /// The interface version this vtable implements (`1`).
    version: u32,
    _reserved: u32 = 0,
    /// Open the app's single window at `w`×`h` (clamped to DRAW_MAX_W/H). Returns
    /// a non-zero window handle, or 0 on failure (already open, out of memory, or
    /// no desktop). Idempotent: a second call returns the first window's handle.
    open: *const fn (ctx: *anyopaque, w: u32, h: u32) callconv(.c) u32,
    /// Copy a `w`×`h` block of tightly-packed BGRA pixels into window `handle`'s
    /// surface and mark it dirty for the next composite. A handle that is not this
    /// app's window, or a `w`/`h` beyond the window, is ignored. The pixels are
    /// consumed by the call, so the app may reuse its buffer immediately.
    blit: *const fn (ctx: *anyopaque, handle: u32, pixels: [*]const u32, w: u32, h: u32) callconv(.c) void,
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
