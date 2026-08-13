//! RamdiskSim — the iramdisk.IRamdisk fake for host tests (the triple:
//! iramdisk.zig contract / ramdisk.zig real / this sim).

const std = @import("std");
const iramdisk = @import("iramdisk");

pub const RamdiskSim = struct {
    const MAX = 8;
    /// Bytes one stored file may hold. The real ramdisk copies to the heap; this
    /// fake copies to fixed storage rather than retaining the caller's slice — a
    /// caller reusing its request buffer would otherwise corrupt a stored file,
    /// which the hardware store cannot do. A fake must fail only the ways the
    /// real thing fails.
    const DATA_MAX = 4096;
    names: [MAX][]const u8 = undefined,
    datas: [MAX][DATA_MAX]u8 = undefined,
    lens: [MAX]usize = undefined,
    gens: [MAX]u32 = undefined,
    n: usize = 0,

    pub fn add(self: *RamdiskSim, name: []const u8, data: []const u8, generation: u32) void {
        std.debug.assert(data.len <= DATA_MAX);
        self.names[self.n] = name;
        @memcpy(self.datas[self.n][0..data.len], data);
        self.lens[self.n] = data.len;
        self.gens[self.n] = generation;
        self.n += 1;
    }

    fn vtPut(ctx: *anyopaque, name: []const u8, data: []const u8) iramdisk.PutError!void {
        const self: *RamdiskSim = @ptrCast(@alignCast(ctx));
        if (data.len > DATA_MAX) return error.OutOfMemory;
        for (0..self.n) |i| {
            if (std.mem.eql(u8, self.names[i], name)) {
                @memcpy(self.datas[i][0..data.len], data);
                self.lens[i] = data.len;
                self.gens[i] += 1;
                return;
            }
        }
        if (self.n == MAX) return error.OutOfMemory;
        self.add(name, data, 1);
    }
    fn vtGet(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *RamdiskSim = @ptrCast(@alignCast(ctx));
        for (0..self.n) |i| if (std.mem.eql(u8, self.names[i], name)) return self.datas[i][0..self.lens[i]];
        return null;
    }
    fn vtCount(ctx: *anyopaque) usize {
        const self: *RamdiskSim = @ptrCast(@alignCast(ctx));
        return self.n;
    }
    fn vtAt(ctx: *anyopaque, i: usize) iramdisk.Entry {
        const self: *RamdiskSim = @ptrCast(@alignCast(ctx));
        return .{
            .name = self.names[i],
            .data = self.datas[i][0..self.lens[i]],
            .generation = self.gens[i],
            .crc32 = crc32(self.datas[i][0..self.lens[i]]),
        };
    }

    const vtable = iramdisk.IRamdisk.VTable{ .put = vtPut, .get = vtGet, .count = vtCount, .at = vtAt };

    pub fn fs(self: *RamdiskSim) iramdisk.IRamdisk {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }
};

/// Same IEEE CRC-32 the kernel uses. A local copy because Zig admits a file to one
/// module only: `crc32.zig` already reaches the suites through `testroot`, so a second
/// module rooted at it collides wherever a test imports both.
fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFF_FFFF;
    for (data) |b| {
        c ^= b;
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
    }
    return c ^ 0xFFFF_FFFF;
}
