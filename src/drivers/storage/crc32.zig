//! CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320).
//!
//! A checksum over a file's bytes: change one bit anywhere and the number changes. The
//! ramdisk stamps one on every file so a reader across the network can tell whether the
//! copy it holds is still the copy we have, without sending the file back.
//!
//! Pure — no hardware, no allocation — so it is host-tested against the standard vectors.

const table = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        t[i] = c;
    }
    break :blk t;
};

pub fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFF_FFFF;
    for (data) |b| c = table[(c ^ b) & 0xff] ^ (c >> 8);
    return c ^ 0xFFFF_FFFF;
}
