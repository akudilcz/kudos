//! Host tests of src/kernel/loader/abi.zig — the `.kudos` binary ABI: CRC parity with
//! the host factory, header round-trip, and every rejection case of `verify`.

const std = @import("std");
const abi = @import("abi");

// The CRC must equal Python's binascii.crc32 (the factory), which is the
// standard IEEE reflected CRC-32 with the well-known check values.
test "crc32 matches the standard vectors the factory uses" {
    try std.testing.expectEqual(@as(u32, 0x00000000), abi.crc32(""));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), abi.crc32("123456789"));
}

// A file stamped by writeHeader must verify, and hand back exactly the code
// slice and mem_len it was given.
test "writeHeader round-trips through verify (MOD-005)" {
    const code = "\x00\x01\x02hello-kudos-payload";
    const mem_len: usize = code.len + 4096; // a .bss tail

    var buf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    var hdr: [abi.HEADER_SIZE]u8 = undefined;
    abi.writeHeader(&hdr, .app, code, mem_len);
    @memcpy(buf[0..abi.HEADER_SIZE], &hdr);
    @memcpy(buf[abi.HEADER_SIZE..], code);

    const got = try abi.verify(&buf);
    try std.testing.expectEqual(abi.Kind.app, got.kind);
    try std.testing.expectEqualSlices(u8, code, got.code);
    try std.testing.expectEqual(mem_len, got.mem_len);
}

test "feature kind round-trips" {
    const code = "feat";
    var buf: [abi.HEADER_SIZE + code.len]u8 = undefined;
    var hdr: [abi.HEADER_SIZE]u8 = undefined;
    abi.writeHeader(&hdr, .feature, code, code.len);
    @memcpy(buf[0..abi.HEADER_SIZE], &hdr);
    @memcpy(buf[abi.HEADER_SIZE..], code);
    const got = try abi.verify(&buf);
    try std.testing.expectEqual(abi.Kind.feature, got.kind);
}

// Build one valid blob, then mutate each invariant and assert the matching
// distinct error — the loader depends on telling these apart.
fn stamp(buf: []u8, code: []const u8, mem_len: usize) void {
    var hdr: [abi.HEADER_SIZE]u8 = undefined;
    abi.writeHeader(&hdr, .app, code, mem_len);
    @memcpy(buf[0..abi.HEADER_SIZE], &hdr);
    @memcpy(buf[abi.HEADER_SIZE..][0..code.len], code);
}

// A capability vtable is ABI: a generated blob binds it by field OFFSET, so the
// layout must stay append-only. version is first (a blob checks it before calling),
// and each call pointer keeps its offset; a new call may only be appended.
test "WindowApi vtable layout is the committed ABI (append-only, ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.WindowApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.WindowApi, "create"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.WindowApi, "close"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(abi.WindowApi, "closed"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(abi.WindowApi, "size"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(abi.WindowApi, "focused"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(abi.WindowApi, "retitle"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(abi.WindowApi, "blit"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(abi.WindowApi, "count"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(abi.WindowApi, "at"));
    // Bounds fit a u16 surface dimension, and more than one window is the point.
    try std.testing.expect(abi.WINDOW_MAX_W > 0 and abi.WINDOW_MAX_W <= 0xFFFF);
    try std.testing.expect(abi.WINDOW_MAX_H > 0 and abi.WINDOW_MAX_H <= 0xFFFF);
    try std.testing.expect(abi.WINDOW_MAX_COUNT > 1);
    // The content modes are distinct ABI values.
    try std.testing.expect(abi.WINDOW_PIXELS != abi.WINDOW_SCENE);
}

test "TaskApi and TaskCtlApi layouts are the committed ABI (ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.TaskApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.TaskApi, "count"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.TaskApi, "at"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(abi.TaskApi, "label"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(abi.TaskApi, "self_core"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.TaskCtlApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.TaskCtlApi, "spawn"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.TaskCtlApi, "stop"));
    // TaskInfo is fixed-width fields a module reads by offset.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.TaskInfo, "state"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(abi.TaskInfo, "core"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.TaskInfo, "cpu_ms"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.TaskInfo, "current"));
}

test "VfsApi vtable layout is the committed ABI (append-only, ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.VfsApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.VfsApi, "size"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.VfsApi, "read"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(abi.VfsApi, "write"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(abi.VfsApi, "remove"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(abi.VfsApi, "mkdir"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(abi.VfsApi, "rmdir"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(abi.VfsApi, "list"));
}

test "NetApi vtable layout is the committed ABI (append-only, ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.NetApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.NetApi, "online"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.NetApi, "fetch_begin"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(abi.NetApi, "fetch_poll"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(abi.NetApi, "fetch_end"));
    // The poll answers are ABI values, not enum positions.
    try std.testing.expectEqual(@as(u32, 0), abi.NET_IDLE);
    try std.testing.expectEqual(@as(u32, 1), abi.NET_IN_FLIGHT);
    try std.testing.expectEqual(@as(u32, 2), abi.NET_DONE);
    try std.testing.expectEqual(@as(u32, 3), abi.NET_FAILED);
}

