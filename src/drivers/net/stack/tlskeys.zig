//! The TLS 1.3 handshake key schedule (RFC 8446 §7.1) — pure derivation, no
//! IO and no session state: shared secret plus transcript hash in, every
//! handshake secret and traffic key out.
//!
//! It lives apart from the client that drives it because this is precisely the
//! code whose defects are invisible in testing and catastrophic in the field:
//! a mislabelled `HKDF-Expand-Label`, a transcript hash taken a message too
//! late, or a key and IV swapped still produce a confident-looking handshake
//! that has thrown away its confidentiality. Derivations must be checked
//! against published vectors (NET-010, process.md §44), and only a pure
//! function can be.

const std = @import("std");
const tls = std.crypto.tls;

/// Every secret and key the handshake phase derives, for one cipher suite `P`
/// (the suite parameter type: `Hash`, `Hkdf`, `Hmac`, `AEAD`).
pub fn Handshake(comptime P: type) type {
    return struct {
        /// Kept for the application-traffic phase, which derives from it.
        handshake_secret: [P.Hash.digest_length]u8,
        master_secret: [P.Hash.digest_length]u8,
        /// The traffic secrets themselves — the key-log format names these,
        /// and the application phase re-derives from `master_secret`.
        client_secret: [P.Hash.digest_length]u8,
        server_secret: [P.Hash.digest_length]u8,
        client_finished_key: [P.Hmac.key_length]u8,
        server_finished_key: [P.Hmac.key_length]u8,
        client_key: [P.AEAD.key_length]u8,
        server_key: [P.AEAD.key_length]u8,
        client_iv: [P.AEAD.nonce_length]u8,
        server_iv: [P.AEAD.nonce_length]u8,
    };
}

/// Derive the handshake schedule from the ECDHE shared secret and the
/// ClientHello..ServerHello transcript hash.
///
/// The chain is RFC 8446 §7.1's, in order: extract the early secret from
/// nothing, `derived` it, extract the handshake secret over the shared
/// secret, then branch — the master secret for later, and each side's
/// traffic secret, from which its finished key, AEAD key and IV expand. The
/// early-secret salt is one zero byte rather than a zero block because HMAC
/// pads a short key with zeros to the block size: the two are the same key,
/// and the RFC's own vector confirms it.
pub fn handshake(
    comptime P: type,
    shared_secret: []const u8,
    hello_hash: []const u8,
) Handshake(P) {
    const zeroes = [1]u8{0} ** P.Hash.digest_length;
    const early_secret = P.Hkdf.extract(&[1]u8{0}, &zeroes);
    const empty_hash = tls.emptyHash(P.Hash);

    const hs_derived = tls.hkdfExpandLabel(P.Hkdf, early_secret, "derived", &empty_hash, P.Hash.digest_length);
    const handshake_secret = P.Hkdf.extract(&hs_derived, shared_secret);
    const ap_derived = tls.hkdfExpandLabel(P.Hkdf, handshake_secret, "derived", &empty_hash, P.Hash.digest_length);
    const master_secret = P.Hkdf.extract(&ap_derived, &zeroes);

    const client_secret = tls.hkdfExpandLabel(P.Hkdf, handshake_secret, "c hs traffic", hello_hash, P.Hash.digest_length);
    const server_secret = tls.hkdfExpandLabel(P.Hkdf, handshake_secret, "s hs traffic", hello_hash, P.Hash.digest_length);

    return .{
        .handshake_secret = handshake_secret,
        .master_secret = master_secret,
        .client_secret = client_secret,
        .server_secret = server_secret,
        .client_finished_key = tls.hkdfExpandLabel(P.Hkdf, client_secret, "finished", "", P.Hmac.key_length),
        .server_finished_key = tls.hkdfExpandLabel(P.Hkdf, server_secret, "finished", "", P.Hmac.key_length),
        .client_key = tls.hkdfExpandLabel(P.Hkdf, client_secret, "key", "", P.AEAD.key_length),
        .server_key = tls.hkdfExpandLabel(P.Hkdf, server_secret, "key", "", P.AEAD.key_length),
        .client_iv = tls.hkdfExpandLabel(P.Hkdf, client_secret, "iv", "", P.AEAD.nonce_length),
        .server_iv = tls.hkdfExpandLabel(P.Hkdf, server_secret, "iv", "", P.AEAD.nonce_length),
    };
}
