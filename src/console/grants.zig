//! The capability grant table (MOD-007, MOD-008, MOD-010): which capability a
//! loaded `.kudos` module may bind, at what version, for which kind of run.
//! Pure over the ABI, so the policy is host-tested; `capabilities.zig` holds the
//! vtables and asks this file whether to hand one back.
//!
//! Default is deny: an `abi.Interface` id with no row — including one the ABI
//! reserves but has not implemented — is refused like an unknown id.

const abi = @import("abi");

/// Who is asking. A run KIND, not a trust level: what decides a grant is
/// whether there is a window someone can close, whether anyone is watching, and
/// whether the code is inside the kernel's trust boundary.
pub const Grant = enum {
    /// `run NAME` in a session: a terminal is watching, its window can be closed.
    app_terminal,
    /// The agent's contained run: no terminal, no window of its own.
    app_headless,
    /// A hot-loaded feature (MOD-003) — kernel-trusted code.
    feature,
};

/// One capability's policy. `why` is printed by `caps`.
pub const Row = struct {
    id: abi.Interface,
    /// The exact interface version this row publishes.
    version: u32,
    app_terminal: bool,
    app_headless: bool,
    feature: bool,
    why: []const u8,
};

/// THE PUBLISHED SET. What a module may reach beyond its base `Api`, and by
/// omission what it may not.
pub const TABLE = [_]Row{
    .{
        .id = .window,
        .version = 1,
        .app_terminal = true,
        .app_headless = true,
        .feature = true,
        .why = "the module's own windows, bounded in count and size; its close box ends the run",
    },
    .{
        .id = .gl,
        .version = 1,
        .app_terminal = true,
        .app_headless = true,
        .feature = true,
        .why = "3D into a window the module already owns, replayed on the GPU",
    },
    .{
        .id = .vfs,
        .version = 1,
        .app_terminal = true,
        .app_headless = true,
        .feature = true,
        .why = "the ramdisk as a namespace; other mounts refused — their transports belong to the system core",
    },
    .{
        .id = .net,
        .version = 1,
        .app_terminal = true,
        .app_headless = true,
        .feature = true,
        .why = "parked HTTP GET the system core performs; one in flight, body lands as a ramdisk file",
    },
    .{
        .id = .input,
        .version = 1,
        .app_terminal = true,
        .app_headless = true,
        .feature = true,
        .why = "the pointer over a window the module owns, while it has focus",
    },
    .{
        .id = .metrics,
        .version = 1,
        .app_terminal = true,
        .app_headless = true,
        .feature = true,
        .why = "read-only machine figures; nothing to bound but the caller's buffers",
    },
    .{
        .id = .desk,
        .version = 1,
        .app_terminal = false,
        .app_headless = false,
        .feature = true,
        .why = "window actions and the window list; a feature acts for the person invoking it",
    },
    .{
        .id = .guests,
        .version = 1,
        .app_terminal = false,
        .app_headless = false,
        .feature = true,
        .why = "observe guest VMs and stop one — machine-level control",
    },
    .{
        .id = .task,
        .version = 1,
        .app_terminal = true,
        .app_headless = true,
        .feature = true,
        .why = "reading what the machine runs; copies of fixed fields, no control",
    },
    .{
        .id = .taskctl,
        .version = 1,
        .app_terminal = false,
        .app_headless = false,
        .feature = true,
        .why = "placing work on the machine and taking it off — the person's call to delegate",
    },
};

/// Whether `grant` may bind `{id, version}`.
///
/// The version match is EXACT (MOD-009): a v1 vtable handed to a module that
/// asked for v2 would be called through offsets that do not exist. A kudos
/// publishing both carries a row for each.
pub fn allows(grant: Grant, id: u32, version: u32) bool {
    const row = find(id, version) orelse return false;
    return switch (grant) {
        .app_terminal => row.app_terminal,
        .app_headless => row.app_headless,
        .feature => row.feature,
    };
}

/// The row for `{id, version}`, or null when nothing publishes it.
pub fn find(id: u32, version: u32) ?Row {
    for (TABLE) |row| {
        if (@intFromEnum(row.id) == id and row.version == version) return row;
    }
    return null;
}
