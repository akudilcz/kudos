//! Host tests of src/drivers/net/stack/roots.zig — the trusted-CA set the TLS
//! client verifies every HTTPS chain against (spec NET-011), and the
//! clock-validity floor that refuses HTTPS on a clock that cannot establish
//! certificate validity (spec NET-015). Runs against the REAL shipped bundle
//! (assets/net/cacert.pem, embedded by the build).

const std = @import("std");
const roots = @import("roots");

/// A believable "now" for parsing the shipped bundle: the floor itself, which
/// every current root's validity window comfortably spans.
const NOW = roots.CLOCK_VALIDITY_FLOOR_EPOCH_S;

/// The shipped bundle carries on the order of 150 roots; a parse that yields
/// fewer than this floor lost most of them and must fail the build.
const MIN_EXPECTED_ROOTS = 100;

test "the shipped PEM bundle parses into a usable trust set" {
    const a = std.testing.allocator;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(a);
    const stats = try roots.addPem(&bundle, a, @embedFile("cacert_pem"), NOW);
    try std.testing.expect(stats.loaded >= MIN_EXPECTED_ROOTS);
    try std.testing.expectEqual(stats.loaded, bundle.map.size);
}

test "clock validity: absent or impossibly early clocks refuse, sane clocks pass" {
    try std.testing.expect(!roots.clockEstablishesValidity(null));
    try std.testing.expect(!roots.clockEstablishesValidity(0));
    try std.testing.expect(!roots.clockEstablishesValidity(roots.CLOCK_VALIDITY_FLOOR_EPOCH_S - 1));
    try std.testing.expect(roots.clockEstablishesValidity(roots.CLOCK_VALIDITY_FLOOR_EPOCH_S));
    try std.testing.expect(roots.clockEstablishesValidity(roots.CLOCK_VALIDITY_FLOOR_EPOCH_S + 1));
}

test "a bundle with no certificate blocks loads nothing, loudly countable" {
    const a = std.testing.allocator;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(a);
    const stats = try roots.addPem(&bundle, a, "no pem here at all", NOW);
    try std.testing.expectEqual(@as(usize, 0), stats.loaded);
}

test "a truncated block (no END marker) is a hard error" {
    const a = std.testing.allocator;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(a);
    const pem = "-----BEGIN CERTIFICATE-----\nAAAA\n";
    try std.testing.expectError(error.MissingEndCertificateMarker, roots.addPem(&bundle, a, pem, NOW));
}

test "a malformed block is skipped and counted, not fatal" {
    const a = std.testing.allocator;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(a);
    const pem = "-----BEGIN CERTIFICATE-----\n!!!not base64!!!\n-----END CERTIFICATE-----\n";
    const stats = try roots.addPem(&bundle, a, pem, NOW);
    try std.testing.expectEqual(@as(usize, 0), stats.loaded);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped);
}

test "ensure builds the kernel bundle once and is idempotent" {
    // The kernel singleton is deliberately never freed, so this test uses the
    // page allocator rather than the leak-checking test allocator.
    const a = std.heap.page_allocator;
    try std.testing.expect(roots.bundle() == null); // untouched before ensure
    const first = try roots.ensure(a, @embedFile("cacert_pem"), NOW);
    try std.testing.expect(first.loaded >= MIN_EXPECTED_ROOTS);
    try std.testing.expect(roots.bundle() != null);
    const again = try roots.ensure(a, @embedFile("cacert_pem"), NOW);
    try std.testing.expectEqual(first.loaded, again.loaded);
    try std.testing.expectEqual(@as(usize, 0), again.skipped);
}
