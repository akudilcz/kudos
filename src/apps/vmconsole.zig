//! VM console terminal emulation — a fixed 80x25 cell grid fed one byte at a
//! time from the guest's UART stream, plus the encoding of named keys headed
//! the other way (`keySequence`). Pure state machine over `feed` (no IO, no
//! allocation), host-tested (test/apps/vmconsole_test.zig); the VM console app owns
//! one and renders `row` slices through the desktop toolkit.
//!
//! The feeder interprets the VT100/ANSI (ECMA-48) subset a guest's full-screen
//! serial text UI draws with (the Debian installer's newt menus, ncurses):
//! cursor addressing, erase display/line, scroll regions, insert/delete of
//! lines and characters, SGR colour (kept per cell), the DEC special-graphics
//! charset (box-drawing, approximated in ASCII), and deferred line wrap.
//! Every sequence it does not act on — DEC private modes, OSC strings, device
//! queries — is swallowed whole, never sprayed into the grid, and every
//! unhandled control byte is discarded, so no input can corrupt the cells or
//! move the cursor out of bounds.

const std = @import("std");
const keymap = @import("keymap");
const Ring = @import("ring").Ring;

pub const COLS = 80;
pub const ROWS = 25;

/// Tab stops every 8 columns, the terminal default the guest assumes.
const TAB_STOP = 8;

// The control bytes the feeder acts on (ASCII names).
const BEL: u8 = 0x07; // bell — also terminates an OSC string
const BS: u8 = 0x08; // backspace
const HT: u8 = 0x09; // horizontal tab
const LF: u8 = 0x0A; // line feed
const SO: u8 = 0x0E; // shift out — select the G1 charset
const SI: u8 = 0x0F; // shift in — select the G0 charset
const CR: u8 = 0x0D; // carriage return
const ESC: u8 = 0x1B; // escape — opens a control sequence

// ECMA-48 CSI byte classes: parameter/intermediate bytes continue a control
// sequence; a final byte ends it.
const CSI_PARAM_LO: u8 = 0x20;
const CSI_PARAM_HI: u8 = 0x3F;
const CSI_FINAL_LO: u8 = 0x40;
const CSI_FINAL_HI: u8 = 0x7E;

// ESC intermediate bytes (ECMA-48 §13.2): they extend a plain escape by one
// byte, as in the charset designations ESC ( 0 and ESC ) 0.
const ESC_INTERMEDIATE_LO: u8 = 0x20;
const ESC_INTERMEDIATE_HI: u8 = 0x2F;

// Printable ASCII: space through tilde.
const PRINT_LO: u8 = 0x20;
const PRINT_HI: u8 = 0x7E;

/// Where the escape parser stands: outside any sequence, after a lone ESC,
/// after an ESC intermediate (a charset designation awaiting its final byte),
/// inside a CSI (ESC '[') sequence, or inside an OSC (ESC ']') string —
/// which runs to BEL or the two-byte string terminator ESC '\'.
const EscState = enum(u8) { none, esc, esc_charset, csi, osc, osc_esc };

/// The bright twin of an ANSI colour index.
fn brighten(c: u4) u4 {
    return if (c < 8) c + 8 else c;
}

/// Longest CSI parameter string kept. Cursor addressing ("ESC [ 24 ; 80 H")
/// and SGR runs are far shorter; a longer sequence is still swallowed
/// correctly, it just stops contributing parameters — no sequence is worth an
/// unbounded buffer.
const PARAM_CAP = 16;

/// SGR codes this console acts on (ECMA-48 §8.3.117).
const SGR_RESET: u16 = 0;
const SGR_BOLD: u16 = 1;
const SGR_FG_FIRST: u16 = 30; // 30..37 select the normal foreground colours
const SGR_FG_DEFAULT: u16 = 39;
const SGR_BRIGHT_FG_FIRST: u16 = 90; // 90..97 select the bright set directly

/// The charset final byte designating the DEC special-graphics (box-drawing)
/// set, as in ESC ( 0; any other designation is treated as US-ASCII.
const CHARSET_DEC_GRAPHICS: u8 = '0';

/// A cell's foreground colour: an ANSI index (0-7 normal, 8-15 bright), or null
/// for "whatever the window paints unstyled text in". The console names the
/// index and nothing else — which pixels an index means is the surface's
/// business (ui/screen/theme.zig).
pub const Color = ?u4;