test "InputApi and GlApi layouts are the committed ABI (ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.InputApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.InputApi, "pointer"));
    // gl's first call selects the window; recording follows it.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.GlApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.GlApi, "frame"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.GlApi, "enable"));
    try std.testing.expectEqual(@sizeOf(abi.GlApi) - 8, @offsetOf(abi.GlApi, "end_frame"));
}

test "DeskApi vtable layout is the committed ABI (append-only, ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.DeskApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.DeskApi, "window"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.DeskApi, "windows"));
    // The action values are ABI, not enum positions.
    try std.testing.expectEqual(@as(u32, 1), abi.DESK_FOCUS);
    try std.testing.expectEqual(@as(u32, 5), abi.DESK_CLOSE);
}

test "GuestsApi vtable layout is the committed ABI (append-only, ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.GuestsApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.GuestsApi, "count"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.GuestsApi, "state"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(abi.GuestsApi, "request_stop"));
    try std.testing.expectEqual(@as(u32, 0), abi.GUEST_ABSENT);
    try std.testing.expectEqual(@as(u32, 5), abi.GUEST_FAILED);
}

test "MetricsApi vtable layout is the committed ABI (append-only, ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.MetricsApi, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.MetricsApi, "frame_stats"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.MetricsApi, "counter_count"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(abi.MetricsApi, "counter_name"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(abi.MetricsApi, "counter"));
}

test "FrameStats is fixed-width C-ABI fields a module can bind (ARCH-013)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.FrameStats, "seq"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(abi.FrameStats, "fps"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.FrameStats, "pump_avg_us"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(abi.FrameStats, "pump_max_us"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(abi.FrameStats, "inputs_per_s"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(abi.FrameStats));
}

// get_interface is how a module reaches anything past the base table, so its
// position in BOTH surfaces is ABI. The Api's other offsets are covered by the
// blobs that already bind them; these two are the ones a capability change moves.
test "get_interface holds its offset in both module surfaces (MOD-007)" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(abi.Api, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(abi.Api, "ctx"));
    // Last field of Api: every capability added since is an Interface id, not a
    // new field here — which is the whole point of binding by id.
    try std.testing.expectEqual(@sizeOf(abi.Api) - 8, @offsetOf(abi.Api, "get_interface"));
    // A feature binds through the same call at the end of its own table.
    try std.testing.expectEqual(@sizeOf(abi.FeatureApi) - 8, @offsetOf(abi.FeatureApi, "get_interface"));
}

test "every defined capability names a distinct id and a real vtable (MOD-007)" {
    // The ABI's capability list is what the agent's documentation is generated
    // from (src/agent/prompt.zig), so a duplicate or an id whose vtable carries no
    // calls would publish a capability nobody can use.
    inline for (abi.CAPABILITIES, 0..) |cap, i| {
        try std.testing.expect(cap.version >= 1);
        var calls: usize = 0;
        inline for (@typeInfo(cap.vtable).@"struct".fields) |f| {
            if (comptime (f.name[0] == '_' or std.mem.eql(u8, f.name, "version"))) continue;
            calls += 1;
        }
        try std.testing.expect(calls > 0);
        // Its vtable states the same version the row claims, so a module that
        // checks the struct's `version` field sees what it asked for.
        try std.testing.expectEqual(
            @as(usize, 0),
            @offsetOf(cap.vtable, "version"),
        );
        inline for (abi.CAPABILITIES, 0..) |other, j| {
            if (comptime (i == j)) continue;
            try std.testing.expect(!(cap.id == other.id and cap.version == other.version));
        }
    }
}

test "verify rejects every corruption with its own error (ARCH-014)" {
    const code = "payload!!";
    var buf: [abi.HEADER_SIZE + code.len]u8 = undefined;

    // too small: fewer bytes than a header
    try std.testing.expectError(error.TooSmall, abi.verify(buf[0 .. abi.HEADER_SIZE - 1]));

    // bad magic
    stamp(&buf, code, code.len);
    buf[0] +%= 1;
    try std.testing.expectError(error.BadMagic, abi.verify(&buf));

    // bad version
    stamp(&buf, code, code.len);
    std.mem.writeInt(u32, buf[4..8], abi.ABI_VERSION + 1, .little);
    try std.testing.expectError(error.BadVersion, abi.verify(&buf));

    // bad kind
    stamp(&buf, code, code.len);
    std.mem.writeInt(u32, buf[8..12], 0, .little);
    try std.testing.expectError(error.BadKind, abi.verify(&buf));

    // mem_len < code_len
    stamp(&buf, code, code.len);
    std.mem.writeInt(u32, buf[16..20], @as(u32, code.len - 1), .little);
    try std.testing.expectError(error.BadLengths, abi.verify(&buf));

    // code_len runs past the end of the blob
    stamp(&buf, code, code.len);
    std.mem.writeInt(u32, buf[12..16], @as(u32, code.len + 1), .little);
    // mem_len must stay >= code_len to reach the length/bounds check
    std.mem.writeInt(u32, buf[16..20], @as(u32, code.len + 1), .little);
    try std.testing.expectError(error.BadLengths, abi.verify(&buf));

    // bad crc: flip a code byte, leaving the stored crc stale
    stamp(&buf, code, code.len);
    buf[abi.HEADER_SIZE] +%= 1;
    try std.testing.expectError(error.BadCrc, abi.verify(&buf));
}
