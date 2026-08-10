//! Host tests of src/drivers/net/stack/http_wire.zig — URL parse, request-head
//! build, status/header parse, head/body split, and the chunked decoder fed at
//! every byte boundary.

const std = @import("std");
const hw = @import("http_wire");

test "parseUrl: scheme, default and explicit ports, path default" {
    const a = try hw.parseUrl("https://openrouter.ai/api/v1/chat/completions");
    try std.testing.expectEqual(hw.Scheme.https, a.scheme);
    try std.testing.expectEqualStrings("openrouter.ai", a.host);
    try std.testing.expectEqual(@as(u16, 443), a.port);
    try std.testing.expectEqualStrings("/api/v1/chat/completions", a.path);

    const b = try hw.parseUrl("http://192.168.1.2:8624/compile");
    try std.testing.expectEqual(hw.Scheme.http, b.scheme);
    try std.testing.expectEqual(@as(u16, 8624), b.port);
    try std.testing.expectEqualStrings("/compile", b.path);

    const c = try hw.parseUrl("http://host");
    try std.testing.expectEqual(@as(u16, 80), c.port);
    try std.testing.expectEqualStrings("/", c.path);

    try std.testing.expectError(error.BadScheme, hw.parseUrl("ftp://x/y"));
    try std.testing.expectError(error.EmptyHost, hw.parseUrl("http:///path"));
}

test "buildRequestHead: POST with headers and content-length (NET-013)" {
    var buf: [512]u8 = undefined;
    const head = try hw.buildRequestHead(&buf, "POST", "openrouter.ai", "/v1/chat", &.{
        .{ .name = "Authorization", .value = "Bearer sk-xyz" },
        .{ .name = "Content-Type", .value = "application/json" },
    }, 42);
    try std.testing.expect(std.mem.startsWith(u8, head, "POST /v1/chat HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "Host: openrouter.ai\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Length: 42\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Authorization: Bearer sk-xyz\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, head, "\r\n\r\n"));
}

test "status and header parsing" {
    try std.testing.expectEqual(@as(u16, 200), hw.parseStatus("HTTP/1.1 200 OK").?);
    try std.testing.expectEqual(@as(u16, 404), hw.parseStatus("HTTP/1.1 404 Not Found").?);
    const block = "Content-Type: text/event-stream\r\nTransfer-Encoding: chunked";
    try std.testing.expectEqualStrings("chunked", hw.headerValue(block, "transfer-encoding").?);
    try std.testing.expectEqualStrings("text/event-stream", hw.headerValue(block, "Content-Type").?);
    try std.testing.expect(hw.headerValue(block, "nope") == null);
}

test "splitHead finds the header/body boundary" {
    const resp = "HTTP/1.1 200 OK\r\nX: y\r\n\r\nBODYHERE";
    const s = hw.splitHead(resp).?;
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nX: y", s.head);
    try std.testing.expectEqualStrings("BODYHERE", s.body);
    try std.testing.expect(hw.splitHead("HTTP/1.1 200 OK\r\nno terminator yet") == null);
}

test "chunked decoder reassembles across every byte split" {
    const body = "4\r\nWiki\r\n5\r\npedia\r\ne\r\n in\r\n\r\nchunks.\r\n0\r\n\r\n";
    const expected = "Wikipedia in\r\n\r\nchunks.";
    // Feed one byte at a time — the worst case for a state machine.
    var dec = hw.ChunkedDecoder{};
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    for (body) |b| {
        try dec.push(&.{b}, &out);
    }
    try std.testing.expect(dec.done);
    try std.testing.expectEqualStrings(expected, out.items);
}

test "chunked decoder rejects a chunk size that overflows usize" {
    // 17 hex digits exceed the 16 that fit a 64-bit size: a hostile server
    // must get a loud rejection, never a wrapped bogus size.
    const body = "1ffffffffffffffff\r\npayload";
    var dec = hw.ChunkedDecoder{};
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidChunkSize, dec.push(body, &out));
}

test "chunked decoder takes the hex prefix and ignores a chunk extension" {
    const body = "3;name=value\r\nabc\r\n0\r\n\r\n";
    var dec = hw.ChunkedDecoder{};
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try dec.push(body, &out);
    try std.testing.expect(dec.done);
    try std.testing.expectEqualStrings("abc", out.items);
}

