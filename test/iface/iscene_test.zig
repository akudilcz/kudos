//! Host tests of src/iface/iscene.zig — the scene mailbox's slot handshake and
//! the validator every replayed frame must pass (MOD-015, MOD-016).

const std = @import("std");
const iscene = @import("iscene");

fn freshSlot() iscene.Slot {
    var s: iscene.Slot = .{};
    iscene.resetSlot(&s);
    return s;
}

/// A minimal valid lit-cube-shaped frame: state, matrices, data, one draw.
fn recordValidFrame(s: *iscene.Slot) void {
    iscene.record(s, .{ .op = .enable, .a = iscene.GL_DEPTH_TEST });
    iscene.record(s, .{ .op = .enable, .a = iscene.GL_LIGHTING });
    iscene.record(s, .{ .op = .matrix_mode, .a = iscene.GL_PROJECTION });
    const m = [_]f32{1} ** 16;
    const moff = iscene.pushFloats(s, &m);
    iscene.record(s, .{ .op = .load_matrix, .off = moff, .n = 16 });
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const voff = iscene.pushFloats(s, &verts);
    iscene.record(s, .{ .op = .vertices, .off = voff, .n = 3 });
    iscene.record(s, .{ .op = .draw_arrays, .a = iscene.GL_TRIANGLES, .b = 0, .c = 3 });
}

test "a well-formed frame validates ok (MOD-016)" {
    var s = freshSlot();
    recordValidFrame(&s);
    try std.testing.expectEqual(iscene.Verdict.ok, iscene.validate(&s));
}

/// The window index these tests record into; any slot behaves the same.
const W0: usize = 0;

test "the producer/consumer slot handshake double-buffers without tearing (MOD-015)" {
    iscene.reset(W0);
    try std.testing.expect(iscene.takeFrame(W0) == null); // nothing published
    recordValidFrame(iscene.recording(W0));
    try std.testing.expect(iscene.canPublish(W0));
    iscene.publish(W0);
    // The producer records the NEXT frame in the other slot immediately...
    recordValidFrame(iscene.recording(W0));
    // ...but must NOT publish until the consumer hands the first slot back:
    // publishing flips recording ONTO that slot, and flipping onto a frame the
    // consumer still holds records over a replay in progress.
    try std.testing.expect(!iscene.canPublish(W0));
    const first = iscene.takeFrame(W0) orelse return error.NothingPublished;
    // Mid-replay the gate still holds; only release opens it.
    try std.testing.expect(!iscene.canPublish(W0));
    try std.testing.expect(iscene.validate(first) == .ok);
    iscene.release(W0);
    try std.testing.expect(iscene.canPublish(W0));
    iscene.publish(W0);
    try std.testing.expect(iscene.takeFrame(W0) != null);
    iscene.release(W0);
    try std.testing.expect(iscene.takeFrame(W0) == null);
    iscene.reset(W0);
}

test "each window's mailbox is its own (MOD-012, MOD-015)" {
    iscene.resetAll();
    recordValidFrame(iscene.recording(0));
    iscene.publish(0);
    // Window 0 has a frame waiting; window 1 has nothing, and publishing to one
    // never fills the other.
    try std.testing.expect(iscene.takeFrame(0) != null);
    try std.testing.expect(iscene.takeFrame(1) == null);
    try std.testing.expect(iscene.canPublish(1));
    iscene.release(0);
    iscene.resetAll();
}

test "an overflowed recording poisons the whole frame (MOD-016)" {
    var s = freshSlot();
    var i: usize = 0;
    while (i < iscene.MAX_CMDS + 1) : (i += 1) iscene.record(&s, .{ .op = .load_identity });
    try std.testing.expectEqual(iscene.Verdict.overflow, iscene.validate(&s));

    var s2 = freshSlot();
    const big = [_]f32{0} ** 32;
    var pushed: usize = 0;
    while (pushed <= iscene.MAX_FLOATS) : (pushed += big.len) _ = iscene.pushFloats(&s2, &big);
    try std.testing.expectEqual(iscene.Verdict.overflow, iscene.validate(&s2));
}

