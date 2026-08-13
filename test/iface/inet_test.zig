//! Host tests of src/iface/inet.zig's module-fetch mailbox — the parked-request
//! handshake behind the `net` capability (MOD-007). The INet contract itself is
//! exercised by the stack and its consumers; this file covers the one piece of
//! logic the seam carries.

const std = @import("std");
const abi = @import("abi");
const inet = @import("inet");

test "a fetch parks, is taken, completes, and is acknowledged" {
    // Idle start (fresh module state; tests in this file run in sequence).
    try std.testing.expectEqual(inet.MFetchState.idle, inet.moduleFetchState());

    try std.testing.expect(inet.requestModuleFetch("http://example.com/data.bin", "data.bin"));
    try std.testing.expectEqual(inet.MFetchState.requested, inet.moduleFetchState());

    const req = inet.takeModuleFetchRequest() orelse return error.NothingParked;
    try std.testing.expectEqualStrings("http://example.com/data.bin", req.url);
    try std.testing.expectEqualStrings("data.bin", req.name);
    try std.testing.expectEqual(inet.MFetchState.in_flight, inet.moduleFetchState());
    // Taken means taken: a second take gets nothing.
    try std.testing.expect(inet.takeModuleFetchRequest() == null);

    inet.completeModuleFetch(true);
    try std.testing.expectEqual(inet.MFetchState.done, inet.moduleFetchState());
    inet.finishModuleFetch();
    try std.testing.expectEqual(inet.MFetchState.idle, inet.moduleFetchState());
}

test "one fetch at a time: a second park is refused until the first is acknowledged" {
    try std.testing.expect(inet.requestModuleFetch("http://a/x", "x"));
    // Parked, in flight, done — refused at every stage short of idle.
    try std.testing.expect(!inet.requestModuleFetch("http://b/y", "y"));
    _ = inet.takeModuleFetchRequest();
    try std.testing.expect(!inet.requestModuleFetch("http://b/y", "y"));
    inet.completeModuleFetch(false);
    try std.testing.expect(!inet.requestModuleFetch("http://b/y", "y"));
    try std.testing.expectEqual(inet.MFetchState.failed, inet.moduleFetchState());
    inet.finishModuleFetch();
    try std.testing.expect(inet.requestModuleFetch("http://b/y", "y"));
    _ = inet.takeModuleFetchRequest();
    inet.completeModuleFetch(true);
    inet.finishModuleFetch();
}

test "a module cannot cancel a transfer the system core still owns" {
    try std.testing.expect(inet.requestModuleFetch("http://a/x", "x"));
    // finish() is an acknowledgement of a RESULT; before one exists it is a
    // no-op — otherwise the module could free the slot while the pump still
    // writes into it.
    inet.finishModuleFetch();
    try std.testing.expectEqual(inet.MFetchState.requested, inet.moduleFetchState());
    _ = inet.takeModuleFetchRequest();
    inet.finishModuleFetch();
    try std.testing.expectEqual(inet.MFetchState.in_flight, inet.moduleFetchState());
    inet.completeModuleFetch(true);
    inet.finishModuleFetch();
    try std.testing.expectEqual(inet.MFetchState.idle, inet.moduleFetchState());
}

test "the mailbox's bounds are the ABI's, and over-bound requests are refused" {
    try std.testing.expectEqual(abi.NET_URL_MAX, inet.MFETCH_URL_MAX);
    const long_url = "h" ** (inet.MFETCH_URL_MAX + 1);
    try std.testing.expect(!inet.requestModuleFetch(long_url, "x"));
    const long_name = "n" ** (inet.MFETCH_NAME_MAX + 1);
    try std.testing.expect(!inet.requestModuleFetch("http://a/x", long_name));
    try std.testing.expect(!inet.requestModuleFetch("", "x"));
    try std.testing.expect(!inet.requestModuleFetch("http://a/x", ""));
    try std.testing.expectEqual(inet.MFetchState.idle, inet.moduleFetchState());
}