test "chunked decoder in one shot" {
    const body = "3\r\nabc\r\n0\r\n\r\n";
    var dec = hw.ChunkedDecoder{};
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    try dec.push(body, &out);
    try std.testing.expect(dec.done);
    try std.testing.expectEqualStrings("abc", out.items);
}

test "StreamingBody: chunked SSE delivered incrementally across hostile splits (NET-014)" {
    const a = std.testing.allocator;
    // A chunked response carrying two SSE events; fed in 3-byte slices so the
    // head/body boundary, chunk headers, and chunk data all split arbitrarily.
    const ev1 = "data: {\"delta\":\"Hel\"}\n\n";
    const ev2 = "data: {\"delta\":\"lo!\"}\n\n";
    var wirebuf = std.array_list.Managed(u8).init(a);
    defer wirebuf.deinit();
    try wirebuf.appendSlice("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n");
    for ([_][]const u8{ ev1, ev2 }) |ev| {
        const line = try std.fmt.allocPrint(a, "{x}\r\n{s}\r\n", .{ ev.len, ev });
        defer a.free(line);
        try wirebuf.appendSlice(line);
    }
    try wirebuf.appendSlice("0\r\n\r\n");

    var sb = hw.StreamingBody.init(a);
    defer sb.deinit();
    var out = std.array_list.Managed(u8).init(a);
    defer out.deinit();

    var complete = false;
    var first_delivery_at: ?usize = null;
    var i: usize = 0;
    while (i < wirebuf.items.len) : (i += 3) {
        const end = @min(i + 3, wirebuf.items.len);
        complete = try sb.push(wirebuf.items[i..end], &out);
        if (out.items.len != 0 and first_delivery_at == null) first_delivery_at = end;
        if (complete) break;
    }
    try std.testing.expect(complete);
    // Incremental: the first body bytes arrived long before the wire ended.
    try std.testing.expect(first_delivery_at.? < wirebuf.items.len);
    var expected = std.array_list.Managed(u8).init(a);
    defer expected.deinit();
    try expected.appendSlice(ev1);
    try expected.appendSlice(ev2);
    try std.testing.expectEqualStrings(expected.items, out.items);
}

test "StreamingBody: Content-Length completes exactly, glued head+body" {
    const a = std.testing.allocator;
    var sb = hw.StreamingBody.init(a);
    defer sb.deinit();
    var out = std.array_list.Managed(u8).init(a);
    defer out.deinit();
    // Head and the whole body arrive in ONE push.
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello-trailing-garbage";
    const complete = try sb.push(wire, &out);
    try std.testing.expect(complete);
    try std.testing.expectEqualStrings("hello", out.items);
}

test "StreamingBody: close-delimited never self-completes" {
    const a = std.testing.allocator;
    var sb = hw.StreamingBody.init(a);
    defer sb.deinit();
    var out = std.array_list.Managed(u8).init(a);
    defer out.deinit();
    try std.testing.expect(!try sb.push("HTTP/1.1 200 OK\r\n\r\nabc", &out));
    try std.testing.expect(!try sb.push("def", &out));
    try std.testing.expectEqualStrings("abcdef", out.items);
}

test "a POST waits for a service to COMPUTE; a GET only waits for bytes (NET-013)" {
    // The numbers themselves are policy, but their ORDER is a correctness
    // property: the factory answers nothing until zig has finished, and a
    // compile that FAILS runs longest of all. A POST budget at or below the GET
    // one puts the client's patience ahead of the service's answer, which is the
    // shipped defect this pins — the agent's compile errors timed out instead of
    // coming back, and the late reply landed on a closed connection.
    try std.testing.expect(hw.POST_STALL_MS > hw.GET_STALL_MS);
    try std.testing.expectEqual(hw.POST_STALL_MS, hw.stallMs(true));
    try std.testing.expectEqual(hw.GET_STALL_MS, hw.stallMs(false));
    // Strictly LONGER than the factory's own 180 s per-compile budget: equal
    // budgets race, and the loser is the user, who is told the service could not
    // be reached instead of being told the compile timed out.
    try std.testing.expect(hw.POST_STALL_MS > 180_000);
}
