//! `ai` / `ai <prompt>` — the kudos agent console.
//!
//! A Claude-Code-style surface: type a natural-language prompt and the agent
//! streams a reply, calling tools (compile an app, ...) inline as it works; or
//! type a `/command` for a session action. Runs on core 0 (it needs the
//! network). The conversation persists across invocations — this is the one
//! on-demand agent (spec AGT-001), reset with `/reset`.
//!
//! Transport: chat streams DIRECTLY from the LLM service over the in-kernel
//! HTTPS stack (inet.postStream, TLS 1.3 + CA verification — AGT-003/AGT-005),
//! authorised by the AI.CFG credential (AGT-004).
//!
//! This file is the CONSOLE half only: the conversation, the credential, the
//! slash commands, and the terminal the reply streams to. What the agent can DO
//! — the tool registry, the compile factory, MCP in both directions — is
//! console/agenttools.zig, which this file configures from AI.CFG and drives.

const std = @import("std");
const abi = @import("abi");
const agenttools = @import("../agenttools.zig");
const aiconsole = @import("../../agent/aiconsole.zig");
const config = @import("../../agent/config.zig");
const console = @import("../console.zig");
const credential = @import("../../agent/credential.zig");
const heap = @import("../../kernel/memory/heap.zig");
const inet = @import("inet");
const iramdisk = @import("iramdisk");
const klog = @import("../../kernel/debug/klog.zig");
const loop = @import("../../agent/loop.zig");
const openrouter = @import("../../agent/openrouter.zig");
const prompt = @import("../../agent/prompt.zig");
const timer = @import("../../kernel/timer/timer.zig");
const vfs = @import("vfs");

const DEFAULT_MODEL = "moonshotai/kimi-k3";
const HISTORY_TURNS = 32;

// The one persistent conversation and its live model choice.
var g_history: ?loop.history.History = null;
var g_model_buf: [96]u8 = undefined;
var g_model_len: usize = 0;

fn model() []const u8 {
    return if (g_model_len != 0) g_model_buf[0..g_model_len] else DEFAULT_MODEL;
}

fn setModel(name: []const u8) void {
    agenttools.setBuf(&g_model_buf, &g_model_len, name);
}

fn history() *loop.history.History {
    if (g_history == null) {
        g_history = loop.history.History.init(heap.allocator(), HISTORY_TURNS);
        // A dropped system prompt would run the agent unguided — leave a trace.
        g_history.?.setSystem(prompt.SYSTEM) catch {
            klog.puts("ai: system prompt dropped (OutOfMemory)\n");
        };
    }
    return &g_history.?;
}

// ── transport (loop.Chat): stream the request straight to the LLM service ─────

// The LLM chat endpoint: AI.CFG `url=` when set, else the OpenRouter default
// (AGT-003). Chat rides the kernel HTTPS stack; only compile and source
// requests go to the LAN factory below.
var g_llm_buf: [160]u8 = undefined;
var g_llm_len: usize = 0;

fn llmUrl() []const u8 {
    return if (g_llm_len != 0) g_llm_buf[0..g_llm_len] else openrouter.CHAT_COMPLETIONS_URL;
}

/// loop.Chat transport: POST the request to the LLM service over HTTPS and
/// stream the response body into `sink` as it arrives (AGT-003/AGT-005), with
/// the credential on every request (AGT-004).
fn chatSend(_: *anyopaque, request: []const u8, sink: inet.BodySink) anyerror!void {
    const n = inet.instance orelse return error.NoNetwork;
    if (!credential.isUnlocked()) return error.NoApiKey;
    const hdrs = [_]inet.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = credential.authorization() },
    };
    try n.postStream(heap.allocator(), llmUrl(), &hdrs, request, sink);
}

// ── output sink (loop.Sink): stream assistant text to the terminal ────────────
// The console of the LAST `ai` invocation (a Console is a value; its contexts
// live as long as the hosting window). Static because the loop's sink and the
// tool-activity announcements both fire from callbacks with no per-call state.
var g_console: ?console.Console = null;

fn writeToConsole(text: []const u8) void {
    if (g_console) |c| c.write(text);
}

fn sinkWrite(_: *anyopaque, text: []const u8) void {
    writeToConsole(text);
}

