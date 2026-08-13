//! Terminal text grid + line editor. Hosts a shell.

const std = @import("std");
const surface = @import("surface");
const font = @import("../ui/screen/font.zig");
const theme = @import("theme");
const window_mod = @import("../ui/wm/window.zig");
const Window = window_mod.Window;
const framebuffer = @import("../ui/screen/framebuffer.zig");
const console_mod = @import("../console/console.zig");
const shell = @import("../console/shell.zig");
const percpu = @import("../kernel/sched/percpu.zig");
const session_mod = @import("../console/session.zig");
const Session = session_mod.Session;
const editline = @import("../console/editline.zig");
const LINE_MAX = editline.LINE_MAX;
const keymap = @import("keymap"); // scrollback + interrupt key codes (one home)
const kgl = @import("kgl");
const gles = @import("gles"); // the 2D toolkit the unified GL desktop draws through
const sched = @import("../kernel/sched/sched.zig");
const smp = @import("../kernel/smp/smp.zig");
const buildinfo = @import("buildinfo");
const localcmd = @import("../console/localcmd.zig");
const kudoscmd = @import("../console/cmd/kudos.zig");
const vfs = @import("vfs");
const debug = @import("../kernel/debug/debug.zig");
const counter = @import("../kernel/debug/counter.zig");

/// Keystrokes dropped because a session's key ring was full (see routeKey).
var cnt_key_drops = counter.Counter{ .mod = .ui, .name = "key.drops" };
const iaccel = @import("iaccel"); // the GPU-acceleration seam (iface/iaccel.zig)

const Color = surface.Color;

// Glass background: the shared premultiplied theme.GLASS_BG. drawGl paints a
// cell background only where it differs from this value — the window's frosted
// body IS the background — so the premultiplied composite stays uniform across
// all glass windows. Glyphs, prompt, and cursor are opaque (0xFF).
pub const BG: Color = theme.GLASS_BG;
pub const FG: Color = 0xFFFFFFFF;
const PROMPT_FG: Color = 0xFF80FFB0;
const CURSOR: Color = 0xFFA0FFA0;

const Cell = struct { ch: u8 = ' ', fg: Color = FG, bg: Color = BG };

// Fixed grid extents — the largest content area a window can ever show (the
// screen-max bound minus chrome, in cells). The grid is allocated ONCE at this
// size; a resize changes only the visible cols/rows, so no resize ever copies,
// clips, or drops cells — text hidden by a shrink reappears when the window
// grows back.
pub const MAX_COLS: usize = (framebuffer.MAX_SCREEN_W - 2 * window_mod.BORDER) / font.WIDTH;
pub const MAX_ROWS: usize = (framebuffer.MAX_SCREEN_H - 2 * window_mod.BORDER - window_mod.TITLE_H) / font.HEIGHT;

