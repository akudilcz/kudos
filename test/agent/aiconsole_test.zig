//! Host tests of src/agent/aiconsole.zig — prompt vs /command classification.

const std = @import("std");
const aiconsole = @import("aiconsole");

test "a plain line is a prompt (trimmed)" {
    const i = aiconsole.parse("  sum the first 20 primes  ");
    try std.testing.expectEqualStrings("sum the first 20 primes", i.prompt);
}

test "known slash commands" {
    try std.testing.expect(aiconsole.parse("/help") == .help);
    try std.testing.expect(aiconsole.parse("/reset") == .reset);
    try std.testing.expect(aiconsole.parse("  /status ") == .status);
    try std.testing.expect(aiconsole.parse("/apps") == .apps);
    try std.testing.expect(aiconsole.parse("/clear") == .clear);
}

test "/model takes an argument" {
    const i = aiconsole.parse("/model anthropic/claude-3.5");
    try std.testing.expectEqualStrings("anthropic/claude-3.5", i.model);
    // no arg -> empty model string (caller reports current)
    try std.testing.expectEqualStrings("", aiconsole.parse("/model").model);
}

test "/improve carries optional focus text" {
    // bare: empty focus (caller uses the default improve prompt)
    try std.testing.expectEqualStrings("", aiconsole.parse("/improve").improve);
    // with focus: the rest of the line, trimmed
    try std.testing.expectEqualStrings("faster shell", aiconsole.parse("/improve  faster shell  ").improve);
}

test "/quit and its /exit alias close the agent window" {
    try std.testing.expect(aiconsole.parse("/quit") == .quit);
    try std.testing.expect(aiconsole.parse("  /exit ") == .quit);
}

test "unknown command is reported, not run as a prompt" {
    try std.testing.expectEqualStrings("/bogus", aiconsole.parse("/bogus now").unknown);
}

test "empty line is an empty prompt" {
    try std.testing.expectEqualStrings("", aiconsole.parse("   ").prompt);
}

test "/login carries its passphrase whole, spaces and all (AGT-017)" {
    // The passphrase is NOT reduced to a first word: one containing a space is
    // a legitimate passphrase, and quietly keeping the first half would report
    // it as wrong rather than as mistyped — sending the user to change a
    // passphrase that was correct.
    switch (aiconsole.parse("/login correct horse battery staple")) {
        .login => |p| try std.testing.expectEqualStrings("correct horse battery staple", p),
        else => return error.WrongCommand,
    }
    switch (aiconsole.parse("  /login welcome  ")) {
        .login => |p| try std.testing.expectEqualStrings("welcome", p),
        else => return error.WrongCommand,
    }
}

test "/login with nothing after it is a request to be asked (AGT-021)" {
    // Empty, not an error: the caller answers this by prompting. Trying an
    // empty passphrase would report "wrong passphrase" for what is really a
    // missing argument.
    switch (aiconsole.parse("/login")) {
        .login => |p| try std.testing.expectEqual(@as(usize, 0), p.len),
        else => return error.WrongCommand,
    }
}

test "an empty line is an empty prompt — the signal to open a session (AGT-018)" {
    // `ai` with nothing after it is someone asking to TALK to the agent, not to
    // run a one-shot command; the caller turns this into an open session.
    switch (aiconsole.parse("")) {
        .prompt => |p| try std.testing.expectEqual(@as(usize, 0), p.len),
        else => return error.WrongCommand,
    }
    switch (aiconsole.parse("   \t \n")) {
        .prompt => |p| try std.testing.expectEqual(@as(usize, 0), p.len),
        else => return error.WrongCommand,
    }
}

test "a leading solidus is what separates a command from a turn (AGT-019)" {
    // Without the rule, "status" — a perfectly ordinary thing to say to an
    // agent — would silently run a session command instead of being answered.
    switch (aiconsole.parse("/status")) {
        .status => {},
        else => return error.WrongCommand,
    }
    switch (aiconsole.parse("status")) {
        .prompt => |p| try std.testing.expectEqualStrings("status", p),
        else => return error.WrongCommand,
    }
    switch (aiconsole.parse("what is /status")) {
        .prompt => |p| try std.testing.expectEqualStrings("what is /status", p),
        else => return error.WrongCommand,
    }
}

test "the command list is itself a command (AGT-020)" {
    switch (aiconsole.parse("/help")) {
        .help => {},
        else => return error.WrongCommand,
    }
}

test "a sealed credential refuses turns but never the commands (AGT-022)" {
    const locked = false;

    // The two inputs that SPEND the credential are refused...
    try std.testing.expectEqual(aiconsole.Gate.locked, aiconsole.gate(aiconsole.parse("hello"), locked));
    try std.testing.expectEqual(aiconsole.Gate.locked, aiconsole.gate(aiconsole.parse("/improve fonts"), locked));

    // ...but OPENING the session is not a turn and must not be refused: an
    // empty prompt is the request to start one, and gating it locks the user
    // out of the very place /login is typed. This shipped once — `ai` answered
    // "the credential is encrypted" instead of opening the session at all.
    try std.testing.expectEqual(aiconsole.Gate.run, aiconsole.gate(aiconsole.parse(""), locked));
    try std.testing.expectEqual(aiconsole.Gate.run, aiconsole.gate(aiconsole.parse("   "), locked));

    // ...and every session command still runs. /login above all: gating it
    // behind the lock it exists to open would make the agent unusable, and
    // /help and /status are how a user finds out that is what to do.
    try std.testing.expectEqual(aiconsole.Gate.run, aiconsole.gate(aiconsole.parse("/login welcome"), locked));
    try std.testing.expectEqual(aiconsole.Gate.run, aiconsole.gate(aiconsole.parse("/help"), locked));
    try std.testing.expectEqual(aiconsole.Gate.run, aiconsole.gate(aiconsole.parse("/status"), locked));
    try std.testing.expectEqual(aiconsole.Gate.run, aiconsole.gate(aiconsole.parse("/quit"), locked));

    // Unlocked, nothing is gated at all.
    try std.testing.expectEqual(aiconsole.Gate.run, aiconsole.gate(aiconsole.parse("hello"), true));
    try std.testing.expectEqual(aiconsole.Gate.run, aiconsole.gate(aiconsole.parse("/improve fonts"), true));
}
