//! `net SUBCOMMAND` — the single front door to the network:
//! ip | dns NAME | ping HOST | fetch URL [NAME].

const std = @import("std");
const iramdisk = @import("iramdisk"); // the file store, whoever provides it
const inet = @import("inet"); // the network: online?, resolve, ping, fetch
const timer = @import("../../kernel/timer/timer.zig");
const console = @import("../console.zig");

const NET_USAGE =
    \\usage: net SUBCOMMAND
    \\  net ip              show the leased address config
    \\  net dns NAME        resolve a hostname to an IPv4 address
    \\  net ping HOST       send 4 ICMP echo requests to an IP or hostname
    \\  net fetch URL [NAME] HTTP GET; print body, optionally save to ramdisk
    \\
;

// Whether bring-up has been attempted yet. The network comes up on the first `net`
// command rather than at boot, so booting never stalls waiting for a DHCP server that
// may not be there. One attempt only: after it runs, `isUp` reflects the result, and a
// second command must not pay the full DHCP timeout again.
var net_init_tried = false;

/// The network, or a printed complaint and null. Every `net` subcommand starts here:
/// there may be no network stack at all (a build without one), and a command that
/// silently does nothing in that case is worse than one that says why.
fn network(c: console.Console) ?inet.INet {
    return inet.instance orelse {
        c.write("no network stack in this build\n");
        return null;
    };
}

/// `net SUBCOMMAND` — dispatch to the subcommand. The NIC is brought up lazily on
/// the first invocation (see `net_init_tried`), so boot never stalls on DHCP.
pub fn run(c: console.Console, args: []const u8) void {
    const n = network(c) orelse return;
    // Lazy bring-up: the first `net` command claims the NIC and leases an address. Boot
    // stays instant, and the cost is only paid when someone actually wants the network.
    if (!net_init_tried) {
        net_init_tried = true;
        if (n.bringUp()) {
            c.write("network: up\n");
        } else {
            c.write("network: DOWN (no NIC or DHCP failed)\n");
        }
    }

    const sp = std.mem.indexOfScalar(u8, args, ' ');
    const sub = if (sp) |i| args[0..i] else args;
    const rest = if (sp) |i| std.mem.trim(u8, args[i + 1 ..], " \t") else "";

    if (sub.len == 0) {
        c.write(if (n.isUp()) "network: up\n" else "network: DOWN\n");
        c.write(NET_USAGE);
    } else if (std.mem.eql(u8, sub, "ip")) {
        netIp(c);
    } else if (std.mem.eql(u8, sub, "dns")) {
        netDns(c, rest);
    } else if (std.mem.eql(u8, sub, "ping")) {
        netPing(c, rest);
    } else if (std.mem.eql(u8, sub, "fetch")) {
        netFetch(c, rest);
    } else {
        c.write("net: unknown subcommand '");
        c.write(sub);
        c.write("'\n");
        c.write(NET_USAGE);
    }
}

/// Write a [4]u8 IPv4 address to the terminal as dotted-decimal.
fn writeIp(c: console.Console, ip: [4]u8) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return;
    c.write(s);
}

/// `net ip` — show the address we were leased (MAC, IP, mask, gateway, DNS).
fn netIp(c: console.Console) void {
    const n = network(c) orelse return;
    if (!n.isUp()) {
        c.write("network is down\n");
        return;
    }
    const lease = n.lease();
    var buf: [64]u8 = undefined;
    const mac = std.fmt.bufPrint(&buf, "mac    {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
        lease.mac[0], lease.mac[1], lease.mac[2], lease.mac[3], lease.mac[4], lease.mac[5],
    }) catch return;
    c.write("link   up\n");
    c.write(mac);
    c.write("ip     ");
    writeIp(c, lease.ip);
    c.write("\nmask   ");
    writeIp(c, lease.netmask);
    c.write("\ngw     ");
    writeIp(c, lease.gateway);
    c.write("\ndns    ");
    writeIp(c, lease.dns);
    c.put('\n');
}

/// `net dns NAME` — resolve a hostname to an IPv4 address via DNS.
fn netDns(c: console.Console, name: []const u8) void {
    if (name.len == 0) {
        c.write("usage: net dns NAME\n");
        return;
    }
    const n = network(c) orelse return;
    if (!n.isUp()) {
        c.write("network is down\n");
        return;
    }
    if (n.resolve(name)) |ip| {
        c.write(name);
        c.write(" -> ");
        writeIp(c, ip);
        c.put('\n');
    } else {
        c.write("could not resolve '");
        c.write(name);
        c.write("'\n");
    }
}

// `net ping` behaviour (see netPing's doc): how many echo
// requests to send, the per-reply timeout, and the gap between requests.
const PING_COUNT: u8 = 4;
const PING_TIMEOUT_MS: u64 = 1000;
const PING_SPACING_MS: u64 = 1000;

