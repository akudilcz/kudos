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
