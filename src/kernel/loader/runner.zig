//! The `.kudos` loader. Verifies a blob (via `abi.verify`) and lays its code
//! image into caller-provided memory, returning the entry pointer to call.
//!
//! The loader does NOT allocate and does NOT execute — the caller owns both, so
//! the same pure logic serves two very different environments:
//!   - the kernel (`src/console/cmd/run.zig`) hands it a heap block, which is
//!     executable because kudos maps no page non-executable, then builds the
//!     real `Api` and calls the returned entry on the session's own core;
//!   - the host test driver (`scripts/agent/hostload.zig`) hands it an
//!     mmap(PROT_EXEC) region and a libc-backed `Api`.
//! Because it is std-only, this exact placement/verification path is exercised
//! on the host against real factory output.

const std = @import("std");
/// Re-exported so a caller reached through this module (the host driver) shares
/// this module's single `abi` instance — its `Api` type must match the one the
/// entry pointer expects.
pub const abi = @import("abi");

/// Entry signature of an `app` image.
pub const AppEntry = *const fn (api: *const abi.Api) callconv(.c) i32;
/// Entry signature of a `feature` image.
pub const FeatureEntry = *const fn (api: *const abi.FeatureApi) callconv(.c) i32;

pub const LoadError = abi.VerifyError || error{
    /// The image buffer is smaller than the header's `mem_len`.
    ImageTooSmall,
    /// The blob's `kind` is not the one the caller asked to load.
    WrongKind,
};

/// Verify `blob`, require it to be `want`, and place its code image into
/// `image`: copy the `code_len` code bytes to the front and zero the rest of
/// the `mem_len` window (the `.bss` tail). `image` must be executable and at
/// least `mem_len` bytes; extra length beyond `mem_len` is left untouched.
fn place(blob: []const u8, image: []u8, want: abi.Kind) LoadError!*const anyopaque {
    const loadable = try abi.verify(blob);
    if (loadable.kind != want) return error.WrongKind;
    if (image.len < loadable.mem_len) return error.ImageTooSmall;
    @memcpy(image[0..loadable.code.len], loadable.code);
    @memset(image[loadable.code.len..loadable.mem_len], 0);
    return @ptrCast(image.ptr);
}

/// Load an `app` image and return its entry. `image` must be executable memory
/// of at least the blob's `mem_len` bytes.
pub fn loadApp(blob: []const u8, image: []u8) LoadError!AppEntry {
    const entry = try place(blob, image, .app);
    return @ptrFromInt(@intFromPtr(entry));
}

/// Load a `feature` image and return its entry.
pub fn loadFeature(blob: []const u8, image: []u8) LoadError!FeatureEntry {
    const entry = try place(blob, image, .feature);
    return @ptrFromInt(@intFromPtr(entry));
}

/// The memory the loader needs for a blob: its `mem_len`, or a verify error.
/// The kernel uses this to size the executable allocation before `loadApp`.
pub fn imageSize(blob: []const u8) abi.VerifyError!usize {
    const loadable = try abi.verify(blob);
    return loadable.mem_len;
}