pub const Terminal = struct {
    a: std.mem.Allocator,
    win: *Window,
    /// The hosting desktop's services, as the console contract sees them
    /// (console/console.zig) — handed over at spawn. The terminal itself never
    /// calls these; it embeds them in the Console it builds per command, so
    /// the apps group needs no import of ui/desktop.
    desktop: console_mod.Desktop,
    cols: usize,
    rows: usize,
    cells: []Cell,
    cx: usize = 0,
    cy: usize = 0,
    fg: Color = FG,
    /// The line editor's pure core (line buffer + Up-arrow recall;
    /// console/editline.zig). Used by the single-core path, where the Terminal
    /// hosts its own editor inline — the SMP path edits its SESSION's editor.
    ed: editline.Editor = .{},
    /// Which terminal this is. The prompt shows it as `#id>` and the title as
    /// `term #id`, so a window is always identifiable. It is a SESSION number,
    /// not a core: the session's task runs wherever there is a free processor and
    /// may move between them (KRN-009/011). On the single-core kernel this is 0.
    id: u32 = 0,
    /// This terminal's current working directory in the VFS namespace
    /// (vfs.zig) — every terminal starts in /ramdisk; `cd` changes it and
    /// the prompt shows it. Always a normalized absolute path.
    cwd_buf: [vfs.MAX_PATH]u8 = undefined,
    cwd_len: usize = 0,
    /// The shared session whose line-editor task this terminal displays (SMP
    /// build). null on the single-core kernel, where the terminal edits its own
    /// `line` inline.
    session: ?*Session = null,

    /// Grid content changed since the desktop last looked (command output
    /// written by the cmd-worker task, echo, clear). The desktop's tick
    /// exchanges it for window damage — on the software rasteriser only
    /// damaged regions repaint, so output that marked nothing stayed
    /// invisible until something else dirtied the window.
    dirty: bool = false,
    /// The AI agent window (spec AGT-002): a terminal whose every committed line
    /// is a turn for the on-demand agent rather than a shell command. It prompts
    /// `ai>` and dispatches each line as `kudos ai <line>` — the same agent
    /// console the `kudos ai` shell command drives, so there is one agent
    /// codebase. A normal terminal leaves this false and runs lines as shell
    /// commands.
    ai_mode: bool = false,

    /// One automatic prompt suppressed (Console.holdPrompt): the running command
    /// ended by asking an inline question, so the next committed line is ITS
    /// input and a prompt would print into the question. Consumed by
    /// promptAfterCommand only — explicit re-prompts always print.
    hold_prompt: bool = false,
    /// Echo masking (Console.setInputMask): typed characters show as `*` so a
    /// passphrase reaches neither the grid nor the test-hooks mirror. Turning it
    /// OFF forgets the editor's recall of the masked line.
    input_mask: bool = false,

    /// Scrollback: how many rows above the bottom-anchored view the user has
    /// scrolled (Shift-PgUp/PgDn). 0 = pinned to the newest content. Clamped to
    /// the retained rows above the view; ANY other keystroke or new output
    /// snaps it back to 0, and the cursor is drawn only at 0.
    view_off: usize = 0,

    /// Whether this terminal WAS OPENED as the agent window, as opposed to a
    /// shell terminal the `ai` command later moved into a conversation. Fixed at
    /// create: `ai_mode` moves, this does not, and leaving the agent means
    /// different things for the two — the shell terminal goes back to its
    /// prompt, the dedicated window has no prompt to go back to and closes.
    agent_window: bool = false,

    // Test-hooks terminal-output mirror (build.zig `-Dtest-hooks`; compiled out
    // otherwise). Accumulates the characters written to the grid a line at a time
    // so the integration harness can read command output back over the trace
    // — see the flush in `putChar`. Sized at debug.VAL_CAP: a longer line flushes
    // in VAL_CAP-byte chunks (keyed `term.<id>+`) before the newline flush.
    mirror_buf: [debug.VAL_CAP]u8 = undefined,
    mirror_len: usize = 0,

    /// Allocate a terminal: the FIXED max-size cell grid (~0.5 MB; resize never
    /// reallocs it), the visible cols/rows from the window's content area, bind it
    /// to its session id and (SMP) its shared `session`, and print the greeting + first
    /// prompt. `close` is the symmetric teardown — it frees everything taken here.
    pub fn create(a: std.mem.Allocator, win: *Window, desktop: console_mod.Desktop, id: u32, session: ?*Session, ai_mode: bool) !*Terminal {
        const cols = win.contentW() / font.WIDTH;
        const rows = win.contentH() / font.HEIGHT;
        const cells = try a.alloc(Cell, MAX_COLS * MAX_ROWS);
        errdefer a.free(cells);
        const t = try a.create(Terminal);
        t.* = .{ .a = a, .win = win, .desktop = desktop, .cols = cols, .rows = rows, .cells = cells, .id = id, .session = session, .ai_mode = ai_mode, .agent_window = ai_mode };
        counter.register(&cnt_key_drops); // idempotent — first terminal wins
        t.setCwd("/ramdisk");
        t.clearGrid();
        // The agent window opens straight into its conversation, so its banner
        // is the only place a first-time user is told the two things they need:
        // where the commands are, and that the credential starts locked.
        t.write(if (ai_mode)
            \\kudos agent
            \\  /login   unlock the service credential (once per boot)
            \\  /help    everything else
            \\
            \\
        else
            "kudos terminal. type 'help'.\n");
        t.prompt();
        return t;
    }

    /// Re-lay-out after the window was resized: recompute the VISIBLE cols/rows from the
    /// new content area. A resize is a VIEW change, not a content edit — the
    /// grid is fixed at MAX_COLS×MAX_ROWS, so
    /// nothing is copied, clipped, or dropped; text hidden by a shrink reappears
    /// when the window grows back. drawGl() bottom-anchors the visible rows over
    /// the used content (viewTop), keeping the cursor/edit line on screen.
    /// Always returns true: the desktop repaints the whole window through the GL
    /// pipeline on the next frame regardless of how the cell counts changed.
    pub fn onResize(self: *Terminal) bool {
        self.cols = self.win.contentW() / font.WIDTH;
        self.rows = self.win.contentH() / font.HEIGHT;
        return true;
    }

    /// First grid row drawn: the visible rows are the BOTTOM `rows` of the used
    /// content (`0..=cy`), so a shrink slides the view down the retained grid
    /// (the newest output + cursor stay visible) and a grow reveals older rows.
    /// Scrollback (`view_off`) slides the window up over the retained rows,
    /// clamped so the view never leaves the grid.
    fn viewTop(self: *const Terminal) usize {
        const base = if (self.cy >= self.rows) self.cy + 1 - self.rows else 0;
        return base - @min(self.view_off, base);
    }

    /// Rows of retained content above the bottom-anchored view — the most the
    /// user can scroll back.
    fn scrollLimit(self: *const Terminal) usize {
        return if (self.cy >= self.rows) self.cy + 1 - self.rows else 0;
    }

    /// Shift-PgUp: scroll one page toward the oldest retained rows (clamped).
    pub fn scrollBack(self: *Terminal) void {
        self.view_off = @min(self.view_off + self.rows, self.scrollLimit());
        @atomicStore(bool, &self.dirty, true, .release);
    }

    /// Shift-PgDn: scroll one page back toward the newest content (saturating).
    pub fn scrollForward(self: *Terminal) void {
        self.view_off -|= self.rows;
        @atomicStore(bool, &self.dirty, true, .release);
    }

    /// The system task: drain the requests this terminal's session has posted and
    /// apply them to the grid (echo/backspace) or execute the line (run_line).
    /// Returns true if anything changed (so the window repaints). SMP build only.
    pub fn applyRequests(self: *Terminal) bool {
        const sess = self.session orelse return false;
        var changed = false;
        while (sess.req.pop()) |r| {
            changed = true;
            switch (r.kind) {
                .echo => self.echoChar(r.ch),
                .prompt => self.promptAfterCommand(),
                .backspace => self.backspaceCell(),
                .move => self.moveCursorCells(r.n),
                .interrupt => self.acknowledgeInterrupt(),
                .run_line => {
                    // Hand the committed line to the command WORKER task (not
                    // run inline here): a slow command must not block the system
                    // task's render/input/ring-drain. The worker runs shell.execute
                    // (yielding during waits), re-prompts, clears busy.
                    self.putChar('\n');
                    sess.cmd.post();
                },
                .complete => {
                    // Tab: the session's editor task is parked on `busy`
                    // (session.requestComplete) — completion needs this
                    // terminal's cwd and the live VFS, which live on this side
                    // of the task boundary. Grow the line (and show the
                    // candidates when the word stays ambiguous) during the
                    // park, then release the editor — released whatever the
                    // completion did.
                    self.completeFor(&sess.ed);
                    @atomicStore(bool, &sess.busy, false, .release);
                    session_mod.wakeTask(sess);
                },
            }
        }
        return changed;
    }

    /// Claim this terminal's pending command for execution: CONSUME the
    /// pending token and set `cmd_running` (the close-deferral guard) in one
    /// atomic exchange, so exactly one claimer ever wins — a command can never
    /// run twice however many dispatchers exist (see console/cmdtoken.zig).
    /// Called by the worker UNDER the desktop's structure lock, so the claim is
    /// also atomic with any concurrent close's deferral check — a claimed
    /// terminal cannot be freed until runPendingCommand clears `cmd_running`.
    pub fn claimPendingCommand(self: *Terminal) bool {
        const sess = self.session orelse return false;
        return sess.cmd.claim();
    }

    /// Execute the command claimed by `claimPendingCommand` — the ONLY entry:
    /// the claim consumed the pending token, so there is no pending check to
    /// re-make here. Called by the command worker task (NOT the system task),
    /// so a blocking command yields the worker — the system task keeps
    /// rendering. Returns true (a command ran).
    pub fn runPendingCommand(self: *Terminal) bool {
        const sess = self.session orelse return false;
        // Fresh work: a ^C aimed at the PREVIOUS command (or one that landed
        // between commands) must not fell this one.
        sched.clearCancel();
        // Publish which task is executing, so a ^C can requestCancel it
        // (session.cancelCommand). The worker task is permanent — never
        // reaped — so a raced load can at worst cancel between commands,
        // which the clearCancel above absorbs.
        @atomicStore(?*sched.Task, &sess.cmd_task, sched.currentTask(), .release);
        self.execLine(sess.ed.text());
        @atomicStore(?*sched.Task, &sess.cmd_task, null, .release);
        if (sched.cancelled()) {
            // The command unwound on a ^C: acknowledge it and drop any prompt
            // hold it left (nothing will answer a cancelled question).
            sched.clearCancel();
            self.hold_prompt = false;
            self.write("^C\n");
        }
        self.promptAfterCommand();
        // Release this terminal's line editor: it can edit the next line.
        @atomicStore(bool, &sess.busy, false, .release);
        // commitLine block()s on `busy` — wake the editor so it resumes instead
        // of sleeping until cancelled. BEFORE clearing cmd_running: the moment
        // that flag clears, a queued close may free this Terminal AND recycle
        // the session slot — a wakeTask after that would grab a recycled
        // session's freshly re-initialized task_lock.
        session_mod.wakeTask(sess);
        sess.cmd.complete();
        return true;
    }

    /// Whether this terminal's SESSION task is inside a local command (`prime`,
    /// `rt`, `run <app>`) — the desktop defers a close while it is, exactly as
    /// for a worker command: the session teardown would otherwise free the
    /// arena the running command's stack lives in. The flag alone is not the
    /// truth: a task that DIES inside the command (a contained session fault)
    /// never runs the defer that clears it, so the latched flag would defer
    /// the close forever. Retirement — the reaper's exit hook, the first
    /// moment the stack provably cannot be touched again — ends the hazard
    /// the flag names, whatever the flag says. No-op false on single-core.
    pub fn localRunning(self: *Terminal) bool {
        const sess = self.session orelse return false;
        return @atomicLoad(bool, &sess.local_running, .acquire) and
            !@atomicLoad(bool, &sess.retired, .acquire);
    }

    /// Whether the command worker is currently inside `shell.execute` for this
    /// terminal (SMP). The desktop checks this before freeing the Terminal on close,
    /// deferring teardown until the in-flight command returns.
    pub fn commandRunning(self: *Terminal) bool {
        const sess = self.session orelse return false;
        return sess.cmd.isRunning();
    }

    /// Whether this terminal has a committed command line waiting for the
    /// worker (SMP). Lets the desktop pump commands without knowing the session's
    /// internals.
    pub fn commandPending(self: *Terminal) bool {
        const sess = self.session orelse return false;
        return sess.cmd.isPending();
    }

    /// Deliver one keystroke to this terminal (SMP path). Pushes the ascii onto
    /// the SESSION's key ring and wakes its (possibly blocked) editor task —
    /// push-THEN-wake so the woken task observes the key. The ring belongs to the
    /// session rather than to a core precisely because the editor task may be
    /// running anywhere, or nowhere, when the key arrives.
    /// The Terminal owns this plumbing so the desktop need not touch session
    /// atomics or the ring directly.
    pub fn routeKey(self: *Terminal, ascii: u8) void {
        const sess = self.session orelse return;
        // Scrollback is a VIEW change: the grid and the editor never see it,
        // and it is served here because this runs on the system task, which
        // owns the view. Every other key snaps the view back to the newest
        // content — the reply to a keystroke must be visible.
        switch (ascii) {
            keymap.KEY_SHIFT_PGUP => return self.scrollBack(),
            keymap.KEY_SHIFT_PGDN => return self.scrollForward(),
            else => self.view_off = 0,
        }
        // Ctrl-C aims at the command IN FLIGHT, so it is out-of-band like the
        // signal it stands for: cancelled here, never queued behind the typed-
        // ahead keys waiting in the ring. An idle terminal's ^C rides the ring
        // to the editor instead, which abandons the line being edited.
        if (ascii == keymap.KEY_CTRL_C and self.interruptRunning()) return;
        // A full ring means the editor is not draining (parked, starved, or
        // dead) — the keystroke is lost. Never silently: this counter is how a
        // "typed command never ran" report gets localized in one run.
        if (!sess.keys.push(.{ .ascii = ascii })) cnt_key_drops.inc();
        session_mod.wakeTask(sess);
    }

    /// Type `line` into this terminal as if at the keyboard, committed with a
    /// newline (SMP; a no-op without a session). Every byte rides the same
    /// path as a keystroke — routeKey → session editor → echo/commit — so the
    /// line appears on the grid and dispatches exactly as a typed command; no
    /// second dispatch path exists. The boot layout starts its tiles' commands
    /// through this. The line must fit the key ring (KEY_RING_CAP) or the
    /// overflow is counted in key.drops like any dropped keystroke.
    pub fn autotype(self: *Terminal, line: []const u8) void {
        for (line) |ch| self.routeKey(ch);
        self.routeKey('\n');
    }

    /// Ctrl-C on an idle line: the editor already abandoned it; acknowledge
    /// and prompt fresh. Clearing the hold covers a command that ended by
    /// asking a question (`passphrase: `) — the interrupt is the answer it
    /// will never get. In an agent SESSION (`kudos ai` in a shell terminal),
    /// ^C is how you kill the REPL: it hands the terminal back to the shell.
    /// The dedicated agent window keeps its conversation — it has no shell
    /// behind it, and closing it is the close box's job.
    fn acknowledgeInterrupt(self: *Terminal) void {
        self.hold_prompt = false;
        self.input_mask = false;
        self.write("^C\n");
        if (self.ai_mode and !self.agent_window) {
            self.ai_mode = false;
            self.write("left the agent - back to the shell\n");
        }
        self.prompt();
    }

    /// Cancel this terminal's in-flight command, if any (the ^C path). A local
    /// command (`prime`, `rt`) runs on the SESSION's own task — cancel that,
    /// exactly as a window close does, WITHOUT clearing `alive` (the session
    /// lives on; the command's loop polls sched.cancelled() and unwinds). A
    /// proxied command runs on the worker — cancel the task the session
    /// published at claim. Returns whether anything was running to cancel.
    fn interruptRunning(self: *Terminal) bool {
        const sess = self.session orelse return false;
        if (self.localRunning()) {
            session_mod.cancelTask(sess);
            return true;
        }
        if (sess.cmd.isRunning()) {
            session_mod.cancelCommand(sess);
            return true;
        }
        return false;
    }

    /// Signal this terminal's session to close WITHOUT releasing its slot (SMP
    /// path). Clears `alive` so the session's run loop returns and the command
    /// worker stops touching this (about-to-be-freed) Terminal, and cancels+wakes
    /// the editor task so a blocked or compute-pegged task unwinds promptly.
    /// Idempotent — the desktop calls it on the close-deferral path (while a
    /// command is still in flight) and may call it again on the final teardown.
    /// Deliberately does NOT release the session slot: that is a ONE-TIME action
    /// belonging to the final teardown only, or a second release could hand the
    /// slot to a *different* terminal that had already claimed it.
    pub fn signalClose(self: *Terminal) void {
        if (!buildinfo.smp) return;
        if (self.session) |sess| {
            @atomicStore(bool, &sess.alive, false, .release);
            session_mod.cancelTask(sess);
        }
    }

    /// Release everything this terminal owns and free it (App.close): on SMP
    /// the session slot goes back so the next `term` can claim it, then the
    /// cell grid and the struct.
    ///
    /// The slot release is a ONE-TIME action, which is why it lives here and
    /// not in `signalClose`: the deferral path signals repeatedly while a
    /// command unwinds, and a second release could hand the slot to a
    /// *different* terminal that had already claimed it. Folding it into the
    /// single teardown makes calling it twice impossible, rather than a rule
    /// stated in a comment.
    pub fn close(self: *Terminal, a: std.mem.Allocator, _: ?*gles.Context) void {
        if (buildinfo.smp) {
            self.signalClose();
            if (self.session) |sess| session_mod.release(sess);
        }
        a.free(self.cells);
        a.destroy(self);
    }

    /// Mutable pointer to the cell at GRID position (x,y) (row-major, fixed
    /// MAX_COLS stride — independent of the visible cols).
    fn cell(self: *Terminal, x: usize, y: usize) *Cell {
        return &self.cells[y * MAX_COLS + x];
    }

    /// Blank the whole grid to default cells and home the cursor.
    fn clearGrid(self: *Terminal) void {
        for (self.cells) |*c| c.* = .{};
        self.cx = 0;
        self.cy = 0;
    }

    /// Scroll the FULL grid up one row (drop the oldest line — the only place
    /// content is destroyed outside `clear` — blank the new bottom line) and park
    /// the cursor on the grid's last row. Runs only when all MAX_ROWS are used;
    /// until then a newline just advances `cy` and the bottom-anchored view
    /// (viewTop) slides, which is what the user sees as scrolling.
    fn scroll(self: *Terminal) void {
        std.mem.copyForwards(Cell, self.cells[0 .. MAX_COLS * (MAX_ROWS - 1)], self.cells[MAX_COLS .. MAX_COLS * MAX_ROWS]);
        for (self.cells[MAX_COLS * (MAX_ROWS - 1) ..]) |*c| c.* = .{};
        self.cy = MAX_ROWS - 1;
    }

    /// Move the cursor to the start of the next row, scrolling the grid when its
    /// last row is used up.
    fn newline(self: *Terminal) void {
        self.cx = 0;
        self.cy += 1;
        if (self.cy >= MAX_ROWS) self.scroll();
    }

    /// Write one character at the cursor, advancing it (wrapping to the next row
    /// at the right edge). '\n' is a newline; other control chars are drawn as-is.
    pub fn putChar(self: *Terminal, ch: u8) void {
        // Test-hooks mirror: emit every committed grid line to the debug channel
        // (build.zig `-Dtest-hooks`; compiled out otherwise so a shipping image
        // pays nothing). This is the SINGLE grid-write sink for both the
        // single-core terminal and the SMP path (the system task drains the echo
        // ring through here), so one hook covers all command/echo output. The
        // integration harness (scripts/tests/) types a command over QMP/KMR1 and
        // greps the resulting `dbg: term.<id> = …` records for the expected
        // output — the only way command output leaves the GPU grid.
        if (comptime buildinfo.test_hooks) self.mirrorPut(ch);
        // Every grid write lands here or in backspaceCell/clearGrid: flag the
        // desktop so this window's damage gets marked (takeDirty).
        @atomicStore(bool, &self.dirty, true, .release);
        // New output snaps a scrolled view back to the bottom: what just
        // happened must be visible.
        self.view_off = 0;
        if (ch == '\n') {
            self.newline();
            return;
        }
        self.cell(self.cx, self.cy).* = .{ .ch = ch, .fg = self.fg, .bg = BG };
        self.cx += 1;
        if (self.cx >= self.cols) self.newline();
    }

    /// The desktop's tick: report-and-clear whether the grid changed since the
    /// last frame, so command output repaints its window (draw on damage).
    pub fn takeDirty(self: *Terminal) bool {
        if (!@atomicLoad(bool, &self.dirty, .acquire)) return false;
        @atomicStore(bool, &self.dirty, false, .release);
        return true;
    }

    /// Test-hooks output mirror (only reached under `comptime buildinfo.test_hooks`).
    /// Accumulate one grid line, flushing as a `dbg: term.<id> = …` record on
    /// newline. A line longer than debug.VAL_CAP flushes in VAL_CAP-byte chunks
    /// keyed `term.<id>+` (the `+` marks a wrap vs. a real line boundary) so the
    /// harness sees the full output in greppable ≤VAL_CAP windows without ever
    /// perturbing the kernel-wide VAL_CAP. '\r' is dropped so it never splits a line.
    fn mirrorPut(self: *Terminal, ch: u8) void {
        if (ch == '\r') return;
        if (ch == '\n') {
            self.mirrorFlush(false);
            return;
        }
        if (self.mirror_len == self.mirror_buf.len) self.mirrorFlush(true);
        self.mirror_buf[self.mirror_len] = ch;
        self.mirror_len += 1;
    }

    /// Emit the accumulated mirror line and reset. `wrapped` = a mid-line
    /// cap-overflow flush (key gets a `+` suffix); false = a real newline flush.
    /// A newline with nothing buffered still emits an empty line so the harness
    /// can prompt-gate on blank echoes.
    fn mirrorFlush(self: *Terminal, wrapped: bool) void {
        var kbuf: [debug.KEY_CAP]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "term.{d}{s}", .{ self.id, if (wrapped) "+" else "" }) catch "term.?";
        debug.set(.term, key, self.mirror_buf[0..self.mirror_len]);
        self.mirror_len = 0;
    }

    /// Write a string to the grid at the current color (each byte via putChar).
    pub fn write(self: *Terminal, s: []const u8) void {
        for (s) |ch| self.putChar(ch);
    }

    /// Write with an explicit color, then restore the default.
    pub fn writeColored(self: *Terminal, s: []const u8, color: Color) void {
        const saved = self.fg;
        self.fg = color;
        self.write(s);
        self.fg = saved;
    }

    /// Clear the terminal screen (the `clear` command).
    pub fn clear(self: *Terminal) void {
        self.clearGrid();
        @atomicStore(bool, &self.dirty, true, .release);
    }

    /// This terminal's cwd (normalized absolute VFS path — vfs.zig).
    pub fn cwd(self: *const Terminal) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    /// Set the cwd (callers pass a normalized absolute path ≤ vfs.MAX_PATH).
    pub fn setCwd(self: *Terminal, path: []const u8) void {
        @memcpy(self.cwd_buf[0..path.len], path);
        self.cwd_len = path.len;
    }

    /// Print the prompt in the prompt color. The AI agent window prompts a bare
    /// `ai>` (every line is a turn for the agent); a shell terminal prompts
    /// `#<id>:<cwd>$` — session id and working directory, closed with bash's
    /// `$` marker.
    pub fn prompt(self: *Terminal) void {
        if (self.ai_mode) {
            self.writeColored("ai> ", PROMPT_FG);
            return;
        }
        var buf: [vfs.MAX_PATH + 16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "#{d}:{s}$ ", .{ self.id, self.cwd() }) catch "#?$ ";
        self.writeColored(s, PROMPT_FG);
    }

    /// The automatic prompt after a command returns — the ONLY consumer of the
    /// hold (a held prompt skipped anywhere else would leave a terminal with no
    /// prompt at all).
    fn promptAfterCommand(self: *Terminal) void {
        if (self.hold_prompt) {
            self.hold_prompt = false;
            return;
        }
        self.prompt();
    }

    /// One line-editor echo. Masked input prints `*` — the mask covers the
    /// mirror too, since it hangs off putChar. Command output never comes
    /// through here.
    fn echoChar(self: *Terminal, ch: u8) void {
        self.putChar(if (self.input_mask and ch != '\n') '*' else ch);
    }

    /// Erase the cell left of the cursor and move the cursor back one column
    /// (no-op at column 0). Screen-only; the caller adjusts the line buffer.
    fn backspaceCell(self: *Terminal) void {
        // A long line WRAPS (putChar starts a new row at the right edge), so an
        // erase has to cross the same boundary the echo did — otherwise taking
        // back a wrapped tail (a case-corrected completion, an Up-arrow recall)
        // leaves its old glyphs on the row above. Nothing to cross at the top.
        if (self.cx == 0 and self.cy > 0) {
            self.cy -= 1;
            self.cx = self.cols;
        }
        if (self.cx > 0) {
            self.cx -= 1;
            self.cell(self.cx, self.cy).* = .{};
            @atomicStore(bool, &self.dirty, true, .release);
        }
    }

    /// Move the cursor `delta` cells (negative = left) across wrapped rows —
    /// the same boundary crossing backspaceCell does, in both directions.
    /// Content is untouched; the caller repaints through echo if it changed.
    fn moveCursorCells(self: *Terminal, delta: i32) void {
        var d = delta;
        while (d < 0) : (d += 1) {
            if (self.cx == 0) {
                if (self.cy == 0) break;
                self.cy -= 1;
                self.cx = self.cols;
            }
            self.cx -= 1;
        }
        while (d > 0) : (d -= 1) {
            self.cx += 1;
            if (self.cx >= self.cols) {
                self.cx = 0;
                self.cy += 1;
                if (self.cy >= MAX_ROWS) self.scroll();
            }
        }
        @atomicStore(bool, &self.dirty, true, .release);
    }

    /// editline.Screen echo bound to this grid (masked like every echo).
    fn scrEcho(ctx: ?*anyopaque, ch: u8) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx.?));
        t.echoChar(ch);
    }
    /// editline.Screen erase bound to this grid.
    fn scrErase(ctx: ?*anyopaque) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx.?));
        t.backspaceCell();
    }
    /// editline.Screen move bound to this grid.
    fn scrMove(ctx: ?*anyopaque, delta: i32) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx.?));
        t.moveCursorCells(delta);
    }
    /// This terminal's editline.Screen: echo/erase/move straight onto the cells.
    fn screen(self: *Terminal) editline.Screen {
        return .{ .ctx = self, .echoFn = scrEcho, .eraseFn = scrErase, .moveFn = scrMove };
    }

    /// Feed one ASCII key from the keyboard to the line editor (single-core
    /// path: the Terminal hosts the editor inline; editline owns the edit
    /// semantics, shared with the SMP session task). Scrollback keys are a
    /// VIEW change served here — the editor never sees them — and any other
    /// key snaps the view to the newest content, mirroring routeKey.
    pub fn onKey(self: *Terminal, ascii: u8) void {
        switch (ascii) {
            keymap.KEY_SHIFT_PGUP => return self.scrollBack(),
            keymap.KEY_SHIFT_PGDN => return self.scrollForward(),
            else => self.view_off = 0,
        }
        switch (self.ed.key(ascii, self.screen())) {
            .commit => {
                self.putChar('\n');
                self.runLine();
                self.ed.clearLine();
                self.promptAfterCommand();
            },
            .complete => self.completeFor(&self.ed),
            .interrupt => self.acknowledgeInterrupt(),
            .none, .recalled, .recall_empty => {},
        }
    }

    /// Run the committed line. A local command (prime/rt — CPU-bound / real-time,
    /// pegging THIS core, which on the single-core build is core 0) runs inline with
    /// output straight to the grid; anything else goes to the shell. The local
    /// command table is shared with the SMP editor (localcmd.zig), so the same
    /// commands exist on both builds.
    fn runLine(self: *Terminal) void {
        if (self.ai_mode) return self.execLine(self.ed.text());
        const parsed = shell.splitCommand(self.ed.text());
        if (localcmd.resolveLine(parsed.cmd, parsed.args)) |r| {
            const out = self.localOut();
            if (localcmd.refusesRedirect(r.args)) {
                out.str("error: '");
                out.str(r.c.name);
                out.str("' runs on this core and cannot pipe or redirect\n");
                return;
            }
            r.c.run(out, r.args);
            return;
        }
        shell.execute(self.console(), self.ed.text());
    }

    /// Run one committed command line through the shell. In the AI agent window
    /// (ai_mode) the whole line is a turn for the agent, dispatched as
    /// `ai <line>` — the same core-0 agent console the `ai` shell command drives,
    /// so there is one agent codebase and no cyclic import (apps → console →
    /// cmd/ai, never the reverse). A normal terminal runs the line verbatim.
    /// SMP: called by core 0's command worker; single-core: inline from runLine.
    fn execLine(self: *Terminal, line: []const u8) void {
        if (self.ai_mode) {
            var buf: [LINE_MAX + 9]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "kudos ai {s}", .{line}) catch return;
            shell.execute(self.console(), full);
        } else {
            shell.execute(self.console(), line);
        }
    }

    // --- console.Console grid half: the five ops a shell command runs against,
    // each a cast-and-forward onto this terminal (console/console.zig owns the
    // contract; the shell commands never see the Terminal type).
    fn conPut(ctx: *anyopaque, ch: u8) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.putChar(ch);
    }
    fn conClear(ctx: *anyopaque) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.clear();
    }
    fn conCwd(ctx: *anyopaque) []const u8 {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        return t.cwd();
    }
    fn conSetCwd(ctx: *anyopaque, path: []const u8) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.setCwd(path);
    }
    fn conPrompt(ctx: *anyopaque) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.prompt();
    }

    /// Console setAiModeFn: enter or leave the agent session on this terminal.
    /// The prompt changes with it (`ai>` against the shell's cwd prompt), so the
    /// line the user is about to type always says where it is going.
    fn conSetAiMode(ctx: *anyopaque, on: bool) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.ai_mode = on;
    }

    /// Console holdPromptFn: suppress the one automatic prompt after this command.
    fn conHoldPrompt(ctx: *anyopaque) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.hold_prompt = true;
    }

    /// Console setInputMaskFn. Unmasking forgets the editor recall — Up-arrow
    /// must not replay onto the screen what the echo hid.
    fn conSetInputMask(ctx: *anyopaque, on: bool) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.input_mask = on;
        if (!on) {
            if (t.session) |sess| sess.ed.forgetRecall() else t.ed.forgetRecall();
        }
    }

    /// Console setColorFn: color what the command writes next, 0 restoring the
    /// default — writeColored's set/write/restore shape stretched across the
    /// seam, with the command's resetColor as the restore.
    fn conSetColor(ctx: *anyopaque, argb: u32) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.fg = if (argb == 0) FG else argb;
    }

    /// Console readHistoryFn: the i-th committed line, oldest first. The
    /// history lives in the line EDITOR, which no shell command can see — this
    /// is the one window into it. Safe from the worker: while a proxied
    /// command (this call's host) runs, the session's editor task is parked on
    /// `busy` — the same handoff that lets run_line read the committed line.
    fn conReadHistory(ctx: *anyopaque, i: usize) ?[]const u8 {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        const ed = if (t.session) |sess| &sess.ed else &t.ed;
        return ed.historyAt(i);
    }

    /// The console surface over this terminal — what shell.execute hands each
    /// command: the grid half bound to this terminal, plus the desktop half
    /// and window handle this terminal was given at spawn.
    fn console(self: *Terminal) console_mod.Console {
        return .{
            .ctx = self,
            .putFn = conPut,
            .clearFn = conClear,
            .cwdFn = conCwd,
            .setCwdFn = conSetCwd,
            .promptFn = conPrompt,
            .desktop = self.desktop,
            .win = self.win,
            .win_id = self.win.id,
            .a = self.a,
            .ai_mode = self.ai_mode,
            .agent_window = self.agent_window,
            .setAiModeFn = conSetAiMode,
            .holdPromptFn = conHoldPrompt,
            .setInputMaskFn = conSetInputMask,
            .setColorFn = conSetColor,
            .readHistoryFn = conReadHistory,
        };
    }

    /// localcmd.Out putFn: write one char straight to this terminal's grid.
    fn outPut(ctx: *anyopaque, ch: u8) void {
        const t: *Terminal = @ptrCast(@alignCast(ctx));
        t.putChar(ch);
    }
    /// localcmd.Out aliveFn: always true — on the single-core build a local
    /// command runs synchronously, so the window cannot be torn down mid-run.
    fn outAlive(_: *anyopaque) bool {
        return true;
    }
    /// Build the localcmd.Out that routes a local command's output to this grid.
    fn localOut(self: *Terminal) localcmd.Out {
        return .{ .ctx = self, .putFn = outPut, .aliveFn = outAlive };
    }

    /// editline.complete.Dirs listFn bound to the live VFS — the whole IO half
    /// of Tab completion, kept out of the pure core. Serves both editor hosts:
    /// the single-core onKey and the SMP .complete request.
    fn dirsList(_: ?*anyopaque, abs: []const u8, cb: vfs.ifilesys.ListFn, cb_ctx: ?*anyopaque) vfs.ifilesys.Error!void {
        return vfs.list(abs, cb, cb_ctx);
    }

    /// The words a first-word completion can offer: the shell's built-ins plus
    /// the per-core local commands, each table still its own source of truth.
    const CMD_NAMES: []const []const u8 = &(shell.NAMES ++ localcmd.NAMES);

    /// The words the SECOND word of a `kudos` line can complete to: the
    /// shell-side subcommand table (cmd/kudos.zig) plus the local trio, each
    /// table still its own source of truth; the group word rides along so the
    /// pure core restates none of them.
    const KUDOS_GROUP = editline.complete.Group{
        .word = localcmd.GROUP,
        .names = &(kudoscmd.NAMES ++ localcmd.GROUP_NAMES),
    };

    /// The live enumeration seam handed to every completion on this terminal.
    fn dirs() editline.complete.Dirs {
        return .{ .ctx = null, .listFn = dirsList };
    }

    /// Serve one Tab press for `ed` (the single-core editor is the Terminal's
    /// own; the SMP editor is its session's) — grow the line, and when several
    /// entries match and nothing more can be added, SHOW them below the line
    /// and re-draw the prompt, the way a user expects a second Tab to answer.
    fn completeFor(self: *Terminal, ed: *editline.Editor) void {
        // The AI window takes no filename arguments, so its Tab completes
        // nothing.
        if (self.ai_mode) return;
        if (ed.completeLine(self.cwd(), dirs(), CMD_NAMES, KUDOS_GROUP, self.screen()) != .ambiguous) return;
        self.putChar('\n');
        var listing = Listing{ .t = self };
        editline.complete.eachMatch(ed.text(), self.cwd(), dirs(), CMD_NAMES, KUDOS_GROUP, .{
            .ctx = &listing,
            .entryFn = candidateOut,
        });
        // What the listing left out is STATED, never silently dropped: a
        // directory with hundreds of entries would otherwise scroll the
        // question off the screen along with the answer.
        if (listing.total > listing.shown) {
            var buf: [40]u8 = undefined;
            self.write(std.fmt.bufPrint(&buf, "... {d} more", .{listing.total - listing.shown}) catch "... more");
        }
        self.putChar('\n');
        self.prompt();
        for (ed.text()) |ch| self.putChar(ch);
    }

    /// How many candidates one ambiguous Tab prints before it summarises the
    /// rest — enough to choose from, few enough to leave the prompt and the
    /// line the user was typing on screen.
    const CANDIDATES_SHOWN: usize = 32;

    /// One ambiguity listing in progress: what has been printed, and how much
    /// there was to print.
    const Listing = struct {
        t: *Terminal,
        shown: usize = 0,
        total: usize = 0,
    };

    /// One candidate in the ambiguity listing: the name, a '/' if it is a
    /// directory, and two spaces — the grid wraps the row itself.
    fn candidateOut(ctx: ?*anyopaque, name: []const u8, kind: vfs.ifilesys.Kind) void {
        const l: *Listing = @ptrCast(@alignCast(ctx.?));
        l.total += 1;
        if (l.shown >= CANDIDATES_SHOWN) return;
        l.shown += 1;
        const self = l.t;
        for (name) |ch| self.putChar(ch);
        if (kind == .dir) self.putChar('/');
        self.putChar(' ');
        self.putChar(' ');
    }

    /// Render the grid into the whole-desktop GL frame (the unified pipeline). The
    /// painter's origin is already at this window's CONTENT top-left, so everything is
    /// content-local cell arithmetic. Cell backgrounds paint only where they differ
    /// from the terminal's own background — the window's frosted body IS the
    /// background on this path, so painting it again would double the frost. Two
    /// batches: white-texel rects, then atlas glyphs.
    pub fn drawGl(self: *Terminal, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, focused: bool, blink_on: bool) void {
        const top = self.viewTop();
        const vx = @min(self.cx, self.cols - 1);
        const vy = self.cy - top;
        const fw: f32 = @floatFromInt(font.WIDTH);
        const fh: f32 = @floatFromInt(font.HEIGHT);
        var y: usize = 0;
        while (y < self.rows) : (y += 1) {
            var x: usize = 0;
            while (x < self.cols) : (x += 1) {
                const cl = self.cells[(top + y) * MAX_COLS + x];
                if (cl.bg != BG)
                    p.fillRect(@as(f32, @floatFromInt(x)) * fw, @as(f32, @floatFromInt(y)) * fh, fw, fh, cl.bg);
            }
        }
        y = 0;
        while (y < self.rows) : (y += 1) {
            var x: usize = 0;
            while (x < self.cols) : (x += 1) {
                const cl = self.cells[(top + y) * MAX_COLS + x];
                if (cl.ch == ' ' or cl.ch == 0) continue;
                const s = [1]u8{cl.ch};
                p.text(atlas_tex, atlas, &s, @as(f32, @floatFromInt(x)) * fw, @as(f32, @floatFromInt(y)) * fh, cl.fg);
            }
        }
        // The cursor exists only at the bottom view: a scrolled-back window
        // shows history, and the edit point is not in it.
        if (focused and blink_on and self.view_off == 0) {
            const thickness = 2;
            p.fillRect(@as(f32, @floatFromInt(vx)) * fw, @as(f32, @floatFromInt(vy)) * fh + fh - thickness, fw, thickness, CURSOR);
        }
    }

    /// Screen-space rect of the cursor cell — the only pixels a blink changes.
    /// The desktop marks just this (instead of the whole window) on blink phase
    /// flips. Uses the cursor's VIEW position
    /// (view-translated row, edge-clamped column) — the same cell draw() paints.
    pub fn cursorCellScreen(self: *const Terminal) struct { x: i32, y: i32, w: usize, h: usize } {
        const vx = @min(self.cx, self.cols - 1);
        // Edge-clamped like the column: a scrolled-back view has no cursor on
        // screen (drawGl skips it), so the blink rect just stays in-window.
        const vy = @min(self.cy - self.viewTop(), self.rows - 1);
        return .{
            .x = self.win.contentX() + @as(i32, @intCast(vx * font.WIDTH)),
            .y = self.win.contentY() + @as(i32, @intCast(vy * font.HEIGHT)),
            .w = font.WIDTH,
            .h = font.HEIGHT,
        };
    }
};
