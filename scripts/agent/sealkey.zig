//! Seal the agent's service credential into the envelope the kernel opens
//! (spec AGT-017). Host-side half of src/agent/keystore.zig — and it calls that
//! module's own `seal`, so the format has exactly ONE implementation rather
//! than two that agree until somebody edits one of them.
//!
//! The credential arrives on STDIN, never in argv: a process's arguments are
//! readable by every other process on the machine, and a secret pasted onto a
//! command line also lands in the shell's history file.
//!
//! Usage: sealkey <passphrase>        # credential on stdin, base64 on stdout

const std = @import("std");
const keystore = @import("keystore");

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    if (argv.len != 2) {
        std.debug.print("usage: sealkey <passphrase>   # credential on stdin\n", .{});
        std.process.exit(2);
    }
    const passphrase = std.mem.span(argv[1]);

    const io = init.io;
    var in_buf: [keystore.MAX_SECRET_BYTES + 64]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &in_buf);
    var secret_buf: [keystore.MAX_SECRET_BYTES + 32]u8 = undefined;
    const read = try fr.interface.readSliceShort(&secret_buf);
    const secret = std.mem.trim(u8, secret_buf[0..read], " \t\r\n");
    if (secret.len == 0) {
        std.debug.print("sealkey: no credential on stdin\n", .{});
        std.process.exit(2);
    }
    if (secret.len > keystore.MAX_SECRET_BYTES) {
        std.debug.print("sealkey: credential is {d} bytes, the kernel accepts at most {d}\n", .{ secret.len, keystore.MAX_SECRET_BYTES });
        std.process.exit(2);
    }

    // A fresh salt and nonce per sealing. The nonce especially: ChaCha20-Poly1305
    // is catastrophically broken by nonce reuse under the same key, and re-sealing
    // the same credential with the same passphrase would do exactly that if either
    // were fixed.
    var salt: [keystore.SALT_BYTES]u8 = undefined;
    var nonce: [keystore.NONCE_BYTES]u8 = undefined;
    try io.randomSecure(&salt);
    try io.randomSecure(&nonce);

    var env: [keystore.HEADER_BYTES + keystore.MAX_SECRET_BYTES]u8 = undefined;
    const blob = try keystore.seal(secret, passphrase, salt, nonce, &env);

    var b64: [4 * (keystore.HEADER_BYTES + keystore.MAX_SECRET_BYTES) / 3 + 8]u8 = undefined;
    const text = std.base64.standard.Encoder.encode(&b64, blob);

    var out_buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    try fw.interface.writeAll(text);
    try fw.interface.writeByte('\n');
    try fw.interface.flush();
}
