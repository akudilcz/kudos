//! Console — the contract a shell command runs against: the terminal grid it
//! writes to, its working directory, and the hosting desktop's window/app
//! services. The console group OWNS this surface; the terminal
//! (apps/terminal.zig) and the desktop (ui/desktop/desktop.zig) sit above the
//! console in the layering and implement it, so no command module ever imports
//! upward into the apps or ui groups. Same shape as the local commands' `Out`
//! (out.zig): opaque context plus function pointers, wrapped in plain methods.

const std = @import("std");
const png = @import("modelcache").png;
const idesk = @import("idesk"); // the desktop-control contract: the app catalogue lives there

/// The application kinds a shell command can ask the desktop to open. The list
/// itself belongs to the contract (iface/idesk.zig) — the apps group names the
/// same set for its hosted union, and neither group may import the other.
pub const AppKind = idesk.AppKind;

/// The hosting desktop's window/app services, as a console sees them —
/// implemented by ui/desktop/desktop.zig, which constructs one of these per
/// terminal at spawn. Both contexts are opaque here: the desktop sits above
/// the console group, which holds only this contract.
pub const Desktop = struct {
    ctx: *anyopaque,
    /// Open a new app window of `kind`, cascaded. A `term` spawn reports
    /// error.NoFreeSessions when the session table is full.
    spawnAppFn: *const fn (ctx: *anyopaque, kind: AppKind) anyerror!void,
    /// Open a model-viewer window on the ABSOLUTE VFS path `path`;
    /// `maximized` opens it maximised.
    spawnModelFn: *const fn (ctx: *anyopaque, path: []const u8, maximized: bool) anyerror!void,
    /// Hand the desktop a decoded background image (spec R24). Returns false
    /// while a previous hand-off is still pending — the caller keeps
    /// ownership of the pixels and reports "busy".
    setBackgroundFn: *const fn (ctx: *anyopaque, img: png.Image) bool,
    /// Queue a console's hosting window (opaque handle) for close; teardown is
    /// deferred so a window is never freed while a command still runs in it.
    closeFn: *const fn (ctx: *anyopaque, win: *anyopaque) void,
};