test "a span outside the pool is refused, never replayed (MOD-016)" {
    var s = freshSlot();
    // A matrix whose span points past what was actually pushed.
    iscene.record(&s, .{ .op = .load_matrix, .off = 4, .n = 16 });
    try std.testing.expectEqual(iscene.Verdict.bad_span, iscene.validate(&s));

    var s2 = freshSlot();
    iscene.record(&s2, .{ .op = .load_matrix, .off = 0, .n = 12 }); // not a matrix
    try std.testing.expectEqual(iscene.Verdict.bad_matrix, iscene.validate(&s2));
}

test "a draw past the provided vertex data is refused (MOD-016)" {
    var s = freshSlot();
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const off = iscene.pushFloats(&s, &verts);
    iscene.record(&s, .{ .op = .vertices, .off = off, .n = 3 });
    iscene.record(&s, .{ .op = .draw_arrays, .a = iscene.GL_TRIANGLES, .b = 1, .c = 3 });
    try std.testing.expectEqual(iscene.Verdict.draw_past_data, iscene.validate(&s));

    // A draw with NO vertex data at all is the same refusal.
    var s2 = freshSlot();
    iscene.record(&s2, .{ .op = .draw_arrays, .a = iscene.GL_TRIANGLES, .b = 0, .c = 3 });
    try std.testing.expectEqual(iscene.Verdict.draw_past_data, iscene.validate(&s2));
}

test "an index past the vertex data is refused (MOD-016)" {
    var s = freshSlot();
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const voff = iscene.pushFloats(&s, &verts);
    iscene.record(&s, .{ .op = .vertices, .off = voff, .n = 3 });
    const idx = [_]u16{ 0, 1, 3 }; // 3 does not exist
    const ioff = iscene.pushIndices(&s, &idx);
    iscene.record(&s, .{ .op = .draw_elements, .a = iscene.GL_TRIANGLES, .off = ioff, .n = 3 });
    try std.testing.expectEqual(iscene.Verdict.index_past_data, iscene.validate(&s));
}

test "an enum outside the accepted set is refused (MOD-016)" {
    // The per-vertex-colour path is unrepresentable (no such op), so the enum
    // gate is about caps and primitives: anything unlisted is a refusal.
    var s = freshSlot();
    iscene.record(&s, .{ .op = .enable, .a = 0x8078 }); // GL_TEXTURE_COORD_ARRAY
    try std.testing.expectEqual(iscene.Verdict.bad_enum, iscene.validate(&s));

    var s2 = freshSlot();
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const off = iscene.pushFloats(&s2, &verts);
    iscene.record(&s2, .{ .op = .vertices, .off = off, .n = 3 });
    iscene.record(&s2, .{ .op = .draw_arrays, .a = 0x0007, .b = 0, .c = 3 }); // GL_QUADS: not ES
    try std.testing.expectEqual(iscene.Verdict.bad_enum, iscene.validate(&s2));
}

test "the ABI's GL enums and the contract's agree (MOD-015)" {
    // A module compiles against abi.zig alone; the kernel validates against
    // iscene. If the two spell one value differently, every module frame is
    // refused as bad_enum — pin them equal here.
    const abi = @import("abi");
    try std.testing.expectEqual(abi.GL_MODELVIEW, iscene.GL_MODELVIEW);
    try std.testing.expectEqual(abi.GL_PROJECTION, iscene.GL_PROJECTION);
    try std.testing.expectEqual(abi.GL_TRIANGLES, iscene.GL_TRIANGLES);
    try std.testing.expectEqual(abi.GL_TRIANGLE_STRIP, iscene.GL_TRIANGLE_STRIP);
    try std.testing.expectEqual(abi.GL_TRIANGLE_FAN, iscene.GL_TRIANGLE_FAN);
    try std.testing.expectEqual(abi.GL_LINES, iscene.GL_LINES);
    try std.testing.expectEqual(abi.GL_DEPTH_TEST, iscene.GL_DEPTH_TEST);
    try std.testing.expectEqual(abi.GL_CULL_FACE, iscene.GL_CULL_FACE);
    try std.testing.expectEqual(abi.GL_LIGHTING, iscene.GL_LIGHTING);
    try std.testing.expectEqual(abi.GL_CW, iscene.GL_CW);
    try std.testing.expectEqual(abi.GL_CCW, iscene.GL_CCW);
}
