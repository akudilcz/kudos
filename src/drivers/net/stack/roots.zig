//! The trusted certificate-authority set for HTTPS (spec NET-011): a PEM
//! bundle of root certificates parsed ONCE into the std.crypto certificate
//! bundle that the TLS client verifies every server chain against. The kernel
//! embeds `assets/net/cacert.pem` and hands its bytes in; this module is pure
//! over those bytes, so the same parse runs in the host test.
//!
//! Also home to the clock-validity rule (spec NET-015): certificate validity
//! is a statement about REAL time, so a wall clock that is absent or
//! impossibly early refuses the connection rather than skipping the check.

const std = @import("std");
const Bundle = std.crypto.Certificate.Bundle;

/// Any wall-clock reading earlier than this instant (2025-01-01T00:00:00Z) is
/// certainly wrong — the trust bundle itself postdates it — so such a clock
/// cannot establish certificate validity and the connection must be refused
/// (NET-015), never verified against fantasy time.
pub const CLOCK_VALIDITY_FLOOR_EPOCH_S: i64 = 1_735_689_600;

/// Whether a wall-clock reading can support a certificate-validity decision:
/// present, and no earlier than the floor above.
pub fn clockEstablishesValidity(now_sec: ?i64) bool {
    const now = now_sec orelse return false;
    return now >= CLOCK_VALIDITY_FLOOR_EPOCH_S;
}

/// What one PEM load did: `loaded` roots now in the bundle, `skipped` blocks
/// the parser rejected or deduplicated (expired, unsupported, repeated).
pub const LoadStats = struct { loaded: usize, skipped: usize };

const BEGIN_MARKER = "-----BEGIN CERTIFICATE-----";
const END_MARKER = "-----END CERTIFICATE-----";
const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

/// Parse every certificate block of `pem` into `dest`. A block that fails to
/// decode or parse is skipped and counted, never fatal — one exotic root must
/// not cost the other hundred — but an empty result is the caller's loud error.
pub fn addPem(dest: *Bundle, gpa: std.mem.Allocator, pem: []const u8, now_sec: i64) !LoadStats {
    const decoded_size_upper_bound = pem.len / 4 * 3;
    try dest.bytes.ensureUnusedCapacity(gpa, decoded_size_upper_bound);

    var blocks: usize = 0;
    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, BEGIN_MARKER)) |begin_start| {
        const cert_start = begin_start + BEGIN_MARKER.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, END_MARKER) orelse
            return error.MissingEndCertificateMarker;
        start_index = cert_end + END_MARKER.len;
        blocks += 1;

        const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
        const decoded_start: u32 = @intCast(dest.bytes.items.len);
        const room = dest.bytes.allocatedSlice()[decoded_start..];
        const n = base64.decode(room, encoded) catch {
            dest.bytes.items.len = decoded_start;
            continue;
        };
        dest.bytes.items.len += n;
        // parseCert itself rolls back and returns cleanly for certs it chooses
        // to skip (unsupported object ids, expired); a hard error is one
        // malformed block — roll back and count it, keep the rest.
        dest.parseCert(gpa, decoded_start, now_sec) catch {
            dest.bytes.items.len = decoded_start;
            continue;
        };
    }
    return .{ .loaded = dest.map.size, .skipped = blocks - dest.map.size };
}

// ── the kernel's one bundle, built on first use ───────────────────────────────

var g_bundle: Bundle = .empty;
var g_ready = false;

/// Build the kernel's trust bundle from `pem` if not yet built (idempotent —
/// later calls are free). Fails when NO root parsed: an empty trust set can
/// verify nothing, and pretending otherwise would fail every connection with a
/// misleading error far from this cause.
pub fn ensure(gpa: std.mem.Allocator, pem: []const u8, now_sec: i64) !LoadStats {
    if (g_ready) return .{ .loaded = g_bundle.map.size, .skipped = 0 };
    const stats = try addPem(&g_bundle, gpa, pem, now_sec);
    if (stats.loaded == 0) return error.NoTrustedRoots;
    g_ready = true;
    return stats;
}

/// The built trust bundle (call `ensure` first; null before that).
pub fn bundle() ?Bundle {
    return if (g_ready) g_bundle else null;
}

/// The trust bundle BY POINTER, for the TLS client, which verifies each chain
/// against it in place rather than against a copy. Null until `ensure` has built
/// it, for the same reason `bundle` is: an empty bundle verifies nothing, and
/// handing one out would fail every connection far from the real cause.
pub fn bundlePtr() ?*Bundle {
    return if (g_ready) &g_bundle else null;
}