/// `net ping HOST` — send PING_COUNT ICMP echo requests to an IP or hostname
/// (1 s per-reply timeout, 1 s spacing) and report RTTs plus a reply count.
fn netPing(c: console.Console, host: []const u8) void {
    if (host.len == 0) {
        c.write("usage: net ping HOST\n");
        return;
    }
    const nw = network(c) orelse return;
    if (!nw.isUp()) {
        c.write("network is down\n");
        return;
    }
    // `resolve` takes a literal address as well as a name, so `ping 192.168.20.30`
    // works with no DNS server in sight.
    const ip = nw.resolve(host) orelse {
        c.write("could not resolve '");
        c.write(host);
        c.write("'\n");
        return;
    };

    c.write("pinging ");
    writeIp(c, ip);
    c.write(" ...\n");
    var recv: u8 = 0;
    var n: u8 = 0;
    while (n < PING_COUNT) : (n += 1) {
        if (nw.ping(ip, PING_TIMEOUT_MS)) |rtt| {
            recv += 1;
            var buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "reply seq={d} time={d} ms\n", .{ n, rtt }) catch return;
            c.write(s);
        } else {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "timeout seq={d}\n", .{n}) catch return;
            c.write(s);
        }
        if (n < PING_COUNT - 1) timer.sleep(PING_SPACING_MS); // no sleep after the last request
    }
    var buf: [48]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}/{d} replies\n", .{ recv, PING_COUNT }) catch return;
    c.write(s);
}

/// The most body bytes echoed to the terminal for a bare (no-NAME) fetch.
/// Printing a whole multi-megabyte body is a per-cell write plus a grid-scroll
/// memmove per newline — seconds of wedged core, and binary data is garbage on
/// a text grid anyway. A save (NAME given) skips the echo entirely.
const FETCH_ECHO_CAP: usize = 4 * 1024;

// The console + save name for the ONE backgrounded fetch. Static because the
// command returns before the fetch finishes (single connection → one at a time).
const FetchCmd = struct {
    c: console.Console = undefined,
    name_buf: [80]u8 = undefined,
    name_len: usize = 0,
};
var g_fetch: FetchCmd = .{};

/// Fires on the session-loop core when the backgrounded fetch retires — `body`
/// is the response (copy it before returning) or null on failure. Save it under
/// the requested NAME, or echo a capped preview.
fn onFetchDone(ctx: *anyopaque, body: ?[]const u8) void {
    const self: *FetchCmd = @ptrCast(@alignCast(ctx));
    const c = self.c;
    const b = body orelse {
        c.write("\nnet: fetch failed\n");
        c.prompt();
        return;
    };
    if (self.name_len > 0) {
        const name = self.name_buf[0..self.name_len];
        const store = iramdisk.instance orelse {
            c.write("\nnet: no file store\n");
            c.prompt();
            return;
        };
        store.put(name, b) catch {
            c.write("\nnet: could not save\n");
            c.prompt();
            return;
        };
        var buf: [64]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "\nsaved {d} bytes to {s}\n", .{ b.len, name }) catch "\nsaved\n");
    } else {
        const shown = @min(b.len, FETCH_ECHO_CAP);
        c.put('\n');
        c.write(b[0..shown]);
        if (shown == 0 or b[shown - 1] != '\n') c.put('\n');
        if (shown < b.len) {
            var buf: [64]u8 = undefined;
            c.write(std.fmt.bufPrint(&buf, "[{d} more bytes not shown; add a NAME to save]\n", .{b.len - shown}) catch "[truncated]\n");
        }
    }
    c.prompt();
}

/// `net fetch URL [NAME]` — HTTP GET in the BACKGROUND: the command returns at
/// once, the transfer advances a chunk per frame (the render stays smooth), and
/// the result prints when it lands. With NAME, save to that ramdisk file; without,
/// echo a capped preview.
///
/// HTTPS is the exception, and runs SYNCHRONOUSLY. A TLS session is a blocking
/// byte stream (tls.zig) with no per-frame step the background job could drive,
/// so the shell is held for the transfer — said plainly on the line above it,
/// because a desktop that stops repainting with no explanation reads as a hang.
fn netFetch(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: net fetch URL [NAME]\n");
        return;
    }
    const sp = std.mem.indexOfScalar(u8, args, ' ');
    const url = if (sp) |i| args[0..i] else args;
    const name = if (sp) |i| std.mem.trim(u8, args[i + 1 ..], " \t") else "";
    const n = network(c) orelse return;

    g_fetch.c = c;
    g_fetch.name_len = @min(name.len, g_fetch.name_buf.len);
    @memcpy(g_fetch.name_buf[0..g_fetch.name_len], name[0..g_fetch.name_len]);

    if (std.ascii.startsWithIgnoreCase(url, "https://")) {
        c.write("fetching ");
        c.write(url);
        c.write(" (https — the shell waits)\n");
        const body = n.fetch(c.a, url) catch |e| {
            c.write("net: ");
            c.write(@errorName(e));
            c.put('\n');
            c.prompt();
            return;
        };
        defer c.a.free(body);
        // The same landing as a backgrounded fetch: one home for save-or-echo.
        onFetchDone(&g_fetch, body);
        return;
    }

    n.fetchBackground(c.a, url, &g_fetch, onFetchDone) catch |e| {
        c.write("net: ");
        c.write(@errorName(e));
        c.put('\n');
        return;
    };
    c.write("fetching ");
    c.write(url);
    c.write(" (backgrounded)\n");
}
