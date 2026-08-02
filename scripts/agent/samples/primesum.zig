//! Stand-in for what the agent's model would generate from "build me a zig app
//! that adds the first 20 prime numbers". Sums the first 20 primes and prints
//! the total (639).

const abi = @import("abi.zig");

fn isPrime(n: u32) bool {
    if (n < 2) return false;
    var d: u32 = 2;
    while (d * d <= n) : (d += 1) if (n % d == 0) return false;
    return true;
}

pub fn main(api: *const abi.Api) i32 {
    var found: u32 = 0;
    var sum: u64 = 0;
    var n: u32 = 2;
    while (found < 20) : (n += 1) {
        if (api.cancelled(api.ctx)) return 2;
        if (isPrime(n)) {
            sum += n;
            found += 1;
        }
    }
    var line: [64]u8 = undefined;
    var end = putStr(&line, 0, "sum of first 20 primes = ");
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
