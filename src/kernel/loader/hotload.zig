//! Hot-load core for feature `.kudos` images (spec AGT-010): verify + place a
//! feature blob, call its `register`, and dispatch the commands it registered —
//! with all output routed through an injected `Sink`.
//!
//! The sink is a real seam: the same load/dispatch path serves a human typing
//! at a terminal (output to that terminal) and the agent loading what it just
//! compiled (output captured into the tool result it will read). Neither target
//! may know the other, and a feature callback must never write to an output
//! that has since gone away — so the CURRENT sink is tracked here for exactly
//! the duration of one `register` or one command dispatch, the invoker always
//! being live for its own call.
//!
//! Like `runner.zig`, this module allocates nothing and is std-only, so the
//! host rigs (`scripts/agent/hostload.zig`, `hostagent.zig`) execute this exact
//! code against real factory output — the kernel path is exercised on a laptop.

const std = @import("std");
pub const runner = @import("runner.zig");
pub const features = @import("features.zig");
pub const abi = runner.abi;

/// Where feature output goes for the duration of one call. Same shape as the
/// agent loop's `Sink` on purpose: a terminal write and a capture-buffer append
/// are the two implementations.
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, text: []const u8) void,
};

// A stable context handed to feature-registered command callbacks. Feature code
// keeps its own state in its image; this is just a non-null placeholder.
var feat_run_ctx: u8 = 0;

// The sink feature output goes to RIGHT NOW: set around `register` and around
// each command dispatch, restored after.
var cur_sink: ?Sink = null;

fn featLog(_: *anyopaque, s: [*]const u8, len: usize) callconv(.c) void {
    const sink = cur_sink orelse return;
    sink.write(sink.ctx, s[0..len]);
}

fn featRegisterCommand(
    _: *anyopaque,
    name: [*]const u8,
    name_len: usize,
    run_fn: *const fn (ctx: *anyopaque, args: [*]const u8, args_len: usize) callconv(.c) void,
) callconv(.c) bool {
    return features.registerCommand(name[0..name_len], run_fn, &feat_run_ctx);
}

/// The `get_interface` a feature is called with — INJECTED, like `sink`, because
/// the registry that answers it must name things this layer may not (the file
/// system, the desktop, a session): it lives in `console/capabilities.zig`, above
/// here. A low layer receiving a capability is the seam; a low layer reaching up
/// for one is the inversion. Host rigs pass their own.
pub const GetInterface = *const fn (ctx: *anyopaque, id: u32, version: u32) callconv(.c) ?*const anyopaque;

/// Verify `blob` as a feature, place it into caller-provided executable
/// `image` memory, and call its `register` with output routed to `sink` and
/// capability requests answered by `get_interface`.
/// Returns the feature's return code. The image backs every callback the
/// feature registered, so it must stay live (and executable) as long as those
/// commands can run — for the kernel, the rest of the boot.
pub fn registerBlob(blob: []const u8, image: []u8, sink: Sink, get_interface: GetInterface) runner.LoadError!i32 {
    const entry = try runner.loadFeature(blob, image);
    var fapi = abi.FeatureApi{
        .version = abi.ABI_VERSION,
        .ctx = &feat_run_ctx,
        .log = featLog,
        .register_command = featRegisterCommand,
        .get_interface = get_interface,
    };
    const prev = cur_sink;
    cur_sink = sink;
    defer cur_sink = prev;
    const rc = entry(&fapi);
    // The FeatureApi pointer does not outlive `register` — the contract is to
    // copy the struct by value. A feature that kept the pointer would otherwise
    // fail only when this stack slot happens to be reused; poisoning it makes
    // that bug deterministic at its first callback instead of latent.
    @memset(std.mem.asBytes(&fapi), 0xAA);
    return rc;
}

/// Run a feature-registered command if one matches `name`, routing its output
/// to `sink` for the call. Returns whether a feature command handled it.
pub fn dispatch(sink: Sink, name: []const u8, args: []const u8) bool {
    const e = features.lookup(name) orelse return false;
    const prev = cur_sink;
    cur_sink = sink;
    defer cur_sink = prev;
    // A stable pointer even for an empty argument string: the C-ABI callback
    // receives (ptr, len) and must never see an undefined ptr.
    const p: [*]const u8 = if (args.len == 0) "" else args.ptr;
    e.run(e.ctx, p, args.len);
    return true;
}
