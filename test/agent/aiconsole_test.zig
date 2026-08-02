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
