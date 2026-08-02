//! Parsing for the openclaw console line — the Claude-Code-style surface where
//! the user types a prompt and gets a streamed response, and `/commands` do
//! session actions. Pure: classify one input line; the kernel command executes
//! the result and streams output.

const std = @import("std");

pub const Input = union(enum) {
    /// A natural-language turn for the agent.
    prompt: []const u8,
    /// `/help` — list what the console can do.
    help,
    /// `/reset` — clear the conversation.
    reset,
    /// `/status` — show config, model, factory, ABI, connection.
    status,
    /// `/apps` — list compiled .kudos apps.
    apps,
    /// `/clear` — clear the screen.
    clear,
    /// `/model <name>` — switch the model for this session.
    model: []const u8,
    /// `/improve [focus]` — a budgeted self-improvement run: ideate, write,
    /// compile, hot-load, and exercise ONE improvement. The optional text
    /// narrows what to work on.
    improve: []const u8,
    /// `/quit` (or `/exit`) — close the dedicated agent window.
    quit,
    /// A `/word` that is not a known command.
    unknown: []const u8,
};

/// Classify a raw input line. Leading/trailing space is ignored. A line that
/// starts with `/` is a command (the first word selects it); anything else is a
/// prompt. An empty line becomes an empty prompt (the caller ignores it).
pub fn parse(line: []const u8) Input {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return .{ .prompt = trimmed };

    const sp = std.mem.indexOfScalar(u8, trimmed, ' ');
    const word = if (sp) |i| trimmed[0..i] else trimmed;
    const rest = std.mem.trim(u8, if (sp) |i| trimmed[i + 1 ..] else "", " \t");

    if (eq(word, "/help")) return .help;
    if (eq(word, "/reset")) return .reset;
    if (eq(word, "/status")) return .status;
    if (eq(word, "/apps")) return .apps;
    if (eq(word, "/clear")) return .clear;
    if (eq(word, "/model")) return .{ .model = rest };
    if (eq(word, "/improve")) return .{ .improve = rest };
    if (eq(word, "/quit") or eq(word, "/exit")) return .quit;
    return .{ .unknown = word };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
