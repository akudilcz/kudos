//! The guest NIC bridge's forwarding policy: which port an Ethernet frame is
//! for. kudos' guests share the machine's one physical NIC at layer 2, and this
//! file is the whole decision — a learning-free switch whose table is fixed,
//! because every guest's address is derived from its mailbox slot
//! (netdev.guestMac) rather than learned from traffic.
//!
//! The ports are the wire, the host's own stack, and one per running guest.
//! Two rules cover every frame: a frame goes to the port its DESTINATION names
//! (all of them, for a group address), and never back to the port it came in
//! on. The network stack owns the wire and host ports and calls in here through
//! its Bridge hook; this file owns the guest ports.
//!
//! Pure policy over the ivirt mailbox, so it is host-tested
//! (test/kernel/virt/netbridge_test.zig) rather than reasoned about: the
//! forwarding rules are exactly the kind of thing that looks obviously right
//! and is not.

const std = @import("std");
const ivirt = @import("ivirt");
const inet = @import("inet");
const netdev = @import("virtio/netdev.zig");

/// The port a frame entered the bridge on, when that port is a guest — null for
/// the two ports this file does not own, the physical wire and the host's own
/// stack. Which guest is all forwarding needs from a frame's origin, since the
/// only rule that depends on it is that nothing goes back out the port it came
/// in on, and neither non-guest port is one the guest ports send back to.
pub const Port = ?ivirt.Id;

/// The destination address of `frame`, or null when it is too short to have one.
fn destination(frame: []const u8) ?*const [inet.ETHER_ADDR_BYTES]u8 {
    if (frame.len < inet.ETHER_HEADER_BYTES) return null;
    return frame[inet.ETHER_DST_OFF..][0..inet.ETHER_ADDR_BYTES];
}

/// Offer one frame, entering on port `from`, to the guest ports. Returns true
/// when the frame is wholly the guests' — the caller must then neither parse it
/// nor put it on the wire.
///
/// A unicast frame addressed to a running guest is that guest's alone. A group
/// address (broadcast or multicast) is copied to every running guest and still
/// returns false, because it belongs to the host stack too — an ARP request is
/// everyone's. Nothing is ever forwarded back to `from`. A full guest ring
/// counts the drop in ivirt (VIRT-030); the frame is still consumed, because a
/// frame addressed to a guest is not the host's to parse whether or not the
/// guest had room for it.
pub fn offer(from: Port, frame: []const u8) bool {
    const dst = destination(frame) orelse return false;
    if (dst[0] & inet.ETHER_GROUP_BIT != 0) {
        for (0..ivirt.MAX_VMS) |id| {
            if (from) |src| if (src == id) continue; // never back out its own port
            if (ivirt.state(id) == .running) _ = ivirt.netDeliver(id, frame);
        }
        return false;
    }
    const id = netdev.guestIdFor(dst) orelse return false;
    // A guest addressing its own MAC: no port left to forward it to, and the
    // wire must not see it either, so the bridge consumes and discards it.
    if (from) |src| if (src == id) return true;
    if (ivirt.state(id) != .running) return false;
    _ = ivirt.netDeliver(id, frame);
    return true;
}

/// Round-robin cursor for `poll`, so one chatty guest cannot starve another of
/// the wire.
var next_port: ivirt.Id = 0;

/// Copy the next guest-transmitted frame into `buf`, report the port it came
/// from in `from`, and return its length — or null when no guest has anything
/// to send. Only a running guest is drained: frames queued before a guest
/// halted are not its successor's to send, and putting a torn-down connection's
/// segments on the wire would be noise attributed to this machine.
pub fn poll(buf: []u8, from: *Port) ?usize {
    for (0..ivirt.MAX_VMS) |i| {
        const id = (next_port + i) % ivirt.MAX_VMS;
        if (ivirt.state(id) != .running) continue;
        if (ivirt.netFetch(id, buf)) |len| {
            next_port = (id + 1) % ivirt.MAX_VMS;
            from.* = id;
            return len;
        }
    }
    return null;
}

/// Whether guest `id`'s port accepts `frame` from the guest — that is, whether
/// the guest is sending as itself. A bridge port answers for exactly one
/// address (VIRT-027, VIRT-033); since forwarding is decided purely on
/// destination, a guest allowed to claim a sibling's or the host's source
/// address could have that machine's replies delivered to itself.
pub fn portAccepts(id: ivirt.Id, frame: []const u8) bool {
    if (frame.len < inet.ETHER_HEADER_BYTES) return false;
    const src = frame[inet.ETHER_SRC_OFF..][0..inet.ETHER_ADDR_BYTES];
    return std.mem.eql(u8, src, &netdev.guestMac(id));
}
