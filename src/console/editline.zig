//! The console line editor's pure core: one keystroke at a time against a
//! line buffer, with every visible effect (echo, erase) pushed through the
//! injected `Screen` — the editor never touches a grid itself. Both terminal
//! editors consume it, so a key means the same thing on every build: the
//! single-core Terminal applies the effects straight to its cells
//! (apps/terminal.zig), the SMP session task forwards them over its request
//! ring (console/session.zig). Tab completion consumes complete.zig through
//! its injected directory enumeration, so the whole edit loop host-tests with
//! no VFS (test/console/editline_test.zig).

const std = @import("std");
const keymap = @import("keymap"); // key codes; the pure half of the keyboard driver
pub const complete = @import("complete.zig");

/// Maximum command-line length (bytes) a line editor holds. The single source
/// of this size: every editor host sizes its scratch from it.
pub const LINE_MAX: usize = 256;

/// The screen half the editor drives: echo one typed byte at the cursor, or
/// erase the cell left of it. Injected because the hosts apply the effects on
/// different sides of a task boundary — the single-core Terminal writes its
/// grid directly; the SMP session task owns no rendering and forwards each
/// effect over its request ring.
pub const Screen = struct {
    ctx: ?*anyopaque,
    echoFn: *const fn (ctx: ?*anyopaque, ch: u8) void,
    eraseFn: *const fn (ctx: ?*anyopaque) void,

    fn echo(self: Screen, ch: u8) void {
        self.echoFn(self.ctx, ch);
    }
    fn erase(self: Screen) void {
        self.eraseFn(self.ctx);
    }
};

/// What a keystroke asks the HOST to do beyond the buffer — the cases the pure
/// core cannot perform itself. `commit` runs the line (shell dispatch, task
/// handoff); `complete` needs the terminal's cwd and a live directory
/// enumeration (the host gathers both, then calls `completeLine`). The recall
/// outcomes are edits the core already applied, distinguished so a host can
/// count them (session.zig's editor-event counters).
pub const Action = enum { none, commit, complete, recalled, recall_empty };

/// What a Tab press achieved, for the host that owns the screen below the
/// line: `grew` the line changed and the echo is done; `ambiguous` several
/// entries match and the host should show them; `none` nothing matched.
pub const Completion = enum { none, grew, ambiguous };

/// The line buffer + last-committed recall buffer, and the keystroke logic
/// over them. Plain value state: each terminal embeds one.
pub const Editor = struct {
    line: [LINE_MAX]u8 = undefined,
    len: usize = 0,
    /// Last committed command, for Up-arrow recall.
    last_line: [LINE_MAX]u8 = undefined,
    last_len: usize = 0,

    /// The line as text — what a commit executes.
    pub fn text(self: *const Editor) []const u8 {
        return self.line[0..self.len];
    }

    /// Drop the recall buffer. Called when masked input ends (a passphrase was
    /// committed): Up-arrow must not replay onto the screen what the echo hid.
    pub fn forgetRecall(self: *Editor) void {
        self.last_len = 0;
    }

    /// Apply one ASCII keystroke: Enter remembers a non-empty line for recall
    /// and asks the host to commit it; Up recalls the last committed line in
    /// place; Tab asks the host for completion; Backspace erases; printable
    /// ASCII appends and echoes. Anything else is ignored.
    pub fn key(self: *Editor, ascii: u8, scr: Screen) Action {
        switch (ascii) {
            '\r', '\n' => {
                const trimmed = std.mem.trim(u8, self.line[0..self.len], " \t");
                if (trimmed.len > 0) {
                    @memcpy(self.last_line[0..self.len], self.line[0..self.len]);
                    self.last_len = self.len;
                }
                return .commit;
            },
            keymap.KEY_UP => return self.recall(scr),
            '\t' => return .complete,
            keymap.KEY_BACKSPACE => {
                if (self.len > 0) {
                    self.len -= 1;
                    scr.erase();
                }
                return .none;
            },
            else => {
                if (ascii >= 0x20 and ascii < 0x7F and self.len < self.line.len) {
                    self.line[self.len] = ascii;
                    self.len += 1;
                    scr.echo(ascii);
                }
                return .none;
            },
        }
    }

    /// Complete the line's last token (Tab) against `cwd` over the injected
    /// enumeration, `cmds` naming the commands a first word can complete to
    /// and `group` the subcommands a second word can (complete.Group).
    /// The redraw is the core's own account of what it changed: erase what a
    /// case-corrected match rewrote, then echo the new tail — which for an
    /// ordinary append is exactly the appended bytes.
    ///
    /// Says what the press could NOT do: `.ambiguous` means several entries
    /// match and the line already holds all the text they share, so the host
    /// SHOWS them (complete.eachMatch) rather than letting the key look dead.
    pub fn completeLine(self: *Editor, cwd: []const u8, dirs: complete.Dirs, cmds: []const []const u8, group: complete.Group, scr: Screen) Completion {
        const before = self.len;
        const r = complete.line(&self.line, self.len, cwd, dirs, cmds, group);
        for (0..r.erased) |_| scr.erase();
        for (self.line[before - r.erased .. r.len]) |ch| scr.echo(ch);
        self.len = r.len;
        if (r.matches > 1 and r.len == before) return .ambiguous;
        return if (r.len != before or r.erased != 0) .grew else .none;
    }

    /// Recall the last committed command (Up): erase the current line, then
    /// load and echo `last_line` so it can be edited or re-run. A no-op
    /// (.recall_empty) when nothing has been committed yet.
    fn recall(self: *Editor, scr: Screen) Action {
        if (self.last_len == 0) return .recall_empty;
        while (self.len > 0) {
            self.len -= 1;
            scr.erase();
        }
        @memcpy(self.line[0..self.last_len], self.last_line[0..self.last_len]);
        self.len = self.last_len;
        for (self.line[0..self.len]) |ch| scr.echo(ch);
        return .recalled;
    }
};
