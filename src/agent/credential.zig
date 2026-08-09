//! The agent's service credential: where it comes from, how a session unlocks
//! it, and what the user is told about it (spec AGT-017).
//!
//! One concern, split out of the agent console because it is a whole story of
//! its own — a sealed envelope in the image, an optional plaintext file on a
//! USB stick, a passphrase typed at a prompt, and four different things to say
//! depending on which of those exist. The console owns the conversation; this
//! owns the secret and the sentences about it.
//!
//! The credential is held ready to send, as an `Authorization` header value, so
//! the plaintext key exists only inside `unlock` — it is never stored.

const std = @import("std");
const keystore = @import("keystore.zig");
const buildinfo = @import("buildinfo");

/// Longest credential accepted from any source. An OpenRouter key is about 73
/// characters; the bound is generous.
pub const MAX_API_KEY_LEN = 128;

/// Where the credential in use came from. "No key" and "the sealed one would
/// not open" need different fixes, and reporting both as MISSING sends an
/// operator to the wrong one.
pub const Source = enum { none, sealed, cfg_file };

var auth_buf: ["Bearer ".len + MAX_API_KEY_LEN]u8 = undefined;
var auth_len: usize = 0;
var source: Source = .none;

/// The `Authorization` value to send, or empty when the credential is still
/// encrypted. Zero length is the one test for "may this request go out".
pub fn authorization() []const u8 {
    return auth_buf[0..auth_len];
}

pub fn isUnlocked() bool {
    return auth_len != 0;
}

pub fn from() Source {
    return source;
}

/// Install `key` as the credential for the rest of this boot.
fn install(key: []const u8, s: Source) void {
    // A key too long for the buffer cannot be sent; leaving it unset makes the
    // refusal loud at chat time instead of sending a truncated credential.
    const held = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{key}) catch return;
    auth_len = held.len;
    source = s;
}

/// Adopt a credential read from the configuration file on the USB stick
/// (AGT-004). A stick someone plugged in is a later decision than the build's
/// own sealed envelope, so this wins.
pub fn useConfigKey(key: []const u8) void {
    install(key, .cfg_file);
}

/// Open the credential sealed into this build with `passphrase`, and return
/// what to tell the user (AGT-017).
///
/// The passphrase is TYPED, not built in: a build carrying both the sealed blob
/// and the words that open it is obfuscation rather than a lock, and the image
/// then hands the credential to anyone who runs it. Baking one is still possible
/// (`-Dagent-password`) for an unattended rig, but it is not the default and
/// never should be for an image anybody else can boot.
pub fn unlock(passphrase: []const u8) []const u8 {
    if (buildinfo.agent_key.len == 0)
        return "no credential is sealed into this build — run scripts/agent/sealkey.sh and rebuild\n";
    if (passphrase.len == 0)
        return "usage: /login <passphrase>\n";

    var secret: [keystore.MAX_SECRET_BYTES]u8 = undefined;
    const key = keystore.unsealBase64(buildinfo.agent_key, passphrase, &secret) catch |e| {
        // Specific, because the fixes differ: a wrong passphrase is the user's
        // to retry, a malformed envelope is the build's to redo.
        return switch (e) {
            error.BadPassphrase => "wrong passphrase — the credential stays sealed\n",
            error.NotSealed => "the sealed credential is malformed (re-run scripts/agent/sealkey.sh)\n",
            error.SecretTooLong => "the sealed credential is longer than the agent accepts\n",
        };
    };
    install(key, .sealed);
    return "unlocked — the agent is ready\n";
}

/// The build may carry its own passphrase for an unattended machine. Off by
/// default (empty), in which case the credential stays sealed until someone
/// types the unlock command.
pub fn tryBakedPassphrase() void {
    if (buildinfo.agent_password.len == 0) return;
    _ = unlock(buildinfo.agent_password);
}

/// Whether this build carries a sealed credential at all — which decides
/// whether "encrypted" or "absent" is the right thing to say.
pub fn isSealedIntoBuild() bool {
    return buildinfo.agent_key.len != 0;
}
