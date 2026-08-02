//! Parse the agent's configuration file, `/usbdisk/AI.CFG`, read at first use.
//! Format: `key=value` lines, `#` comments, surrounding whitespace ignored.
//! Recognised keys: `key` (the LLM service credential, sent as
//! `Authorization: Bearer`, AGT-004), `url` (the LLM chat endpoint, overriding
//! the OpenRouter default), `factory` (host:port of the compile factory),
//! `model` (the model id to request), `token` (the factory's shared secret,
//! sent as X-Factory-Token). Values are slices into the caller's text — no
//! allocation.

const std = @import("std");

pub const Config = struct {
    api_key: ?[]const u8 = null,
    /// Overrides the LLM chat endpoint (AGT-003); the default lives in
    /// openrouter.zig (CHAT_COMPLETIONS_URL).
    url: ?[]const u8 = null,
    factory: ?[]const u8 = null,
    model: ?[]const u8 = null,
    token: ?[]const u8 = null,
    /// An external MCP server's HTTP JSON-RPC endpoint. When set, the agent
    /// binds to it (AGT-014): discovers its tools and offers them to the model
    /// alongside its own (AGT-015).
    mcp: ?[]const u8 = null,
};

/// Parse `text` into a `Config`. Unknown keys are ignored (forward-compatible);
/// the last assignment of a key wins.
pub fn parse(text: []const u8) Config {
    var cfg = Config{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "key")) {
            cfg.api_key = val;
        } else if (std.mem.eql(u8, key, "url")) {
            cfg.url = val;
        } else if (std.mem.eql(u8, key, "factory")) {
            cfg.factory = val;
        } else if (std.mem.eql(u8, key, "model")) {
            cfg.model = val;
        } else if (std.mem.eql(u8, key, "token")) {
            cfg.token = val;
        } else if (std.mem.eql(u8, key, "mcp")) {
            cfg.mcp = val;
        }
    }
    return cfg;
}
