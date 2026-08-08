//! Host tests of src/kernel/virt/netbridge.zig — the guest NIC bridge's
//! forwarding policy. The bridge is a switch with three kinds of port (the
//! wire, this host's stack, one per running guest), and every test here asks
//! the same two questions of one frame: which ports does it reach, and is the
//! caller left holding it?
//!
//! `offer` returning TRUE means the frame is wholly the guests' — the network
//! stack must then neither parse it nor put it on the wire — so the return
//! value is as much of the policy as the deliveries are, and every test checks
//! both.

const std = @import("std");
const netbridge = @import("testroot").kernel.netbridge;
const netdev = @import("testroot").kernel.virtio_netdev;
const ivirt = netdev.ivirt;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const A: ivirt.Id = 0;
const B: ivirt.Id = 1;

/// A MAC belonging to no guest — the gateway, say.
const OUTSIDE = [6]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
const BROADCAST = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
/// IPv6 all-nodes: the group bit is set but it is not broadcast, the case a
/// broadcast-only filter silently loses.
const MULTICAST = [6]u8{ 0x33, 0x33, 0x00, 0x00, 0x00, 0x01 };

/// One minimal Ethernet frame: destination, source, ethertype, one byte of
/// payload — enough to be forwarded and to be told apart from another.
fn frame(dst: [6]u8, src: [6]u8, tag: u8) [15]u8 {
    var f: [15]u8 = undefined;
    @memcpy(f[0..6], &dst);
    @memcpy(f[6..12], &src);
    f[12] = 0x08;
    f[13] = 0x00;
    f[14] = tag;
    return f;
}

/// Clear every mailbox slot and mark `running` ones live, so each test states
/// the machine it is describing.
fn machine(running: []const ivirt.Id) void {
    for (0..ivirt.MAX_VMS) |id| ivirt.reset(id);
    for (running) |id| ivirt.setState(id, .running);
}

/// The frame queued for guest `id`, or null — the guest's own core's view.
fn delivered(id: ivirt.Id, buf: []u8) ?usize {
    const len = ivirt.netPeek(id, buf) orelse return null;
    ivirt.netCommit(id);
    return len;
}

test "wire unicast to a guest is delivered to it and consumed (VIRT-029)" {
    machine(&.{ A, B });
    const f = frame(netdev.guestMac(A), OUTSIDE, 'a');
    try expect(netbridge.offer(null, &f));

    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    const len = delivered(A, &buf) orelse return error.NotDelivered;
    try expect(std.mem.eql(u8, &f, buf[0..len]));
    // Only the addressed guest: a bridge is not a hub.
    try expectEqual(@as(?usize, null), delivered(B, &buf));
}

test "wire unicast to no guest is left for the host stack (VIRT-029)" {
    machine(&.{A});
    const f = frame(OUTSIDE, OUTSIDE, 'a');
    try expect(!netbridge.offer(null, &f));
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    try expectEqual(@as(?usize, null), delivered(A, &buf));
}

test "wire unicast to a guest that is not running reaches nobody (VIRT-029)" {
    machine(&.{}); // slot A exists but has never run
    const f = frame(netdev.guestMac(A), OUTSIDE, 'a');
    try expect(!netbridge.offer(null, &f));
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    try expectEqual(@as(?usize, null), delivered(A, &buf));
}

test "wire broadcast and multicast reach every guest AND the host (VIRT-029)" {
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    for ([_][6]u8{ BROADCAST, MULTICAST }) |group| {
        machine(&.{ A, B });
        const f = frame(group, OUTSIDE, 'g');
        // False: an ARP request — or a neighbour solicitation — is everyone's,
        // so the host stack must still see it.
        try expect(!netbridge.offer(null, &f));
        for ([_]ivirt.Id{ A, B }) |id| {
            const len = delivered(id, &buf) orelse return error.NotDelivered;
            try expect(std.mem.eql(u8, &f, buf[0..len]));
        }
    }
}

