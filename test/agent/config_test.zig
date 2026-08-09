//! Host tests of src/agent/config.zig — AI.CFG parsing.

const std = @import("std");
const config = @import("config");

test "parses keys, ignoring comments, blanks, whitespace, and unknown keys (AGT-004)" {
    const text =
        \\# agent config
        \\key = sk-or-v1-abcdef
        \\
        \\factory=192.168.64.1:8623
        \\  model =  anthropic/claude-3.5
        \\token = shared-secret
        \\unknown = ignored
    ;
    const c = config.parse(text);
    try std.testing.expectEqualStrings("sk-or-v1-abcdef", c.api_key.?);
    try std.testing.expectEqualStrings("192.168.64.1:8623", c.factory.?);
    try std.testing.expectEqualStrings("anthropic/claude-3.5", c.model.?);
    try std.testing.expectEqualStrings("shared-secret", c.token.?);
}

test "missing keys stay null; last assignment wins" {
    const c = config.parse("key=first\nkey=second\n");
    try std.testing.expectEqualStrings("second", c.api_key.?);
    try std.testing.expect(c.factory == null);
    try std.testing.expect(c.model == null);
}

test "empty input is all-null" {
    const c = config.parse("");
    try std.testing.expect(c.api_key == null and c.factory == null and c.model == null);
}

test "the llm endpoint override key is parsed (AGT-003)" {
    const c = config.parse("url = https://openrouter.ai/api/v1/chat/completions\nkey=k\n");
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", c.url.?);
    // Absent by default — the agent then uses the OpenRouter default endpoint.
    try std.testing.expect(config.parse("key=k\n").url == null);
}

test "the mcp endpoint key is parsed (AGT-014)" {
    const c = config.parse("mcp = http://192.168.20.1:8000/rpc\nkey=k\n");
    try std.testing.expectEqualStrings("http://192.168.20.1:8000/rpc", c.mcp.?);
    // Absent by default.
    try std.testing.expect(config.parse("key=k\n").mcp == null);
}