/// One console: what `shell.execute` hands every command. Built by the
/// terminal per dispatched line — the grid half's `ctx` is the hosting
/// terminal, the desktop half is the contract that terminal was given at
/// spawn. A command that outlives its invocation (a backgrounded completion)
/// stores the Console BY VALUE; the contexts stay valid for the window's life.
pub const Console = struct {
    /// The hosting terminal (the grid the five functions below run against).
    ctx: *anyopaque,
    /// Write one character at the cursor ('\n' starts a new line).
    putFn: *const fn (ctx: *anyopaque, ch: u8) void,
    /// Blank the whole grid and home the cursor.
    clearFn: *const fn (ctx: *anyopaque) void,
    /// This console's cwd (normalized absolute VFS path — vfs.zig).
    cwdFn: *const fn (ctx: *anyopaque) []const u8,
    /// Set the cwd (callers pass a normalized absolute path ≤ vfs.MAX_PATH).
    setCwdFn: *const fn (ctx: *anyopaque, path: []const u8) void,
    /// Print the shell prompt — a backgrounded command re-prompts when its
    /// completion lands after the synchronous part already returned.
    promptFn: *const fn (ctx: *anyopaque) void,
    /// Suppress the ONE automatic prompt the terminal prints when this command
    /// returns. For a command that ends by asking an inline question
    /// (`passphrase: `) or whose answer arrives later (`curl`): the next
    /// committed line is input to it, or its completion re-prompts itself.
    holdPromptFn: *const fn (ctx: *anyopaque) void,
    /// Mask the line editor's echo (each typed character shows as `*`) until
    /// turned off. Turning it OFF also forgets the editor's recall of the
    /// masked line, so Up-arrow cannot replay a passphrase.
    setInputMaskFn: *const fn (ctx: *anyopaque, on: bool) void,
    /// The i-th line of this terminal's committed-command history, oldest
    /// first, or null past the end — what the `history` command walks. The
    /// history lives in the line EDITOR, which no command can see; this is the
    /// one sanctioned window into it. The slice stays valid for the command's
    /// life (the editor is parked while its command runs).
    readHistoryFn: *const fn (ctx: *anyopaque, i: usize) ?[]const u8,
    /// The hosting desktop's services and this console's window within it.
    desktop: Desktop,
    win: *anyopaque,
    /// What a pipe fed this command: the previous stage's captured output, or
    /// empty at the head of a line. A plain value — the shell sets it per
    /// stage; consumers (`grep`, `wc`, `head`) read it when no file is named.
    stdin: []const u8 = "",
    /// The desktop's allocator: pixels handed over via `setBackground` and
    /// buffers a backgrounded fetch retains are owned by it.
    a: std.mem.Allocator,
    /// Whether this console is CURRENTLY in an agent session (AGT-018), where
    /// every committed line is a turn for the agent rather than a shell command.
    /// A snapshot: `setAiMode` moves the hosting terminal in and out of it, so a
    /// console value taken before the change does not describe the one after.
    ai_mode: bool,
    /// Whether this console's window IS the dedicated agent window (AGT-002) —
    /// opened as the agent rather than turned into it by `ai`. It decides what
    /// leaving the agent means: a terminal goes back to its shell, while the
    /// dedicated window has no shell behind it and closes.
    agent_window: bool,
    /// Enter or leave the agent session on the hosting terminal (AGT-018) — what
    /// makes `ai` turn THIS terminal into the chat rather than opening another
    /// window beside it, and `/quit` hand it back to the shell.
    setAiModeFn: *const fn (ctx: *anyopaque, on: bool) void,

    /// Write one character to the grid.
    pub fn put(self: Console, ch: u8) void {
        self.putFn(self.ctx, ch);
    }
    /// Write a string to the grid (each byte via put).
    pub fn write(self: Console, s: []const u8) void {
        for (s) |ch| self.putFn(self.ctx, ch);
    }
    /// Blank the whole grid and home the cursor.
    pub fn clear(self: Console) void {
        self.clearFn(self.ctx);
    }
    /// This console's cwd (normalized absolute VFS path).
    pub fn cwd(self: Console) []const u8 {
        return self.cwdFn(self.ctx);
    }
    /// Set the cwd to a normalized absolute path.
    pub fn setCwd(self: Console, path: []const u8) void {
        self.setCwdFn(self.ctx, path);
    }
    /// Print the shell prompt (backgrounded-completion path).
    pub fn prompt(self: Console) void {
        self.promptFn(self.ctx);
    }
    /// Suppress the one automatic prompt after this command returns.
    pub fn holdPrompt(self: Console) void {
        self.holdPromptFn(self.ctx);
    }
    /// Mask (or unmask) the line editor's echo; unmasking forgets the recall.
    pub fn setInputMask(self: Console, on: bool) void {
        self.setInputMaskFn(self.ctx, on);
    }
    /// The i-th committed-command history line, oldest first, or null past
    /// the end.
    pub fn history(self: Console, i: usize) ?[]const u8 {
        return self.readHistoryFn(self.ctx, i);
    }
    /// Open a new app window of `kind` (see Desktop.spawnAppFn).
    pub fn spawnApp(self: Console, kind: AppKind) anyerror!void {
        return self.desktop.spawnAppFn(self.desktop.ctx, kind);
    }
    /// Open a model-viewer window (see Desktop.spawnModelFn).
    pub fn spawnModel(self: Console, path: []const u8, maximized: bool) anyerror!void {
        return self.desktop.spawnModelFn(self.desktop.ctx, path, maximized);
    }
    /// Hand the desktop a decoded background image (see Desktop.setBackgroundFn).
    pub fn setBackground(self: Console, img: png.Image) bool {
        return self.desktop.setBackgroundFn(self.desktop.ctx, img);
    }
    /// Enter or leave the agent session on this terminal (AGT-018).
    pub fn setAiMode(self: Console, on: bool) void {
        self.setAiModeFn(self.ctx, on);
    }
    /// Close this console's own window (`exit`, the agent's `/quit`).
    pub fn close(self: Console) void {
        self.desktop.closeFn(self.desktop.ctx, self.win);
    }
};
