//! Host tests of the agent's sealed credential store (spec AGT-017).
//!
//! The property that matters is negative: nothing but the right passphrase
//! yields bytes, and a failure is a failure rather than a plausible-looking
//! string the agent would then post to a paid API as if it were a credential.

const std = @import("std");
const keystore = @import("keystore");

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

const SECRET = "sk-or-v1-this-is-a-test-fixture-not-a-credential-xxxxxxxxxxxxxxxxxxxxxx";
const SALT: [keystore.SALT_BYTES]u8 = @splat(0x5A);
const NONCE: [keystore.NONCE_BYTES]u8 = @splat(0x11);

fn sealed(buf: []u8, passphrase: []const u8) ![]const u8 {
    return keystore.seal(SECRET, passphrase, SALT, NONCE, buf);
}

test "a sealed credential comes back byte-exact under its passphrase (AGT-017)" {
    var env: [256]u8 = undefined;
    var out: [keystore.MAX_SECRET_BYTES]u8 = undefined;

    const blob = try sealed(&env, "welcome");
    try expectEqualStrings(SECRET, try keystore.unseal(blob, "welcome", &out));
}

test "the sealed blob does not contain the credential (AGT-017)" {
    var env: [256]u8 = undefined;
    const blob = try sealed(&env, "welcome");

    // The whole point of sealing: the credential is not a string anybody can
    // find by scanning the image. A cipher accidentally wired as a passthrough
    // would still round-trip perfectly and pass every other test here.
    try expect(std.mem.indexOf(u8, blob, SECRET) == null);
    try expect(std.mem.indexOf(u8, blob, SECRET[0..16]) == null);
    // Nor is it merely reordered: no 8-byte run of the credential survives.
    var i: usize = 0;
    while (i + 8 <= SECRET.len) : (i += 1) {
        try expect(std.mem.indexOf(u8, blob, SECRET[i .. i + 8]) == null);
    }
}

test "a wrong passphrase yields an error, never bytes (AGT-017)" {
    var env: [256]u8 = undefined;
    var out: [keystore.MAX_SECRET_BYTES]u8 = undefined;
    const blob = try sealed(&env, "welcome");

    // Authenticated decryption is what makes this an error rather than 73
    // characters of rubbish. Unauthenticated, a wrong passphrase would produce
    // a perfectly plausible string, which the agent would then send to a paid
    // API — and the failure would surface as an opaque HTTP 401 rather than as
    // "your passphrase is wrong".
    try expectError(keystore.Error.BadPassphrase, keystore.unseal(blob, "welcom", &out));
    try expectError(keystore.Error.BadPassphrase, keystore.unseal(blob, "Welcome", &out));
    try expectError(keystore.Error.BadPassphrase, keystore.unseal(blob, "", &out));
}

test "a tampered envelope fails the tag (AGT-017)" {
    var env: [256]u8 = undefined;
    var out: [keystore.MAX_SECRET_BYTES]u8 = undefined;
    const blob = try sealed(&env, "welcome");

    // Every byte after the magic is covered: flipping one anywhere must fail.
    var i: usize = keystore.MAGIC.len;
    while (i < blob.len) : (i += 1) {
        env[i] ^= 0x01;
        try expectError(keystore.Error.BadPassphrase, keystore.unseal(env[0..blob.len], "welcome", &out));
        env[i] ^= 0x01;
    }
    // ...and the unmodified blob still opens, so the loop above proved damage
    // detection rather than a blob broken from the start.
    try expectEqualStrings(SECRET, try keystore.unseal(env[0..blob.len], "welcome", &out));
}

test "something that is not an envelope is reported as such (AGT-017)" {
    var out: [keystore.MAX_SECRET_BYTES]u8 = undefined;

    // A missing or truncated file is an operator mistake with a different fix
    // from a wrong passphrase, so it must not be reported as a wrong passphrase.
    try expectError(keystore.Error.NotSealed, keystore.unseal("", "welcome", &out));
    try expectError(keystore.Error.NotSealed, keystore.unseal("KSE1", "welcome", &out));
    try expectError(keystore.Error.NotSealed, keystore.unseal("XXXX" ** 16, "welcome", &out));
}

test "an output buffer too small refuses rather than truncating (AGT-017)" {
    var env: [256]u8 = undefined;
    var small: [8]u8 = undefined;
    const blob = try sealed(&env, "welcome");

    // A truncated credential is a credential that fails authentication at the
    // far end for no visible reason.
    try expectError(keystore.Error.SecretTooLong, keystore.unseal(blob, "welcome", &small));
}

test "the base64 form the build embeds round-trips (AGT-017)" {
    var env: [256]u8 = undefined;
    var b64: [512]u8 = undefined;
    var out: [keystore.MAX_SECRET_BYTES]u8 = undefined;

    const blob = try sealed(&env, "welcome");
    const enc = std.base64.standard.Encoder;
    const text = enc.encode(&b64, blob);
    try expectEqualStrings(SECRET, try keystore.unsealBase64(text, "welcome", &out));

    // An empty option — the ordinary case on a build with no sealed key — must
    // report "no envelope", not crash and not appear to succeed.
    try expectError(keystore.Error.NotSealed, keystore.unsealBase64("", "welcome", &out));
}