/// Announce each tool call on the terminal as the agent makes it (the "● tool"
/// lines). Installed here because the terminal is this file's to know.
fn announceOnConsole() void {
    agenttools.announce = writeToConsole;
}

// ── clock (loop.Clock): the budget's wall-time source ─────────────────────────
fn clockMillis(_: *anyopaque) u64 {
    return timer.millis();
}
var g_clock_ctx: u8 = 0;

// The loop contracts (Chat/Tools/Sink) want a context, but every callback here
// reaches its console through g_console (chatSend needs none at all) — same
// dummy-context pattern as g_clock_ctx.
var g_loop_ctx: u8 = 0;

// ── slash commands ────────────────────────────────────────────────────────────
fn cmdHelp(c: console.Console) void {
    c.write(
        \\ai — the kudos agent
        \\  <prompt>        talk to the agent (it writes, compiles, hot-loads
        \\                  and exercises apps & features)
        \\  /improve [focus] budgeted self-improvement run: build, load & try
        \\                  one new feature (optionally about <focus>)
        \\  /login [pass]   decrypt the service credential (asks if given
        \\                  no passphrase); required once per boot before chat
        \\  /help           this help
        \\  /reset          clear the conversation
        \\  /status         model, endpoints, network, ABI
        \\  /apps           list compiled .kudos apps
        \\  /model <name>   switch the model
        \\  /clear          clear the screen
        \\  /quit           close the agent window (agent window only)
        \\Then run a compiled app in a terminal:  kudos run <name>
        \\
    );
}

fn cmdStatus(c: console.Console) void {
    var buf: [640]u8 = undefined;
    const up = if (inet.instance) |n| n.isUp() else false;
    const lim = loop.budget.Limits{};
    const imp = loop.budget.IMPROVE_LIMITS;
    c.write(std.fmt.bufPrint(&buf, "model:   {s}\nllm:     {s}\nkey:     {s}\nfactory: {s}\nnetwork: {s}\nABI:     v{d}\nbudget:  chat: {d} turns, {d} tool calls, {d} tokens, {d} s\n         improve: {d} turns, {d} tool calls, {d} tokens, {d} s\n", .{
        model(),
        llmUrl(),
        switch (credential.from()) {
            .sealed => "sealed into this build (AGT-017)",
            .cfg_file => "from " ++ agenttools.CFG_PATH,
            .none => "MISSING — /login to decrypt, or set key= in " ++ agenttools.CFG_PATH,
        },
        agenttools.factoryHost() orelse "(set factory= in " ++ agenttools.CFG_PATH ++ ")",
        if (up) "up" else "down",
        abi.ABI_VERSION,
        lim.max_turns,
        lim.max_tool_calls,
        lim.max_tokens,
        lim.max_ms / std.time.ms_per_s,
        imp.max_turns,
        imp.max_tool_calls,
        imp.max_tokens,
        imp.max_ms / std.time.ms_per_s,
    }) catch "");
}

fn cmdApps(c: console.Console) void {
    const rd = iramdisk.instance orelse {
        c.write("(no ramdisk)\n");
        return;
    };
    var count: usize = 0;
    var i: usize = 0;
    const n = rd.count();
    while (i < n) : (i += 1) {
        const e = rd.at(i);
        if (std.mem.endsWith(u8, e.name, ".kudos")) {
            c.write("  ");
            c.write(e.name);
            c.write("\n");
            count += 1;
        }
    }
    if (count == 0) c.write("(no compiled apps yet — ask me to build one)\n");
}

fn loadConfig() config.Config {
    const text = vfs.read(agenttools.CFG_PATH) orelse return .{};
    return config.parse(text);
}

/// `/login` was typed with no passphrase and one was asked for: the NEXT line
/// is that passphrase, not a prompt for the model.
var g_awaiting_passphrase: bool = false;

/// The greeting an agent session opens with (AGT-018). It names the two things
/// a first-time user needs — where the commands are, and that the credential
/// starts encrypted — because the session opens straight into its conversation
/// and there is nowhere else to learn them.
fn banner() []const u8 {
    return if (credential.isSealedIntoBuild())
        \\kudos agent — /help for commands, /quit to leave
        \\the service credential is encrypted; /login to decrypt it
        \\
        \\
    else
        \\kudos agent — /help for commands, /quit to leave
        \\
        \\
    ;
}

