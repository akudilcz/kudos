//! Host driver that loads and RUNS a real `.kudos` on the development
//! machine — the laptop-local, no-QEMU end-to-end proof of the ABI, the loader,
//! and the factory's machine-code output.
//!
//! It reuses the exact kernel load paths (`src/kernel/loader/runner.zig` for
//! apps, `hotload.zig` for features), differing only in what the kernel
//! supplies for itself: executable memory comes from mmap(PROT_EXEC) instead
//! of the (already-executable) kernel heap, and the `Api`/output sink are
//! backed by libc/std instead of kudos subsystems.
//!
//! Usage: hostload <file.kudos>                    app: run, exit with its i32
//!        hostload <file.kudos> <command> [args]   feature: register, then
//!                                                 dispatch <command>

const std = @import("std");
const hotload = @import("hotload");
const runner = hotload.runner;
const abi = runner.abi;

/// State reached through `Api.ctx`: a bump arena and a fixed RNG, enough to
/// exercise an app's use of the capability surface deterministically.
const Ctx = struct {
    arena: []u8,
    used: usize = 0,
    rng: u64 = 0x1234_5678_9abc_def1,
};

fn ctxPtr(p: *anyopaque) *Ctx {
    return @ptrCast(@alignCast(p));
}

fn apiPrint(_: *anyopaque, s: [*]const u8, len: usize) callconv(.c) void {
    _ = std.os.linux.write(1, s, len);
}
fn apiPollKey(_: *anyopaque) callconv(.c) i32 {
    return -1; // no input in the host harness
}
fn apiMillis(_: *anyopaque) callconv(.c) u64 {
    return 0;
}
fn apiSleepMs(_: *anyopaque, _: u64) callconv(.c) void {}
fn apiYield(_: *anyopaque) callconv(.c) void {}
fn apiCancelled(_: *anyopaque) callconv(.c) bool {
    return false;
}
fn apiRand(p: *anyopaque) callconv(.c) u64 {
    const c = ctxPtr(p);
    c.rng = c.rng *% 6364136223846793005 +% 1442695040888963407;
    return c.rng;
}
fn apiAlloc(p: *anyopaque, n: usize, log2_align: u8) callconv(.c) ?[*]u8 {
    const c = ctxPtr(p);
    const al: usize = @as(usize, 1) << @intCast(log2_align);
    const base = std.mem.alignForward(usize, c.used, al);
    if (base + n > c.arena.len) return null;
    c.used = base + n;
    return c.arena.ptr + base;
}
fn apiFileRead(_: *anyopaque, _: [*]const u8, _: usize, _: [*]u8, _: usize) callconv(.c) isize {
    return -1; // no VFS on the host
}
fn apiFileWrite(_: *anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) bool {
    return false;
}
fn apiGetInterface(_: *anyopaque, _: u32, _: u32) callconv(.c) ?*const anyopaque {
    // The host harness publishes no capability interfaces — there is no window, no
    // desktop and no machine behind it. Handed to both an app's `Api` and a
    // feature's `FeatureApi`, so a module that binds anything here takes the same
    // refusal it would take from a kudos that does not publish it, which is the
    // path worth exercising on a laptop.
    return null;
}

// The host analogue of the kernel's terminal sink: feature output to stdout.
var sink_ctx: u8 = 0;

fn sinkStdout(_: *anyopaque, text: []const u8) void {
    _ = std.os.linux.write(1, text.ptr, text.len);
}

fn stdoutSink() hotload.Sink {
    return .{ .ctx = &sink_ctx, .write = sinkStdout };
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const args = init.minimal.args.vector;
    if (args.len < 2) {
        std.debug.print("usage: hostload <file.kudos>\n", .{});
        std.process.exit(2);
    }

    const blob = try std.Io.Dir.cwd().readFileAlloc(init.io, std.mem.span(args[1]), a, .limited(64 << 20));
    const loadable = try abi.verify(blob);
    const mem_len = loadable.mem_len;

    // Executable image memory — the host analogue of the kernel's executable heap.
    const page = std.heap.pageSize();
    const rounded = std.mem.alignForward(usize, mem_len, page);
    const image = try std.posix.mmap(
        null,
        rounded,
        .{ .READ = true, .WRITE = true, .EXEC = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    defer std.posix.munmap(image);

    if (loadable.kind == .feature) {
        // The kernel path for a feature, on the host: register through the
        // shared core, then dispatch the named command if one was asked for.
        const rc = try hotload.registerBlob(blob, image[0..mem_len], stdoutSink(), apiGetInterface);
        if (args.len >= 3) {
            const cmd_args: []const u8 = if (args.len >= 4) std.mem.span(args[3]) else "";
            if (!hotload.dispatch(stdoutSink(), std.mem.span(args[2]), cmd_args)) {
                std.debug.print("hostload: no such feature command: {s}\n", .{std.mem.span(args[2])});
                std.process.exit(3);
            }
        }
        std.process.exit(@intCast(rc & 0x7f));
    }

    const entry = try runner.loadApp(blob, image[0..mem_len]);

    const arena = try a.alloc(u8, abi.APP_ARENA_MAX_BYTES);
    defer a.free(arena);
    var ctx = Ctx{ .arena = arena };
    const api = abi.Api{
        .version = abi.ABI_VERSION,
        .ctx = &ctx,
        .print = apiPrint,
        .poll_key = apiPollKey,
        .millis = apiMillis,
        .sleep_ms = apiSleepMs,
        .yield = apiYield,
        .cancelled = apiCancelled,
        .rand = apiRand,
        .alloc = apiAlloc,
        .file_read = apiFileRead,
        .file_write = apiFileWrite,
        .get_interface = apiGetInterface,
    };

    const rc = entry(&api);
    std.process.exit(@intCast(rc & 0x7f));
}