/// The byte sequence a named key sends down the guest tty, or null for an
/// ordinary character that goes as itself. The desktop's keyboard path carries
/// arrows as keymap's control bytes; a guest tty expects the VT100 cursor
/// sequences (ECMA-48 CUU/CUD/CUF/CUB) — the same encoding this module's
/// feeder reads in the guest-to-screen direction.
pub fn keySequence(ascii: u8) ?[]const u8 {
    return switch (ascii) {
        keymap.KEY_UP => "\x1b[A",
        keymap.KEY_DOWN => "\x1b[B",
        keymap.KEY_RIGHT => "\x1b[C",
        keymap.KEY_LEFT => "\x1b[D",
        else => null,
    };
}

pub const Console = struct {
    cells: [ROWS * COLS]u8,
    /// Foreground colour per cell, parallel to `cells`.
    colors: [ROWS * COLS]Color,
    cx: u8,
    cy: u8,
    esc: EscState,
    /// The colour subsequent output is written in, as the last SGR set it.
    pen: Color,
    /// Parameter bytes collected since the CSI opened.
    params: [PARAM_CAP]u8,
    param_len: u8,
    /// The cursor DECSC (ESC 7) / SCP (CSI s) saved, for DECRC / RCP to restore.
    saved_cx: u8,
    saved_cy: u8,
    /// Deferred wrap: writing the last column leaves the cursor ON it and arms
    /// this flag; the NEXT printable wraps first. This is the VT100 rule that
    /// lets a full-screen UI paint the bottom-right cell without scrolling.
    wrap_pending: bool,
    /// DECSTBM scroll region, inclusive 0-based rows. A line feed on the bottom
    /// margin scrolls only these rows, so an ncurses UI can scroll a pane while
    /// its frame stands still.
    scroll_top: u8,
    scroll_bot: u8,
    /// Which charset slot the pending ESC intermediate designates ('(' = G0,
    /// ')' = G1; anything else is a non-charset escape, swallowed).
    charset_slot: u8,
    /// True while a slot holds the DEC special-graphics set.
    g0_graphics: bool,
    g1_graphics: bool,
    /// Shift-out (SO) selects G1 until shift-in (SI) returns to G0 — the route
    /// ncurses takes to its box-drawing characters on a VT102.
    shift_out: bool,

    /// A blank grid (all spaces), cursor at the top-left, pen at the default,
    /// the scroll region the full screen, US-ASCII in both charset slots.
    pub fn init() Console {
        return .{
            .cells = [_]u8{' '} ** (ROWS * COLS),
            .colors = [_]Color{null} ** (ROWS * COLS),
            .cx = 0,
            .cy = 0,
            .esc = .none,
            .pen = null,
            .params = [_]u8{0} ** PARAM_CAP,
            .param_len = 0,
            .saved_cx = 0,
            .saved_cy = 0,
            .wrap_pending = false,
            .scroll_top = 0,
            .scroll_bot = ROWS - 1,
            .charset_slot = 0,
            .g0_graphics = false,
            .g1_graphics = false,
            .shift_out = false,
        };
    }

    /// Interpret one byte of the guest's serial output.
    pub fn feed(self: *Console, b: u8) void {
        switch (self.esc) {
            .esc => {
                switch (b) {
                    '[' => {
                        self.esc = .csi;
                        self.param_len = 0;
                    },
                    ']' => self.esc = .osc,
                    ESC_INTERMEDIATE_LO...ESC_INTERMEDIATE_HI => {
                        // A charset designation (or another two-byte escape
                        // family): remember which slot, await the final byte.
                        self.charset_slot = b;
                        self.esc = .esc_charset;
                    },
                    else => {
                        self.escFinal(b);
                        self.esc = .none;
                    },
                }
                return;
            },
            .esc_charset => {
                // The final byte selects the charset for the designated slot;
                // non-charset escapes (ESC # 8 and kin) end here with no effect.
                if (self.charset_slot == '(') self.g0_graphics = (b == CHARSET_DEC_GRAPHICS);
                if (self.charset_slot == ')') self.g1_graphics = (b == CHARSET_DEC_GRAPHICS);
                self.esc = .none;
                return;
            },
            .csi => {
                // Parameter/intermediate bytes continue the sequence and are
                // kept; a final byte dispatches it; a fresh ESC restarts (a
                // truncated sequence must not eat the one that follows); any
                // other stray control byte aborts. Unknown finals end the
                // sequence discarded — consumed, never printed.
                if (b == ESC) {
                    self.esc = .esc;
                    return;
                }
                if (b >= CSI_PARAM_LO and b <= CSI_PARAM_HI) {
                    if (self.param_len < PARAM_CAP) {
                        self.params[self.param_len] = b;
                        self.param_len += 1;
                    }
                    return;
                }
                if (b >= CSI_FINAL_LO and b <= CSI_FINAL_HI) self.csiFinal(b);
                self.esc = .none;
                return;
            },
            .osc => {
                // An OSC string (a window title and kin) has no place on this
                // grid: swallow to its BEL or ESC '\' terminator.
                if (b == BEL) self.esc = .none;
                if (b == ESC) self.esc = .osc_esc;
                return;
            },
            .osc_esc => {
                // The byte after the string's ESC — '\' for the standard
                // terminator; anything else still ends the swallow.
                self.esc = .none;
                return;
            },
            .none => {},
        }
        switch (b) {
            ESC => self.esc = .esc,
            LF => {
                self.wrap_pending = false;
                self.lineFeed();
            },
            CR => {
                self.wrap_pending = false;
                self.cx = 0;
            },
            BS => {
                // Cursor motion only — a terminal never erases on BS; the
                // guest that wants an erase sends BS SP BS.
                self.wrap_pending = false;
                self.cx -|= 1;
            },
            HT => self.tab(),
            SO => self.shift_out = true,
            SI => self.shift_out = false,
            else => if (b >= PRINT_LO and b <= PRINT_HI) self.put(b),
            // Every other control byte (BEL, NUL, DEL, ...) is discarded.
        }
    }

    /// The r-th visible row's COLS bytes (row 0 on top).
    pub fn row(self: *const Console, r: usize) []const u8 {
        return self.cells[r * COLS ..][0..COLS];
    }

    /// The r-th visible row's per-cell colours, parallel to `row`.
    pub fn rowColors(self: *const Console, r: usize) []const Color {
        return self.colors[r * COLS ..][0..COLS];
    }

    /// A plain escape's final byte (no intermediates). Only the VT100 cursor
    /// and reset controls mean anything on this grid; the rest (keypad modes,
    /// DECALN, ...) are swallowed.
    fn escFinal(self: *Console, b: u8) void {
        self.wrap_pending = false;
        switch (b) {
            '7' => { // DECSC — save cursor
                self.saved_cx = self.cx;
                self.saved_cy = self.cy;
            },
            '8' => { // DECRC — restore cursor
                self.cx = self.saved_cx;
                self.cy = self.saved_cy;
            },
            'D' => self.lineFeed(), // IND — index
            'E' => { // NEL — next line
                self.cx = 0;
                self.lineFeed();
            },
            'M' => { // RI — reverse index: up one row, scrolling down at the top margin
                if (self.cy == self.scroll_top) {
                    self.scrollDown(self.scroll_top, self.scroll_bot);
                } else if (self.cy > 0) {
                    self.cy -= 1;
                }
            },
            'c' => self.* = init(), // RIS — reset to initial state
            else => {},
        }
    }

    /// Dispatch a completed CSI sequence on its final byte. Anything not named
    /// here — mode sets ('h'/'l', DEC private included), device queries, the
    /// long tail — is consumed with no visible effect.
    fn csiFinal(self: *Console, b: u8) void {
        // Every cursor/erase control lands the cursor somewhere definite; only
        // SGR must preserve a pending wrap (colour changes mid-line at the
        // right margin are common in wrapped listings).
        if (b != 'm') self.wrap_pending = false;
        switch (b) {
            'm' => self.applySgr(),
            'A' => { // CUU — cursor up, stopping at the top margin when below it
                const floor = if (self.cy >= self.scroll_top) self.scroll_top else 0;
                self.cy = @max(floor, self.cy -| self.countParam());
            },
            'B' => { // CUD — cursor down, stopping at the bottom margin when above it
                const ceil = if (self.cy <= self.scroll_bot) self.scroll_bot else ROWS - 1;
                self.cy = @min(ceil, self.cy +| self.countParam());
            },
            'C' => self.cx = @min(COLS - 1, self.cx +| self.countParam()), // CUF
            'D' => self.cx = self.cx -| self.countParam(), // CUB
            'G' => self.cx = self.posParam(0, COLS), // CHA — column absolute
            'd' => self.cy = self.posParam(0, ROWS), // VPA — row absolute
            'H', 'f' => { // CUP/HVP — cursor position, 1-based row;col
                self.cy = self.posParam(0, ROWS);
                self.cx = self.posParam(1, COLS);
            },
            'J' => self.eraseDisplay(self.paramAt(0) orelse 0), // ED
            'K' => self.eraseLine(self.paramAt(0) orelse 0), // EL
            'L' => { // IL — insert blank lines at the cursor, inside the region
                if (self.cy >= self.scroll_top and self.cy <= self.scroll_bot) {
                    var n = self.countParam();
                    while (n > 0) : (n -= 1) self.scrollDown(self.cy, self.scroll_bot);
                }
            },
            'M' => { // DL — delete lines at the cursor, inside the region
                if (self.cy >= self.scroll_top and self.cy <= self.scroll_bot) {
                    var n = self.countParam();
                    while (n > 0) : (n -= 1) self.scrollUp(self.cy, self.scroll_bot);
                }
            },
            'P' => self.deleteChars(self.countParam()), // DCH
            '@' => self.insertChars(self.countParam()), // ICH
            'X' => self.eraseChars(self.countParam()), // ECH
            'r' => { // DECSTBM — set the scroll region, home the cursor
                const top = @max(self.paramAt(0) orelse 1, 1);
                const bot = @min(self.paramAt(1) orelse ROWS, ROWS);
                if (top < bot) {
                    self.scroll_top = @intCast(top - 1);
                    self.scroll_bot = @intCast(bot - 1);
                    self.cx = 0;
                    self.cy = 0;
                }
            },
            's' => { // SCP — save cursor (the ANSI twin of ESC 7)
                self.saved_cx = self.cx;
                self.saved_cy = self.cy;
            },
            'u' => { // RCP — restore cursor
                self.cx = self.saved_cx;
                self.cy = self.saved_cy;
            },
            else => {},
        }
    }

    /// The idx-th numeric parameter of the pending sequence, or null when it is
    /// absent, empty, or non-numeric (a DEC private '?' marker, an overlong field).
    fn paramAt(self: *const Console, idx: usize) ?u16 {
        var it = std.mem.splitScalar(u8, self.params[0..self.param_len], ';');
        var i: usize = 0;
        while (it.next()) |field| : (i += 1) {
            if (i == idx) return std.fmt.parseInt(u16, field, 10) catch null;
        }
        return null;
    }

    /// The first parameter as a repeat count: absent or 0 means 1 (the ECMA-48
    /// default), capped so no count outruns the grid's own bounds checks.
    fn countParam(self: *const Console) u8 {
        return @intCast(std.math.clamp(self.paramAt(0) orelse 1, 1, std.math.maxInt(u8)));
    }

    /// The idx-th parameter as a 1-based position clamped into [1, limit],
    /// returned as a 0-based index. Absent or 0 means 1.
    fn posParam(self: *const Console, idx: usize, limit: u16) u8 {
        const v = @max(self.paramAt(idx) orelse 1, 1);
        return @intCast(@min(v, limit) - 1);
    }

    /// Apply the collected SGR parameters to the pen. Unknown codes are ignored
    /// rather than guessed at; a bare "ESC [ m" resets, as ECMA-48 says.
    fn applySgr(self: *Console) void {
        if (self.param_len == 0) {
            self.pen = null;
            return;
        }
        var bright = false;
        var it = std.mem.splitScalar(u8, self.params[0..self.param_len], ';');
        while (it.next()) |field| {
            const code = std.fmt.parseInt(u16, field, 10) catch continue;
            switch (code) {
                SGR_RESET => {
                    self.pen = null;
                    bright = false;
                },
                // Bold means "bright" on a terminal with no bold face, which is
                // exactly what a fixed-cell bitmap console is. It applies to the
                // colour selected in the same sequence, hence the flag.
                SGR_BOLD => {
                    bright = true;
                    if (self.pen) |c| self.pen = brighten(c);
                },
                SGR_FG_DEFAULT => self.pen = null,
                SGR_FG_FIRST...SGR_FG_FIRST + 7 => {
                    const base: u4 = @intCast(code - SGR_FG_FIRST);
                    self.pen = if (bright) brighten(base) else base;
                },
                SGR_BRIGHT_FG_FIRST...SGR_BRIGHT_FG_FIRST + 7 => {
                    self.pen = brighten(@intCast(code - SGR_BRIGHT_FG_FIRST));
                },
                else => {}, // backgrounds, underline, and the rest: not shown
            }
        }
    }

    /// Blank the cells in [from, to) — the one primitive every erase shares.
    fn clearCells(self: *Console, from: usize, to: usize) void {
        @memset(self.cells[from..to], ' ');
        @memset(self.colors[from..to], null);
    }

    /// ED — erase display: 0 cursor→end, 1 start→cursor, 2/3 everything.
    /// The cursor does not move (a full clear is always paired with a CUP).
    fn eraseDisplay(self: *Console, mode: u16) void {
        const cur = @as(usize, self.cy) * COLS + self.cx;
        switch (mode) {
            0 => self.clearCells(cur, ROWS * COLS),
            1 => self.clearCells(0, cur + 1),
            2, 3 => self.clearCells(0, ROWS * COLS),
            else => {},
        }
    }

    /// EL — erase line: 0 cursor→end, 1 start→cursor, 2 the whole line.
    fn eraseLine(self: *Console, mode: u16) void {
        const start = @as(usize, self.cy) * COLS;
        const cur = start + self.cx;
        switch (mode) {
            0 => self.clearCells(cur, start + COLS),
            1 => self.clearCells(start, cur + 1),
            2 => self.clearCells(start, start + COLS),
            else => {},
        }
    }

    /// DCH — delete n cells at the cursor: the rest of the line pulls left,
    /// the vacated tail blanks.
    fn deleteChars(self: *Console, n: u8) void {
        const start = @as(usize, self.cy) * COLS + self.cx;
        const line_end = (@as(usize, self.cy) + 1) * COLS;
        const cnt = @min(@as(usize, n), line_end - start);
        std.mem.copyForwards(u8, self.cells[start .. line_end - cnt], self.cells[start + cnt .. line_end]);
        std.mem.copyForwards(Color, self.colors[start .. line_end - cnt], self.colors[start + cnt .. line_end]);
        self.clearCells(line_end - cnt, line_end);
    }

    /// ICH — insert n blank cells at the cursor: the rest of the line pushes
    /// right, whatever passes the last column falls off.
    fn insertChars(self: *Console, n: u8) void {
        const start = @as(usize, self.cy) * COLS + self.cx;
        const line_end = (@as(usize, self.cy) + 1) * COLS;
        const cnt = @min(@as(usize, n), line_end - start);
        std.mem.copyBackwards(u8, self.cells[start + cnt .. line_end], self.cells[start .. line_end - cnt]);
        std.mem.copyBackwards(Color, self.colors[start + cnt .. line_end], self.colors[start .. line_end - cnt]);
        self.clearCells(start, start + cnt);
    }

    /// ECH — erase n cells from the cursor in place; nothing shifts.
    fn eraseChars(self: *Console, n: u8) void {
        const start = @as(usize, self.cy) * COLS + self.cx;
        const line_end = (@as(usize, self.cy) + 1) * COLS;
        self.clearCells(start, @min(start + n, line_end));
    }

    /// Write a printable byte at the cursor and advance; an armed deferred
    /// wrap fires first (see `wrap_pending`). The active charset maps DEC
    /// box-drawing to its ASCII stand-ins.
    fn put(self: *Console, b: u8) void {
        if (self.wrap_pending) {
            self.wrap_pending = false;
            self.cx = 0;
            self.lineFeed();
        }
        const graphics = if (self.shift_out) self.g1_graphics else self.g0_graphics;
        const i = @as(usize, self.cy) * COLS + self.cx;
        self.cells[i] = if (graphics) decGraphics(b) else b;
        self.colors[i] = self.pen;
        if (self.cx + 1 == COLS) {
            self.wrap_pending = true;
        } else {
            self.cx += 1;
        }
    }

    /// Move down one row, keeping the column (the guest's tty discipline sends
    /// CR LF for a newline); on the region's bottom margin, scroll the region
    /// instead; below the region, stop at the screen's last row.
    fn lineFeed(self: *Console) void {
        if (self.cy == self.scroll_bot) {
            self.scrollUp(self.scroll_top, self.scroll_bot);
        } else if (self.cy + 1 < ROWS) {
            self.cy += 1;
        }
    }

    /// Advance to the next tab stop, pinned to the last column at the right
    /// margin (a tab never wraps, matching terminal convention).
    fn tab(self: *Console) void {
        self.wrap_pending = false;
        const next = (@as(usize, self.cx) / TAB_STOP + 1) * TAB_STOP;
        self.cx = @intCast(@min(next, COLS - 1));
    }

    /// Scroll rows top..bot (inclusive) up one: the top row leaves, a blank
    /// row enters at the bottom. The cursor is unchanged.
    fn scrollUp(self: *Console, top: u8, bot: u8) void {
        const t = @as(usize, top) * COLS;
        const e = (@as(usize, bot) + 1) * COLS;
        std.mem.copyForwards(u8, self.cells[t .. e - COLS], self.cells[t + COLS .. e]);
        std.mem.copyForwards(Color, self.colors[t .. e - COLS], self.colors[t + COLS .. e]);
        self.clearCells(e - COLS, e);
    }

    /// Scroll rows top..bot (inclusive) down one: the bottom row leaves, a
    /// blank row enters at the top. The cursor is unchanged.
    fn scrollDown(self: *Console, top: u8, bot: u8) void {
        const t = @as(usize, top) * COLS;
        const e = (@as(usize, bot) + 1) * COLS;
        std.mem.copyBackwards(u8, self.cells[t + COLS .. e], self.cells[t .. e - COLS]);
        std.mem.copyBackwards(Color, self.colors[t + COLS .. e], self.colors[t .. e - COLS]);
        self.clearCells(t, t + COLS);
    }
};

