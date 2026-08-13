//! The console line editor's pure core: one keystroke at a time against a
//! line buffer, with every visible effect (echo, erase, cursor motion) pushed
//! through the injected `Screen` — the editor never touches a grid itself.
//! Both terminal editors consume it, so a key means the same thing on every
//! build: the single-core Terminal applies the effects straight to its cells
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

/// Committed lines the history ring retains: enough to walk back through a
/// session's work, small enough that every editor carries its ring by value.
pub const HISTORY: usize = 32;

/// The screen half the editor drives: echo one typed byte at the cursor
/// (overwriting the cell there), erase the cell left of it, or move the cursor
/// by whole cells without touching content — the repaint-tail primitive a
/// mid-line insert or delete needs. Injected because the hosts apply the
/// effects on different sides of a task boundary — the single-core Terminal
/// writes its grid directly; the SMP session task owns no rendering and
/// forwards each effect over its request ring.
pub const Screen = struct {
    ctx: ?*anyopaque,
    echoFn: *const fn (ctx: ?*anyopaque, ch: u8) void,
    eraseFn: *const fn (ctx: ?*anyopaque) void,
    /// Move the cursor `delta` cells (negative = left), crossing wrapped-line
    /// boundaries the way erase does. Content is untouched.
    moveFn: *const fn (ctx: ?*anyopaque, delta: i32) void,

    fn echo(self: Screen, ch: u8) void {
        self.echoFn(self.ctx, ch);
    }
    fn erase(self: Screen) void {
        self.eraseFn(self.ctx);
    }
    fn move(self: Screen, delta: i32) void {
        if (delta != 0) self.moveFn(self.ctx, delta);
    }
};

/// What a keystroke asks the HOST to do beyond the buffer — the cases the pure
/// core cannot perform itself. `commit` runs the line (shell dispatch, task
/// handoff); `complete` needs the terminal's cwd and a live directory
/// enumeration (the host gathers both, then calls `completeLine`);
/// `interrupt` (Ctrl-C) abandoned the line — the host prints `^C` and a fresh
/// prompt. The recall outcomes are edits the core already applied,
/// distinguished so a host can count them (session.zig's editor-event
/// counters).
pub const Action = enum { none, commit, complete, recalled, recall_empty, interrupt };

/// What a Tab press achieved, for the host that owns the screen below the
/// line: `grew` the line changed and the echo is done; `ambiguous` several
/// entries match and the host should show them; `none` nothing matched.
pub const Completion = enum { none, grew, ambiguous };