/// What to say when a chat is attempted with no usable credential — the two
/// cases need opposite actions from the user.
fn lockedMessage() []const u8 {
    return if (credential.isSealedIntoBuild())
        "the service credential is encrypted — decrypt it first:\n\n    /login <passphrase>\n\n"
    else
        "no credential: seal one into the build (scripts/agent/sealkey.sh) or set key= in " ++ agenttools.CFG_PATH ++ "\n";
}

/// Whether a turn (or any other `ai` invocation) is in flight. There is ONE
/// agent (AGT-001) and one conversation, but terminals run their commands at the
/// same time (APP-031), so a second terminal can reach this command while a
/// reply is streaming to the first. Everything below it is that one agent's —
/// the history, the model, the credential, the terminal the reply streams to —
/// so a second caller is REFUSED with the reason (APP-032) rather than
/// interleaved into the first, which would splice two conversations into one
/// history and stream both replies into whichever terminal asked last.
///
/// It also stops the agent from calling itself: a `kudos ai ...` line run by the
/// model's own `shell` tool arrives here on the very task holding the turn.
var g_running: bool = false;

/// `ai ...` — the shell command entry.
pub fn run(c: console.Console, args: []const u8) void {
    if (@atomicRmw(bool, &g_running, .Xchg, true, .acq_rel)) {
        c.write("the agent is busy with a turn in another terminal — one conversation at a time\n");
        return;
    }
    defer @atomicStore(bool, &g_running, false, .release);
    g_console = c;
    agenttools.shell_console = c;
    announceOnConsole();
    const cfg = loadConfig();
    if (cfg.factory) |f| agenttools.setFactory(f);
    // An unattended build may open its own seal; otherwise the credential waits
    // for `/login`. Either way a stick that carries its own `key=` overrides it
    // below — whoever plugged the stick in is the later decision.
    if (credential.from() == .none) credential.tryBakedPassphrase();
    if (cfg.api_key) |k| {
        credential.useConfigKey(k);
    }
    if (cfg.url) |u| agenttools.setBuf(&g_llm_buf, &g_llm_len, u);
    if (cfg.model) |m| if (g_model_len == 0) setModel(m);
    if (cfg.mcp) |u| agenttools.setMcpServer(u);
    if (cfg.token) |tk| agenttools.setToken(tk);

    // A `/login` with no passphrase asked for one; this line IS the answer, so
    // it is taken verbatim before any parsing — a passphrase may begin with `/`
    // or look like anything else, and the console must not interpret it. The
    // echo mask comes off HERE (which also forgets the editor's recall of the
    // masked line), only now that the answer has arrived.
    if (g_awaiting_passphrase) {
        g_awaiting_passphrase = false;
        c.setInputMask(false);
        c.write(credential.unlock(std.mem.trim(u8, args, " \t\r\n")));
        return;
    }

    const input = aiconsole.parse(args);
    // Refuse what SPENDS the credential while it is still encrypted, and say
    // what to do about it (AGT-022). Session commands still run — /login
    // especially — and so does OPENING a session, which is where /login is typed.
    if (aiconsole.gate(input, credential.isUnlocked()) == .locked) return c.write(lockedMessage());

    switch (input) {
        .login => |pass| {
            if (pass.len == 0) {
                // Ask, rather than fail: `/login` on its own is the natural way
                // to type it, and answering "usage:" to that is a shell being
                // pedantic at somebody who did the obvious thing. The question
                // holds the prompt (the next line is the answer, not a command)
                // and masks the echo until that answer arrives.
                g_awaiting_passphrase = true;
                c.write("passphrase: ");
                c.holdPrompt();
                c.setInputMask(true);
            } else {
                c.write(credential.unlock(pass));
            }
            return;
        },
        .help => return cmdHelp(c),
        .status => return cmdStatus(c),
        .apps => return cmdApps(c),
        .clear => {
            c.clear();
            return;
        },
        .reset => {
            if (g_history) |*h| h.deinit();
            g_history = null;
            c.write("conversation reset\n");
            return;
        },
        .model => |m| {
            if (m.len == 0) {
                c.write("model: ");
                c.write(model());
                c.write("\n");
            } else {
                setModel(m);
                c.write("model set\n");
            }
            return;
        },
        .quit => {
            // Leaving means two different things, and which one it is was
            // decided when the window opened. A shell terminal that typed `ai`
            // has a shell to go back to, and closing it would take that shell
            // with it. The dedicated agent window (AGT-002) has nothing behind
            // the conversation, so leaving it is closing it — anything else
            // leaves a window still titled "AI Agent" that is no longer one.
            if (c.agent_window) {
                c.close();
            } else if (c.ai_mode) {
                c.setAiMode(false);
                c.write("left the agent — back to the shell\n");
            } else {
                c.write("not in an agent session; type `ai` to start one\n");
            }
            return;
        },
        .unknown => |w| {
            c.write("unknown command ");
            c.write(w);
            c.write(" — try /help\n");
            return;
        },
        .prompt => |p| {
            if (p.len == 0) {
                // `ai` on its own means "talk to the agent", so THIS terminal
                // becomes the conversation — the way running a chat client in a
                // shell does. Opening a second window instead would leave the
                // user looking at the terminal they just typed into.
                if (c.ai_mode) return; // already in it; a blank line is a blank line
                c.setAiMode(true);
                c.write(banner());
                // Sealed and nobody has opened it yet: ask right here. Entering
                // the session and THEN being told to type /login is a step the
                // user has to discover; asking is the same information offered
                // at the moment it is needed.
                if (!credential.isUnlocked() and credential.isSealedIntoBuild()) {
                    g_awaiting_passphrase = true;
                    c.write("passphrase: ");
                    c.holdPrompt();
                    c.setInputMask(true);
                }
                return;
            }
            // The standing conversation, at the default per-request budget.
            runLoop(c, history(), p, .{});
        },
        .improve => |focus| {
            // A self-improvement run is isolated: a fresh conversation with the
            // improve system prompt and a wider stated budget, so it neither
            // pollutes the standing chat nor silently borrows its budget.
            var hist = loop.history.History.init(heap.allocator(), HISTORY_TURNS);
            defer hist.deinit();
            hist.setSystem(prompt.IMPROVE_SYSTEM) catch {
                c.write("out of memory — /improve aborted\n");
                return;
            };
            var pbuf: [128]u8 = undefined;
            const p = if (focus.len == 0)
                "Improve kudos."
            else
                std.fmt.bufPrint(&pbuf, "Improve kudos: {s}", .{focus}) catch "Improve kudos.";
            runLoop(c, &hist, p, loop.budget.IMPROVE_LIMITS);
        },
    }
}