test "a guest's broadcast reaches its siblings but never itself (VIRT-032)" {
    machine(&.{ A, B });
    const f = frame(BROADCAST, netdev.guestMac(A), 'a');
    try expect(!netbridge.offer(A, &f));

    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    // A switch never reflects a frame back down the port it arrived on: a guest
    // hearing its own broadcast would answer its own ARP requests.
    try expectEqual(@as(?usize, null), delivered(A, &buf));
    const len = delivered(B, &buf) orelse return error.NotDelivered;
    try expect(std.mem.eql(u8, &f, buf[0..len]));
}

test "a guest's unicast to a sibling is switched locally, not to the wire (VIRT-031)" {
    machine(&.{ A, B });
    const f = frame(netdev.guestMac(B), netdev.guestMac(A), 'a');
    // True: wholly the guests' — the caller must not also send it, because the
    // wire's switch would never bring it back down this port.
    try expect(netbridge.offer(A, &f));

    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    const len = delivered(B, &buf) orelse return error.NotDelivered;
    try expect(std.mem.eql(u8, &f, buf[0..len]));
    try expectEqual(@as(?usize, null), delivered(A, &buf));
}

test "a guest addressing its own MAC is consumed and goes nowhere" {
    machine(&.{A});
    const f = frame(netdev.guestMac(A), netdev.guestMac(A), 'a');
    try expect(netbridge.offer(A, &f)); // consumed: the wire must not see it
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    try expectEqual(@as(?usize, null), delivered(A, &buf));
}

test "a frame too short to carry addresses is nobody's" {
    machine(&.{A});
    const runt = [_]u8{0xFF} ** 13; // one byte short of an Ethernet header
    try expect(!netbridge.offer(null, &runt));
    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    try expectEqual(@as(?usize, null), delivered(A, &buf));
}

test "poll reports the port each frame came from, round-robin (VIRT-028)" {
    machine(&.{ A, B });
    try expect(ivirt.netPost(A, "from-a"));
    try expect(ivirt.netPost(B, "from-b"));

    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    var seen = [_]bool{false} ** ivirt.MAX_VMS;
    for (0..2) |_| {
        var from: netbridge.Port = null;
        const len = netbridge.poll(&buf, &from) orelse return error.NoFrame;
        const id = from orelse return error.NoPort;
        // The port is what makes local switching possible at all: it is the one
        // port the frame must not go back to.
        const expected = if (id == A) "from-a" else "from-b";
        try expect(std.mem.eql(u8, expected, buf[0..len]));
        try expect(!seen[id]); // round-robin: neither guest is served twice
        seen[id] = true;
    }
    var from: netbridge.Port = null;
    try expectEqual(@as(?usize, null), netbridge.poll(&buf, &from));
}

test "poll leaves a halted guest's queued frames off the wire" {
    machine(&.{A});
    try expect(ivirt.netPost(A, "queued-then-halted"));
    ivirt.setState(A, .halted);

    var buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
    var from: netbridge.Port = null;
    try expectEqual(@as(?usize, null), netbridge.poll(&buf, &from));
}

test "a port accepts only its own guest's source address (VIRT-033)" {
    machine(&.{ A, B });
    // Forwarding is decided purely on destination, so a guest allowed to send
    // as its sibling would have that sibling's replies delivered to itself.
    try expect(netbridge.portAccepts(A, &frame(OUTSIDE, netdev.guestMac(A), 'a')));
    try expect(!netbridge.portAccepts(A, &frame(OUTSIDE, netdev.guestMac(B), 'a')));
    try expect(!netbridge.portAccepts(A, &frame(OUTSIDE, OUTSIDE, 'a')));
    // A frame with no room for a source address cannot be attributed to anyone.
    try expect(!netbridge.portAccepts(A, &[_]u8{0xFF} ** 13));
}