/// The line buffer + committed-line history ring, and the keystroke logic
/// over them. Plain value state: each terminal embeds one.
pub const Editor = struct {
    line: [LINE_MAX]u8 = undefined,
    len: usize = 0,
    /// Insertion point into `line` (0..=len). Printable keys insert here,
    /// backspace deletes left of here; Left/Right/Home/End move it.
    cursor: usize = 0,

    /// Committed commands, a ring of the newest HISTORY lines. `hist_head` is
    /// the next slot to write; entry k newest lives at head-k (mod HISTORY).
    hist: [HISTORY][LINE_MAX]u8 = undefined,
    hist_lens: [HISTORY]usize = [_]usize{0} ** HISTORY,
    hist_head: usize = 0,
    hist_count: usize = 0,
    /// Whether the LAST commit stored a new entry — false for an empty line or
    /// a consecutive duplicate. forgetRecall drops the newest entry only when
    /// it holds the line being scrubbed, never an older command.
    last_commit_stored: bool = false,
    /// How far Up has walked into history: 0 = editing the live line,
    /// k = the k-th newest entry is loaded.
    walk: usize = 0,
    /// The in-progress line, saved on the FIRST Up so walking Down past the
    /// newest entry restores it (bash behavior).
    stash: [LINE_MAX]u8 = undefined,
    stash_len: usize = 0,

    /// The line as text — what a commit executes.
    pub fn text(self: *const Editor) []const u8 {
        return self.line[0..self.len];
    }

    /// Reset to an empty line: buffer, cursor, and the history walk (the next
    /// Up starts from the newest entry again). The host calls this after a
    /// commit is executed; the core calls it on interrupt.
    pub fn clearLine(self: *Editor) void {
        self.len = 0;
        self.cursor = 0;
        self.walk = 0;
    }

    /// Drop the NEWEST history entry — and only if the last commit stored one.
    /// Called when masked input ends (a passphrase was committed): Up-arrow
    /// must not replay onto the screen what the echo hid. Older commands stay
    /// recallable.
    pub fn forgetRecall(self: *Editor) void {
        if (self.last_commit_stored and self.hist_count > 0) {
            self.hist_head = (self.hist_head + HISTORY - 1) % HISTORY;
            self.hist_count -= 1;
            self.last_commit_stored = false;
        }
        self.walk = 0;
        self.stash_len = 0;
    }

    /// Forget EVERY committed line (`history -c`): the ring empties and the
    /// walk resets, so Up-arrow recalls nothing until new commits arrive.
    pub fn clearHistory(self: *Editor) void {
        self.hist_count = 0;
        self.last_commit_stored = false;
        self.walk = 0;
        self.stash_len = 0;
    }

    /// The i-th history line, OLDEST first (what the `history` command
    /// numbers), or null past the end.
    pub fn historyAt(self: *const Editor, i: usize) ?[]const u8 {
        if (i >= self.hist_count) return null;
        const idx = self.histIndex(self.hist_count - i);
        return self.hist[idx][0..self.hist_lens[idx]];
    }

    /// Apply one ASCII keystroke: Enter remembers a non-empty line in history
    /// and asks the host to commit it; Up/Down walk the history in place;
    /// Left/Right/Home/End move the cursor; Tab asks the host for completion;
    /// Ctrl-C abandons the line; Backspace deletes left of the cursor;
    /// printable ASCII inserts at it. Anything else is ignored.
    pub fn key(self: *Editor, ascii: u8, scr: Screen) Action {
        switch (ascii) {
            '\r', '\n' => {
                const trimmed = std.mem.trim(u8, self.line[0..self.len], " \t");
                self.last_commit_stored = trimmed.len > 0 and !self.repeatsNewest();
                if (self.last_commit_stored) self.pushHistory();
                return .commit;
            },
            keymap.KEY_UP => return self.recallOlder(scr),
            keymap.KEY_DOWN => return self.recallNewer(scr),
            keymap.KEY_LEFT => {
                if (self.cursor > 0) {
                    self.cursor -= 1;
                    scr.move(-1);
                }
                return .none;
            },
            keymap.KEY_RIGHT => {
                if (self.cursor < self.len) {
                    self.cursor += 1;
                    scr.move(1);
                }
                return .none;
            },
            keymap.KEY_HOME => {
                scr.move(-cells(self.cursor));
                self.cursor = 0;
                return .none;
            },
            keymap.KEY_END => {
                scr.move(cells(self.len - self.cursor));
                self.cursor = self.len;
                return .none;
            },
            '\t' => return .complete,
            keymap.KEY_CTRL_C => {
                // The abandoned text stays on screen (bash leaves it too); the
                // host prints `^C` after it and prompts fresh.
                self.clearLine();
                return .interrupt;
            },
            keymap.KEY_BACKSPACE => {
                if (self.cursor > 0) {
                    std.mem.copyForwards(u8, self.line[self.cursor - 1 .. self.len - 1], self.line[self.cursor..self.len]);
                    self.cursor -= 1;
                    self.len -= 1;
                    scr.erase();
                    self.repaintTail(scr, true);
                }
                return .none;
            },
            else => {
                if (ascii >= 0x20 and ascii < 0x7F and self.len < self.line.len) {
                    std.mem.copyBackwards(u8, self.line[self.cursor + 1 .. self.len + 1], self.line[self.cursor..self.len]);
                    self.line[self.cursor] = ascii;
                    self.len += 1;
                    self.cursor += 1;
                    scr.echo(ascii);
                    self.repaintTail(scr, false);
                }
                return .none;
            },
        }
    }

    /// Complete the line's last token (Tab) against `cwd` over the injected
    /// enumeration, `cmds` naming the commands a first word can complete to
    /// and `group` the subcommands a second word can (complete.Group).
    /// Completion appends at the END of the line, so the cursor is brought
    /// there first. The redraw is the core's own account of what it changed:
    /// erase what a case-corrected match rewrote, then echo the new tail —
    /// which for an ordinary append is exactly the appended bytes.
    ///
    /// Says what the press could NOT do: `.ambiguous` means several entries
    /// match and the line already holds all the text they share, so the host
    /// SHOWS them (complete.eachMatch) rather than letting the key look dead.
    pub fn completeLine(self: *Editor, cwd: []const u8, dirs: complete.Dirs, cmds: []const []const u8, group: complete.Group, scr: Screen) Completion {
        scr.move(cells(self.len - self.cursor));
        self.cursor = self.len;
        const before = self.len;
        const r = complete.line(&self.line, self.len, cwd, dirs, cmds, group);
        for (0..r.erased) |_| scr.erase();
        for (self.line[before - r.erased .. r.len]) |ch| scr.echo(ch);
        self.len = r.len;
        self.cursor = r.len;
        if (r.matches > 1 and r.len == before) return .ambiguous;
        return if (r.len != before or r.erased != 0) .grew else .none;
    }

    /// Repaint the cells from the cursor to the end of the line after a
    /// mid-line edit, then put the cursor back. A delete (`blank_last`) shifted
    /// the tail left, so the cell past the new end still shows the old last
    /// character — overwrite it with a space. No-op when the edit was at the
    /// end of the line.
    fn repaintTail(self: *const Editor, scr: Screen, blank_last: bool) void {
        if (self.cursor == self.len) return;
        for (self.line[self.cursor..self.len]) |ch| scr.echo(ch);
        var painted = self.len - self.cursor;
        if (blank_last) {
            scr.echo(' ');
            painted += 1;
        }
        scr.move(-cells(painted));
    }

    /// The slot of the k-th newest history entry (k in 1..=hist_count).
    fn histIndex(self: *const Editor, k: usize) usize {
        return (self.hist_head + HISTORY - k) % HISTORY;
    }

    /// Whether the line repeats the newest history entry (consecutive
    /// duplicates are not stored — bash's default).
    fn repeatsNewest(self: *const Editor) bool {
        if (self.hist_count == 0) return false;
        const i = self.histIndex(1);
        return std.mem.eql(u8, self.hist[i][0..self.hist_lens[i]], self.line[0..self.len]);
    }

    /// Store the line as the newest history entry, evicting the oldest once
    /// the ring is full.
    fn pushHistory(self: *Editor) void {
        @memcpy(self.hist[self.hist_head][0..self.len], self.line[0..self.len]);
        self.hist_lens[self.hist_head] = self.len;
        self.hist_head = (self.hist_head + 1) % HISTORY;
        if (self.hist_count < HISTORY) self.hist_count += 1;
    }

    /// Up: walk one entry older. The first step stashes the in-progress line
    /// so Down can restore it; at the oldest entry the key edits nothing
    /// (.recall_empty — "Up did nothing" stays countable).
    fn recallOlder(self: *Editor, scr: Screen) Action {
        if (self.walk >= self.hist_count) return .recall_empty;
        if (self.walk == 0) {
            @memcpy(self.stash[0..self.len], self.line[0..self.len]);
            self.stash_len = self.len;
        }
        self.walk += 1;
        const idx = self.histIndex(self.walk);
        self.loadLine(self.hist[idx][0..self.hist_lens[idx]], scr);
        return .recalled;
    }

    /// Down: walk one entry newer; past the newest, restore the stashed
    /// in-progress line (bash behavior). Not walking = nothing to do.
    fn recallNewer(self: *Editor, scr: Screen) Action {
        if (self.walk == 0) return .recall_empty;
        self.walk -= 1;
        if (self.walk == 0) {
            self.loadLine(self.stash[0..self.stash_len], scr);
        } else {
            const idx = self.histIndex(self.walk);
            self.loadLine(self.hist[idx][0..self.hist_lens[idx]], scr);
        }
        return .recalled;
    }

    /// Replace the line with `s` on screen and in the buffer: cursor to the
    /// end, erase everything, then load and echo. `s` never aliases `line` —
    /// it is a history entry or the stash.
    fn loadLine(self: *Editor, s: []const u8, scr: Screen) void {
        scr.move(cells(self.len - self.cursor));
        while (self.len > 0) {
            self.len -= 1;
            scr.erase();
        }
        @memcpy(self.line[0..s.len], s);
        self.len = s.len;
        self.cursor = s.len;
        for (s) |ch| scr.echo(ch);
    }
};

/// A cell count (≤ LINE_MAX) as the signed delta Screen.move takes.
fn cells(n: usize) i32 {
    return @intCast(n);
}
