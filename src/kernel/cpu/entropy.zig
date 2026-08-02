//! Hardware entropy — RDRAND, the only randomness source on this machine
//! (spec R4 names randomness a real seam; this is its one implementation).
//! Seeds std.crypto's CSPRNG for TLS via the root `std_options` hook. No
//! RDRAND → no entropy: consumers fail loudly (an https fetch errors) rather
//! than run on a guessable stream.

const std = @import("std");
const cpu = @import("cpu.zig");

const CPUID_FEATURES_LEAF: u32 = 1;
const ECX_RDRAND_BIT: u32 = 1 << 30;

/// Retries per 64-bit draw. Intel's DRNG guide: the DRBG refills fast enough
/// that 10 retries make failure "astronomically unlikely" on working silicon.
const RDRAND_RETRIES: u8 = 10;

/// Whether this CPU has RDRAND at all (CPUID.01H:ECX[30]).
pub fn available() bool {
    return cpu.cpuid(CPUID_FEATURES_LEAF, 0).ecx & ECX_RDRAND_BIT != 0;
}

/// One 64-bit hardware draw, or null when the DRBG would not deliver.
fn draw64() ?u64 {
    var attempt: u8 = 0;
    while (attempt < RDRAND_RETRIES) : (attempt += 1) {
        var ok: u8 = undefined;
        var v: u64 = undefined;
        asm volatile ("rdrand %[v]; setc %[ok]"
            : [v] "=r" (v),
              [ok] "=r" (ok),
        );
        if (ok != 0) return v;
    }
    return null;
}

/// Fill `buf` with hardware entropy. Returns false (buffer untouched beyond
/// what was written) when RDRAND is absent or persistently failing — the
/// caller must treat that as "no entropy exists", never as zeroes.
pub fn fill(buf: []u8) bool {
    if (!available()) return false;
    var i: usize = 0;
    while (i < buf.len) {
        const v = draw64() orelse return false;
        const n = @min(8, buf.len - i);
        @memcpy(buf[i .. i + n], std.mem.asBytes(&v)[0..n]);
        i += n;
    }
    return true;
}

/// The `std.Options.cryptoRandomSeed` hook (wired in main/main_smp): seed
/// std.crypto's CSPRNG from RDRAND. A machine with no RDRAND panics HERE,
/// at first use — better a loud stop than TLS keys from a constant.
pub fn cryptoRandomSeed(buffer: []u8) void {
    if (!fill(buffer)) @panic("entropy: RDRAND unavailable — cannot seed std.crypto (https needs it)");
}