// ── the guest-name table ─────────────────────────────────────────────────────
// Register → bind → lookup → unregister is a guest's whole naming life; the
// tests below run in sequence over the module's one table and each leaves it
// empty.

const MAC_A = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x00 };
const MAC_B = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x01 };

test "a guest resolves only between its lease landing and its teardown" {
    // Registered but unleased: the name exists, the address does not yet.
    try std.testing.expect(inet.registerGuest("zigserver", MAC_A));
    try std.testing.expectEqual(@as(?[4]u8, null), inet.lookupGuest("zigserver"));

    // A stranger's ACK (a MAC not in the table) binds nothing.
    inet.bindGuestIp(MAC_B, .{ 10, 0, 2, 99 });
    try std.testing.expectEqual(@as(?[4]u8, null), inet.lookupGuest("zigserver"));

    inet.bindGuestIp(MAC_A, .{ 10, 0, 2, 16 });
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 2, 16 }), inet.lookupGuest("zigserver"));
    // A re-lease rebinds; an all-zero "lease" is not one and changes nothing.
    inet.bindGuestIp(MAC_A, .{ 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 2, 16 }), inet.lookupGuest("zigserver"));
    inet.bindGuestIp(MAC_A, .{ 10, 0, 2, 17 });
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 2, 17 }), inet.lookupGuest("zigserver"));

    // vm stop: the name is withdrawn with the guest.
    inet.unregisterGuest(MAC_A);
    try std.testing.expectEqual(@as(?[4]u8, null), inet.lookupGuest("zigserver"));
    inet.unregisterGuest(MAC_A); // teardown paths call this unconditionally
}

test "re-registering a MAC replaces its entry — a recycled slot starts unleased" {
    try std.testing.expect(inet.registerGuest("ubuntu", MAC_A));
    inet.bindGuestIp(MAC_A, .{ 10, 0, 2, 20 });
    // The slot is reused for a different guest: same MAC, new name, no lease.
    try std.testing.expect(inet.registerGuest("firefox", MAC_A));
    try std.testing.expectEqual(@as(?[4]u8, null), inet.lookupGuest("ubuntu"));
    try std.testing.expectEqual(@as(?[4]u8, null), inet.lookupGuest("firefox"));
    inet.unregisterGuest(MAC_A);
}

test "two boots of the same image are two entries; lookup finds the leased one" {
    try std.testing.expect(inet.registerGuest("zigserver", MAC_A));
    try std.testing.expect(inet.registerGuest("zigserver", MAC_B));
    inet.bindGuestIp(MAC_B, .{ 10, 0, 2, 18 });
    // MAC_A's twin has no lease; the bound twin answers rather than the first
    // name hit ending the search.
    try std.testing.expectEqual(@as(?[4]u8, .{ 10, 0, 2, 18 }), inet.lookupGuest("zigserver"));
    inet.unregisterGuest(MAC_A);
    inet.unregisterGuest(MAC_B);
}

test "capacity is the guest count: a fifth name needs a freed entry" {
    var macs: [inet.GUEST_NAMES][6]u8 = undefined;
    for (&macs, 0..) |*m, i| {
        m.* = MAC_A;
        m[5] = @intCast(0x10 + i);
        try std.testing.expect(inet.registerGuest("guest", m.*));
    }
    var extra = MAC_A;
    extra[5] = 0xFF;
    try std.testing.expect(!inet.registerGuest("late", extra));
    inet.unregisterGuest(macs[0]);
    try std.testing.expect(inet.registerGuest("late", extra));
    inet.unregisterGuest(extra);
    for (macs[1..]) |m| inet.unregisterGuest(m);
}

test "a name outside the table's bounds is refused, not truncated" {
    try std.testing.expect(!inet.registerGuest("", MAC_A));
    const long = "n" ** (inet.GUEST_NAME_MAX + 1);
    try std.testing.expect(!inet.registerGuest(long, MAC_A));
    try std.testing.expectEqual(@as(?[4]u8, null), inet.lookupGuest(long));
}
