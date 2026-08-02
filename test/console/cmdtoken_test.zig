//! Host tests of src/console/cmdtoken.zig — the single-flight command token.
//! The property under test is CONSUME-ON-CLAIM: exactly one claimer wins a
//! posted command, however many dispatchers poll. The incident this guards:
//! a non-consuming claim let two tasks execute the same `ps` concurrently,
//! tear the terminal grid, and GP-fault both — killing the desktop, the trace
//! pump, and the remote-reset path in one stroke.

const std = @import("std");
const CmdToken = @import("cmdtoken").CmdToken;
const expect = std.testing.expect;

test "exactly one claimer wins a posted command" {
    var t = CmdToken{};
    t.post();
    try expect(t.claim()); // first dispatcher wins
    try expect(!t.claim()); // second finds the token consumed — never a double run
    try expect(t.isRunning()); // the winner holds the close-deferral guard
    try expect(!t.isPending());
    t.complete();
    try expect(!t.isRunning());
}

test "a claim without a post never wins" {
    var t = CmdToken{};
    try expect(!t.claim());
    try expect(!t.isRunning());
}

test "the token re-arms for the next command" {
    var t = CmdToken{};
    t.post();
    try expect(t.claim());
    t.complete();
    t.post(); // next committed line
    try expect(t.claim()); // claimable again — single-flight, not single-shot
    try expect(!t.claim());
}
