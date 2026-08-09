//! The agent's service credential, sealed (spec AGT-017).
//!
//! The credential is an account secret with a bill attached, and kudos needs it
//! at every request. Reading it from a file on the USB stick (AGT-004) keeps it
//! out of the source tree but makes the agent unusable on a machine with no
//! stick — every emulator run, and this laptop. Sealing it into the image
//! instead trades that away for a different property: the image and the build
//! tree hold CIPHERTEXT, so the credential is not a string anybody can grep out
//! of a binary, a core dump, or a repository.
//!
//! What this is NOT: protection against someone holding both the sealed blob
//! and the passphrase. A passphrase carried in the same image as the blob makes
//! the pair openable by anyone who has the image — the seal raises the cost of
//! finding the credential, it does not keep a determined reader out. The one
//! guarantee worth stating is the one this buys: the plaintext credential never
//! exists on disk, in the build tree, or in the binary.
//!
//! Format (`Envelope`): a 4-byte magic, a PBKDF2 salt, a ChaCha20-Poly1305
//! nonce and tag, then the ciphertext. Authenticated, so a wrong passphrase and
//! a corrupted blob are the SAME error — the tag fails either way, and the
//! module never returns half-decrypted bytes as if they were a credential.
//!
//! Pure: bytes in, bytes out, no IO and no allocation. The sealing side is
//! scripts/agent/sealkey.zig, which calls `seal` below rather than
//! reimplementing it — one definition of the format, not two that agree until
//! somebody edits one of them.

const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Prf = std.crypto.auth.hmac.sha2.HmacSha256;

/// Envelope magic — "Kudos Sealed Envelope", version 1. Checked before anything
/// else so a truncated or unrelated file is reported as such rather than as a
/// wrong passphrase, which would send an operator looking in the wrong place.
pub const MAGIC = "KSE1".*;

pub const SALT_BYTES = 16;
pub const NONCE_BYTES = Aead.nonce_length;
pub const TAG_BYTES = Aead.tag_length;
pub const KEY_BYTES = Aead.key_length;

/// Bytes before the ciphertext: magic, salt, nonce, tag.
pub const HEADER_BYTES = MAGIC.len + SALT_BYTES + NONCE_BYTES + TAG_BYTES;

/// PBKDF2-HMAC-SHA256 iterations. High enough that guessing the passphrase
/// costs real time per attempt, low enough that unsealing is imperceptible
/// against the network round trip that follows it. One home: the sealing script
/// reads this value from here rather than repeating it.
pub const ITERATIONS: u32 = 200_000;

/// Longest credential this module will unseal. An OpenRouter key is about 73
/// characters; the bound is generous and exists so the output buffer is a fixed
/// size the caller can hold in a global.
pub const MAX_SECRET_BYTES = 128;

pub const Error = error{
    /// Not a sealed envelope at all — wrong magic, or too short to hold one.
    NotSealed,
    /// The envelope is well-formed and did not authenticate: a wrong passphrase
    /// or a damaged blob, indistinguishable by design.
    BadPassphrase,
    /// The sealed secret does not fit `out`.
    SecretTooLong,
};

/// Derive the envelope key from `passphrase` and `salt`.
fn deriveKey(passphrase: []const u8, salt: []const u8) [KEY_BYTES]u8 {
    var k: [KEY_BYTES]u8 = undefined;
    // The only failure PBKDF2 defines is a derived length far beyond what any
    // cipher uses; a 32-byte key cannot reach it.
    std.crypto.pwhash.pbkdf2(&k, passphrase, salt, ITERATIONS, Prf) catch unreachable;
    return k;
}

/// Open `envelope` with `passphrase`, writing the credential into `out` and
/// returning the slice of it that holds the credential.
pub fn unseal(envelope: []const u8, passphrase: []const u8, out: []u8) Error![]const u8 {
    if (envelope.len < HEADER_BYTES) return Error.NotSealed;
    if (!std.mem.eql(u8, envelope[0..MAGIC.len], &MAGIC)) return Error.NotSealed;

    var off: usize = MAGIC.len;
    const salt = envelope[off..][0..SALT_BYTES];
    off += SALT_BYTES;
    const nonce = envelope[off..][0..NONCE_BYTES].*;
    off += NONCE_BYTES;
    const tag = envelope[off..][0..TAG_BYTES].*;
    off += TAG_BYTES;
    const ct = envelope[off..];

    if (ct.len > out.len) return Error.SecretTooLong;

    const key = deriveKey(passphrase, salt);
    // Authenticated decryption: `out` is only meaningful if this returns. A
    // wrong passphrase fails the tag, so there is no path on which a caller
    // receives plausible-looking rubbish and posts it as a credential.
    Aead.decrypt(out[0..ct.len], ct, tag, &.{}, nonce, key) catch return Error.BadPassphrase;
    return out[0..ct.len];
}

/// Seal `secret` under `passphrase` into `out`, returning the envelope. The
/// kernel never calls this — it exists so the format has ONE definition that
/// the host-side sealer is tested against, rather than two that agree until
/// someone edits one of them.
pub fn seal(
    secret: []const u8,
    passphrase: []const u8,
    salt: [SALT_BYTES]u8,
    nonce: [NONCE_BYTES]u8,
    out: []u8,
) error{NoSpace}![]const u8 {
    if (out.len < HEADER_BYTES + secret.len) return error.NoSpace;
    var off: usize = 0;
    @memcpy(out[off..][0..MAGIC.len], &MAGIC);
    off += MAGIC.len;
    @memcpy(out[off..][0..SALT_BYTES], &salt);
    off += SALT_BYTES;
    @memcpy(out[off..][0..NONCE_BYTES], &nonce);
    off += NONCE_BYTES;
    const tag_at = off;
    off += TAG_BYTES;

    var tag: [TAG_BYTES]u8 = undefined;
    const key = deriveKey(passphrase, &salt);
    Aead.encrypt(out[off..][0..secret.len], &tag, secret, &.{}, nonce, key);
    @memcpy(out[tag_at..][0..TAG_BYTES], &tag);
    return out[0 .. off + secret.len];
}

/// Decode the base64 form the build embeds (build options carry text, and a
/// binary blob in a generated Zig string literal is a needless escaping
/// hazard), then unseal it.
pub fn unsealBase64(b64: []const u8, passphrase: []const u8, out: []u8) Error![]const u8 {
    var raw: [HEADER_BYTES + MAX_SECRET_BYTES]u8 = undefined;
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return Error.NotSealed;
    if (n > raw.len) return Error.SecretTooLong;
    dec.decode(raw[0..n], b64) catch return Error.NotSealed;
    return unseal(raw[0..n], passphrase, out);
}
