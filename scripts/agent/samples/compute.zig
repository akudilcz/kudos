//! A hand-written .kudos app that exercises more of the Api: allocate a buffer,
//! fill and sum it while cooperatively checking for cancellation, and print the
//! result hand-formatted: std.fmt is off-limits in a .kudos image — its writer
//! vtable emits function-pointer globals, which are load-time relocations the
//! position-independent contract forbids.

const abi = @import("abi.zig");

pub fn main(api: *const abi.Api) i32 {
    const n: usize = 100;
    const raw = api.alloc(api.ctx, n * @sizeOf(u32), 2) orelse {
        const msg = "alloc failed\n";
        api.print(api.ctx, msg, msg.len);
        return 1;
    };
    const buf: [*]u32 = @ptrCast(@alignCast(raw));

    var sum: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (api.cancelled(api.ctx)) return 2;
        buf[i] = @intCast(i + 1);
        sum += buf[i];
        api.yield(api.ctx);
    }

    var line: [64]u8 = undefined;
    var end = putStr(&line, 0, "sum(1..");
    end = putU64(&line, end, n);
    end = putStr(&line, end, ")=");
    end = putU64(&line, end, sum);
    end = putStr(&line, end, "\n");
    api.print(api.ctx, &line, end);
    return 0;
}

/// Append `v` in decimal at buf[at..]; returns the new end. Hand-rolled because
/// std.fmt's writer vtable emits function-pointer globals — load-time
/// relocations the position-independent .kudos contract forbids.
fn putU64(buf: []u8, at: usize, v: u64) usize {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        tmp[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
        if (x == 0) break;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[at + i] = tmp[n - 1 - i];
    return at + n;
}

fn putStr(buf: []u8, at: usize, s: []const u8) usize {
    for (s, 0..) |c, i| buf[at + i] = c;
    return at + s.len;
}
