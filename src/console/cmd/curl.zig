//! `curl [-s] [-o FILE] URL` — HTTP GET. The body prints to the terminal
//! (capped), or lands in the named ramdisk file with `-o`, curl(1)'s flag; `-s`
//! silences the notes curl's own -s silences (the transfer still reports its
//! failures).
//!
//! http rides the BACKGROUND fetch engine (a chunk per frame; the render stays
//! smooth) with the prompt held until the result lands, so the command reads
//! synchronous the way curl does. Safe to hold: the engine's stall budget
//! (fetchjob.STALL_MS) guarantees completion or failure. https has no per-frame
//! step (a TLS session is a blocking byte stream), so it runs synchronously and
//! says so before it holds the shell.
//!
//! There is ONE in-flight transfer machine-wide (one TCP connection), and
//! terminals run their commands at the same time (APP-031) — so the slot below
//! is CLAIMED, and a second curl is refused with the holder's work undisturbed
//! (APP-032), never silently overwritten.

const std = @import("std");
const console = @import("../console.zig");
const inet = @import("inet");
const iramdisk = @import("iramdisk");
const network = @import("../network.zig");
const opt = @import("../opt.zig");

const USAGE = "usage: curl [-s] [-o FILE] URL\n";

/// Most body bytes echoed for a print (no `-o`). A whole multi-megabyte body is
/// a per-cell write plus a scroll memmove per newline — seconds of wedged core.
const ECHO_CAP: usize = 4 * 1024;

// The console + save name for the ONE in-flight fetch. Static because the
// command returns before a backgrounded fetch finishes (single connection →
// one at a time); `busy` is the claim that keeps two terminals out of it.
const Fetch = struct {
    busy: bool = false,
    c: console.Console = undefined,
    name_buf: [80]u8 = undefined,
    name_len: usize = 0,
    silent: bool = false,
};
var g_fetch: Fetch = .{};

pub fn run(c: console.Console, args: []const u8) void {
    var name: []const u8 = "";
    var silent = false;
    var sc = opt.Scan.init("o:", args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            'o' => name = v.arg,
            else => return opt.refuse(c, "curl", o, USAGE),
        },
        .flag => |ch| switch (ch) {
            's' => silent = true,
            else => return opt.refuse(c, "curl", o, USAGE),
        },
        else => return opt.refuse(c, "curl", o, USAGE),
    };
    var ops = opt.Operands.init("o:", args);
    const url = ops.next() orelse {
        c.write(USAGE);
        return;
    };
    const n = network.up(c) orelse return;

    // Claim the one transfer slot (APP-032): consume-or-refuse, so a second
    // terminal's curl cannot overwrite the console the first one's completion
    // will write to.
    if (@atomicRmw(bool, &g_fetch.busy, .Xchg, true, .acq_rel)) {
        c.write("curl: a transfer is already in flight\n");
        return;
    }
    g_fetch.c = c;
    g_fetch.silent = silent;
    g_fetch.name_len = @min(name.len, g_fetch.name_buf.len);
    @memcpy(g_fetch.name_buf[0..g_fetch.name_len], name[0..g_fetch.name_len]);

    if (std.ascii.startsWithIgnoreCase(url, "https://")) {
        defer @atomicStore(bool, &g_fetch.busy, false, .release);
        if (!silent) c.write("curl: https is synchronous — the shell waits\n");
        const body = n.fetch(c.a, url) catch |e| {
            c.write("curl: ");
            c.write(@errorName(e));
            c.put('\n');
            return;
        };
        defer c.a.free(body);
        deliver(&g_fetch, body);
        return;
    }

    n.fetchBackground(c.a, url, &g_fetch, onDone) catch |e| {
        @atomicStore(bool, &g_fetch.busy, false, .release);
        c.write("curl: ");
        c.write(@errorName(e));
        c.put('\n');
        return;
    };
    // The result re-prompts when it lands (onDone); until then the terminal
    // shows the transfer's own silence, exactly as curl does.
    c.holdPrompt();
}

/// Fires on the session-loop core when the backgrounded fetch retires — `body`
/// is the response (copy before returning) or null on failure.
fn onDone(ctx: *anyopaque, body: ?[]const u8) void {
    const self: *Fetch = @ptrCast(@alignCast(ctx));
    defer @atomicStore(bool, &self.busy, false, .release);
    const b = body orelse {
        self.c.write("curl: transfer failed\n");
        self.c.prompt();
        return;
    };
    deliver(self, b);
    self.c.prompt();
}

/// Save-or-echo, shared by both transports. The https path prints its own
/// prompt via the worker, so only onDone re-prompts.
fn deliver(self: *Fetch, b: []const u8) void {
    const c = self.c;
    if (self.name_len > 0) {
        const name = self.name_buf[0..self.name_len];
        const store = iramdisk.instance orelse {
            c.write("curl: no file store\n");
            return;
        };
        store.put(name, b) catch {
            c.write("curl: could not save\n");
            return;
        };
        var buf: [64]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "saved {d} bytes to {s}\n", .{ b.len, name }) catch "saved\n");
    } else {
        const shown = @min(b.len, ECHO_CAP);
        c.write(b[0..shown]);
        if (shown == 0 or b[shown - 1] != '\n') c.put('\n');
        if (shown < b.len and !self.silent) {
            var buf: [64]u8 = undefined;
            c.write(std.fmt.bufPrint(&buf, "[{d} more bytes not shown; use -o FILE]\n", .{b.len - shown}) catch "[truncated]\n");
        }
    }
}