/// The DEC special-graphics set, approximated in ASCII: box corners, tees and
/// crossings become '+', the horizontal and vertical lines '-' and '|', the
/// checkerboard fill '#' — enough for a newt/ncurses frame to read as a frame
/// on a plain glyph grid. Codes outside the box-drawing range show as
/// themselves.
fn decGraphics(b: u8) u8 {
    return switch (b) {
        'j', 'k', 'l', 'm', 'n', 't', 'u', 'v', 'w' => '+',
        'q' => '-',
        'x' => '|',
        'a' => '#',
        else => b,
    };
}

/// Keystrokes typed at a VM console window that its guest's serial ring has not
/// taken yet (spec VIRT-036).
///
/// The mailbox ring is sized for a human at a keyboard. A machine delivers a
/// command line in one burst, far faster than a busy guest's tty drains, and a
/// byte lost there does not look lost — it looks like a command that was
/// mistyped. This queue holds the overflow on the WINDOW, which can wait,
/// rather than on the sender, which cannot see the loss.
///
/// EVERY byte enters here, including one the guest could take immediately.
/// That is what makes the order structural rather than a rule someone has to
/// remember: with no fast path there is nothing for a later byte to overtake,
/// so a command line arrives delayed or truncated, never scrambled.
pub const SerialQueue = struct {
    /// Depth: one long command line's worth. Beyond that the sender is faster
    /// than the guest by more than a burst, which is a loss worth reporting
    /// rather than an overflow worth absorbing.
    pub const CAP = 256;

    q: Ring(u8, CAP) = .{},

    /// Take one byte for the guest. False = the queue is full and this byte is
    /// lost; the caller counts it (the mailbox owns that counter).
    pub fn offer(self: *SerialQueue, b: u8) bool {
        return self.q.push(b);
    }

    /// The next byte owed to the guest, or null when it is caught up. Does not
    /// consume — the guest's ring may still refuse it, and a byte taken out of
    /// this queue and then refused would be gone.
    pub fn next(self: *SerialQueue) ?u8 {
        return if (self.q.peek()) |p| p.* else null;
    }

    /// Confirm the guest took the byte `next` reported.
    pub fn advance(self: *SerialQueue) void {
        self.q.drop();
    }

    pub fn isEmpty(self: *SerialQueue) bool {
        return self.q.isEmpty();
    }
};

/// Whether the VM window shows the guest's SCANOUT rather than its serial
/// console (spec VIRT-016).
///
/// Two conditions, and the second is the one that is easy to miss: a guest
/// arms its scanout (SET_SCANOUT) before it has drawn a single pixel into it,
/// so a window that switched on the texture alone would blank a console still
/// carrying the boot log — replacing the one thing the user needs to read
/// during bring-up with an empty rectangle. The window waits for the guest's
/// first FLUSH, and only then is there something to show.
pub fn showsScanout(has_texture: bool, flushed_once: bool) bool {
    return has_texture and flushed_once;
}