/// Drive one budgeted agent run over `hist` with the given limits, streaming to
/// the terminal. Shared by a chat prompt and an `/improve` session.
fn runLoop(c: console.Console, hist: *loop.history.History, p: []const u8, limits: loop.budget.Limits) void {
    if (!credential.isUnlocked()) {
        c.write("no API key — set `key=<LLM service key>` in " ++ agenttools.CFG_PATH ++ "\n");
        return;
    }
    const arena_alloc = heap.allocator();
    // Bind the external MCP server (if any) once per turn, then offer the model
    // the local tools plus the federated remote ones.
    agenttools.discoverRemoteTools();
    const tj = agenttools.mergedToolsJson(arena_alloc) catch {
        c.write("out of memory\n");
        return;
    };
    defer arena_alloc.free(tj);

    const chat = loop.Chat{ .ctx = &g_loop_ctx, .send = chatSend };
    const tool_iface = loop.Tools{ .ctx = &g_loop_ctx, .invoke = agenttools.invoke };
    const sink = loop.Sink{ .ctx = &g_loop_ctx, .write = sinkWrite };
    const clock = loop.Clock{ .ctx = &g_clock_ctx, .millis = clockMillis };
    loop.run(arena_alloc, chat, tool_iface, sink, clock, hist, p, .{ .model = model(), .tools_json = tj, .limits = limits }) catch |e| {
        c.write("\nagent error: ");
        c.write(@errorName(e));
        c.write("\n");
        return;
    };
    c.write("\n");
}
