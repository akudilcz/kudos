//! Parsing for the agent console line — the Claude-Code-style surface where
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
    /// `/login <passphrase>` — open the sealed service credential for this
    /// session (AGT-017). Empty text = the user typed `/login` with nothing
    /// after it, which the caller answers with a prompt rather than an attempt:
    /// a blank passphrase is never right, and trying it would report "wrong
    /// passphrase" for what is really a missing argument.
    login: []const u8,
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
    // NOT trimmed to a first word: a passphrase may legitimately contain
    // spaces, and silently keeping only the first would report the passphrase
    // as wrong rather than as mistyped.
    if (eq(word, "/login")) return .{ .login = if (sp) |i| trimmed[i + 1 ..] else "" };
    if (eq(word, "/quit") or eq(word, "/exit")) return .quit;
    return .{ .unknown = word };
}

/// What a session must do with an input given the credential's state.
pub const Gate = enum {
    /// Carry it out.
    run,
    /// Refuse it and say how to decrypt the credentials (AGT-022).
    locked,
};

/// Whether `input` may proceed while the service credentials are still
/// encrypted (AGT-022).
///
/// Only the two things that SPEND the credential are refused. Every session
/// command still runs — `/login` above all, which would otherwise be locked
/// behind the lock it exists to open, but equally `/help` and `/status`, which
/// are how a user finds out what to do about it. Refusing here rather than at
/// the transport is what turns an opaque HTTP 401 from a service the user
/// cannot see into a sentence naming the command that fixes it.
pub fn gate(input: Input, unlocked: bool) Gate {
    if (unlocked) return .run;
    return switch (input) {
        // An EMPTY prompt is not a turn — it is the request to OPEN a session
        // (AGT-018), and that must work while the credentials are still
        // encrypted or there is nowhere to type the command that decrypts them.
        .prompt => |p| if (p.len == 0) .run else .locked,
        .improve => .locked,
        else => .run,
    };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
