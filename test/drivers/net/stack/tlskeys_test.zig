//! Host tests of src/drivers/net/stack/tlskeys.zig — the TLS 1.3 handshake key
//! schedule, against the PUBLISHED vectors of RFC 8448 §3 ("Simple 1-RTT
//! Handshake"). Standard primitives validated against published test vectors is
//! the crypto-hygiene rule (process.md §44); this suite is where NET-010's
//! derivation is held to it.
//!
//! Every expectation below is copied from RFC 8448's own trace, not from this
//! implementation's output — a self-consistency test would pass just as
//! happily on a schedule that derived the wrong keys all the way down.

const std = @import("std");
const tlskeys = @import("tlskeys");

/// TLS_AES_128_GCM_SHA256 — the suite RFC 8448 §3 traces.
const P = struct {
    pub const Hash = std.crypto.hash.sha2.Sha256;
    pub const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    pub const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    pub const AEAD = std.crypto.aead.aes_gcm.Aes128Gcm;
};

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

fn expectHex(comptime expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualSlices(u8, &hex(expected), actual);
}

// RFC 8448 §3: the ECDHE shared secret and the ClientHello..ServerHello
// transcript hash of that trace — the schedule's only two inputs.
const SHARED_SECRET = "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d";
const HELLO_HASH = "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8";

test "the handshake secret matches RFC 8448 (NET-010)" {
    const ks = tlskeys.handshake(P, &hex(SHARED_SECRET), &hex(HELLO_HASH));
    // "{server} extract secret 'handshake'" — the whole early-secret →
    // derived → extract chain lands here, so a wrong label or a skipped
    // derive shows up as a different secret.
    try expectHex("1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac", &ks.handshake_secret);
}

test "both handshake traffic secrets match RFC 8448 (NET-010)" {
    const ks = tlskeys.handshake(P, &hex(SHARED_SECRET), &hex(HELLO_HASH));
    // Swapping the "c hs traffic"/"s hs traffic" labels is a silent disaster:
    // the handshake still completes, each side decrypting with the other's
    // key material only because both are wrong the same way.
    try expectHex("b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21", &ks.client_secret);
    try expectHex("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38", &ks.server_secret);
}

test "the AEAD write keys and IVs match RFC 8448, per direction (NET-010)" {
    const ks = tlskeys.handshake(P, &hex(SHARED_SECRET), &hex(HELLO_HASH));
    // "{server} derive write traffic keys for handshake data" and the client's
    // equivalent. Key and IV expand from the same secret under different
    // labels and lengths — the pairing is what the vectors pin.
    try expectHex("dbfaa693d1762c5b666af5d950258d01", &ks.client_key);
    try expectHex("5bd3c71b836e0b76bb73265f", &ks.client_iv);
    try expectHex("3fce516009c21727d0f2e4e86ee403bc", &ks.server_key);
    try expectHex("5d313eb2671276ee13000b30", &ks.server_iv);
}

test "the finished keys and the master secret match RFC 8448 (NET-010)" {
    const ks = tlskeys.handshake(P, &hex(SHARED_SECRET), &hex(HELLO_HASH));
    // The finished keys authenticate the transcript: get these wrong and the
    // handshake fails closed. The master secret is derived here but consumed
    // later, by the application-traffic phase.
    try expectHex("b80ad01015fb2f0bd65ff7d4da5d6bf83f84821d1f87fdc7d3c75b5a7b42d9c4", &ks.client_finished_key);
    try expectHex("008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8", &ks.server_finished_key);
    try expectHex("18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919", &ks.master_secret);
}

test "a different transcript hash derives entirely different traffic keys" {
    // The transcript binding is the whole point of feeding the hello hash in:
    // a handshake spliced onto a different transcript must not reuse keys.
    const ks = tlskeys.handshake(P, &hex(SHARED_SECRET), &hex(HELLO_HASH));
    var other = hex(HELLO_HASH);
    other[0] ^= 1;
    const ks2 = tlskeys.handshake(P, &hex(SHARED_SECRET), &other);
    try std.testing.expect(!std.mem.eql(u8, &ks.client_key, &ks2.client_key));
    try std.testing.expect(!std.mem.eql(u8, &ks.server_key, &ks2.server_key));
    // ...while the handshake secret, derived before the transcript enters, is
    // unchanged — which is what makes the traffic-key difference meaningful.
    try std.testing.expectEqualSlices(u8, &ks.handshake_secret, &ks2.handshake_secret);
}
