//! Host tests of src/apps/vmconsole.zig — the 80x25 VT100/ANSI serial-console
//! terminal grid. Feeds guest-style byte streams and checks the visible cells:
//! printable placement, deferred wrap, CR/LF/BS/TAB, scrolling and scroll
//! regions, cursor addressing, erase, insert/delete, SGR colour, the DEC
//! graphics charset, and that every unhandled escape sequence and stray
//! control byte leaves no trace. The other direction too: the VT sequences
//! named keys are encoded as for the guest tty.

const std = @import("std");
const vmconsole = @import("vmconsole");
const keymap = @import("keymap");
const Console = vmconsole.Console;
const COLS = vmconsole.COLS;
const ROWS = vmconsole.ROWS;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

fn feedAll(c: *Console, bytes: []const u8) void {
    for (bytes) |b| c.feed(b);
}

fn expectBlankRow(c: *const Console, r: usize) !void {
    for (c.row(r)) |cell| try expectEqual(@as(u8, ' '), cell);
}

test "init: all spaces, cursor at the top-left" {
    var c = Console.init();
    for (0..ROWS) |r| try expectBlankRow(&c, r);
    try expectEqual(@as(u8, 0), c.cx);
    try expectEqual(@as(u8, 0), c.cy);
}

test "printable text lands at the cursor and advances" {
    var c = Console.init();
    feedAll(&c, "hi");
    try expectEqualSlices(u8, "hi", c.row(0)[0..2]);
    try expectEqual(@as(u8, ' '), c.row(0)[2]); // nothing beyond the cursor
    c.feed('!'); // lands where the cursor advanced to, not back at 0
    try expectEqualSlices(u8, "hi!", c.row(0)[0..3]);
}

test "wrap at column 80: the 81st byte starts row 1" {
    var c = Console.init();
    for (0..COLS) |_| c.feed('a');
    c.feed('b');
    try expectEqual(@as(u8, 'a'), c.row(0)[COLS - 1]); // row 0 filled to the edge
    try expectEqual(@as(u8, 'b'), c.row(1)[0]); // wrapped, not overwritten
    try expectEqual(@as(u8, 1), c.cy);
}

test "deferred wrap: the bottom-right cell fills without scrolling" {
    var c = Console.init();
    feedAll(&c, "top");
    feedAll(&c, "\x1b[25;80HX"); // the far corner
    try expectEqual(@as(u8, 'X'), c.row(ROWS - 1)[COLS - 1]);
    try expectEqualSlices(u8, "top", c.row(0)[0..3]); // nothing scrolled yet
    feedAll(&c, "\x1b[31m"); // SGR must not cancel the pending wrap
    c.feed('Y'); // the NEXT glyph wraps, and at the bottom row that scrolls
    try expectEqual(@as(u8, 'Y'), c.row(ROWS - 1)[0]);
    try expectEqual(@as(u8, 'X'), c.row(ROWS - 2)[COLS - 1]);
}

test "line feed moves down keeping the column; carriage return rewinds it" {
    var c = Console.init();
    feedAll(&c, "ab\ncd");
    try expectEqualSlices(u8, "ab", c.row(0)[0..2]);
    try expectEqualSlices(u8, "cd", c.row(1)[2..4]); // LF kept column 2
    feedAll(&c, "\rX");
    try expectEqual(@as(u8, 'X'), c.row(1)[0]); // CR rewound to column 0
    try expectEqualSlices(u8, "cd", c.row(1)[2..4]); // without erasing the line
}

test "backspace steps left without erasing; a no-op at column 0" {
    var c = Console.init();
    feedAll(&c, "ab\x08");
    try expectEqualSlices(u8, "ab", c.row(0)[0..2]); // the cell survives — a guest erases with BS SP BS
    c.feed('X'); // cursor stepped back: X overwrites where b was
    try expectEqualSlices(u8, "aX", c.row(0)[0..2]);
    feedAll(&c, "\x08\x08\x08q"); // more BS than columns — pinned at 0
    try expectEqualSlices(u8, "qX", c.row(0)[0..2]);
}

test "tab advances to the next multiple of 8" {
    var c = Console.init();
    feedAll(&c, "a\tb");
    try expectEqual(@as(u8, 'a'), c.row(0)[0]);
    try expectEqual(@as(u8, 'b'), c.row(0)[8]); // next stop after column 1 is 8
    c.feed('\t');
    c.feed('c');
    try expectEqual(@as(u8, 'c'), c.row(0)[16]); // from column 9, next stop is 16
    for (c.row(0)[1..8]) |cell| try expectEqual(@as(u8, ' '), cell); // tab skips, never writes
}

test "scroll: the 26th line pushes the top row off, content bottom-anchored" {
    var c = Console.init();
    // 26 marker lines 'A'..'Z', CR LF between them (the guest tty sends both).
    for (0..26) |i| {
        c.feed('A' + @as(u8, @intCast(i)));
        if (i != 25) feedAll(&c, "\r\n");
    }
    try expectEqual(@as(u8, 'B'), c.row(0)[0]); // 'A' scrolled off
    try expectEqual(@as(u8, 'Y'), c.row(ROWS - 2)[0]);
    try expectEqual(@as(u8, 'Z'), c.row(ROWS - 1)[0]); // newest line at the bottom
    try expectEqual(@as(u8, ROWS - 1), c.cy); // cursor pinned to the bottom row
}

test "CUP addresses the cell it names, clamped to the grid" {
    var c = Console.init();
    feedAll(&c, "\x1b[5;10HX"); // 1-based row 5, column 10
    try expectEqual(@as(u8, 'X'), c.row(4)[9]);
    feedAll(&c, "\x1b[HY"); // no parameters: home
    try expectEqual(@as(u8, 'Y'), c.row(0)[0]);
    feedAll(&c, "\x1b[99;999HZ"); // beyond the grid: pinned to the far corner
    try expectEqual(@as(u8, 'Z'), c.row(ROWS - 1)[COLS - 1]);
}

test "relative cursor moves land relative to the cursor" {
    var c = Console.init();
    feedAll(&c, "\x1b[10;10H");
    feedAll(&c, "\x1b[3AX"); // up 3 → row 7 (1-based), same column
    try expectEqual(@as(u8, 'X'), c.row(6)[9]);
    feedAll(&c, "\x1b[2BY"); // down 2, from the column X advanced to
    try expectEqual(@as(u8, 'Y'), c.row(8)[10]);
    feedAll(&c, "\x1b[5DZ"); // back 5
    try expectEqual(@as(u8, 'Z'), c.row(8)[6]);
    feedAll(&c, "\x1b[CW"); // forward, default count 1
    try expectEqual(@as(u8, 'W'), c.row(8)[8]);
    feedAll(&c, "\x1b[99A\x1b[999DQ"); // overshoot clamps at the top-left
    try expectEqual(@as(u8, 'Q'), c.row(0)[0]);
}

test "ED clears the addressed span of the display" {
    var c = Console.init();
    feedAll(&c, "aaaa\r\nbbbb\r\ncccc");
    feedAll(&c, "\x1b[2;3H\x1b[J"); // erase from row 2 column 3 to the end
    try expectEqualSlices(u8, "aaaa", c.row(0)[0..4]); // before the cursor: kept
    try expectEqualSlices(u8, "bb  ", c.row(1)[0..4]); // from the cursor on: gone
    try expectBlankRow(&c, 2);
    feedAll(&c, "\x1b[1;2H\x1b[1J"); // erase from the start through the cursor
    try expectEqualSlices(u8, "  aa", c.row(0)[0..4]);
    feedAll(&c, "\x1b[2J"); // erase everything
    for (0..ROWS) |r| try expectBlankRow(&c, r);
}

test "EL clears the addressed span of the line" {
    var c = Console.init();
    feedAll(&c, "abcdef\x1b[4G\x1b[K"); // CHA to column 4, erase rightward
    try expectEqualSlices(u8, "abc   ", c.row(0)[0..6]);
    feedAll(&c, "\x1b[2G\x1b[1K"); // erase from the start through column 2
    try expectEqualSlices(u8, "  c", c.row(0)[0..3]);
    feedAll(&c, "\x1b[2K"); // erase the whole line
    try expectBlankRow(&c, 0);
}

test "SGR colours the pen; the sequence itself never prints" {
    var c = Console.init();
    feedAll(&c, "\x1b[32mg\x1b[1;34mB\x1b[0mn");
    try expectEqualSlices(u8, "gBn", c.row(0)[0..3]); // no '[', digits, ';' or 'm' visible
    try expectEqual(@as(vmconsole.Color, 2), c.rowColors(0)[0]); // green
    try expectEqual(@as(vmconsole.Color, 12), c.rowColors(0)[1]); // bold blue reads bright
    try expectEqual(@as(vmconsole.Color, null), c.rowColors(0)[2]); // reset to default
}

test "unknown CSI and DEC private modes vanish without a trace" {
    var c = Console.init();
    // Cursor hide, alternate screen, a device status query, an unassigned
    // final, a '>'-prefixed query — the newt/ncurses warm-up chatter.
    feedAll(&c, "a\x1b[?25l\x1b[?1049h\x1b[6n\x1b[12;34z\x1b[>cb");
    try expectEqualSlices(u8, "ab", c.row(0)[0..2]);
    try expectEqual(@as(u8, 2), c.cx); // the cursor moved only for a and b
    try expectEqual(@as(u8, 0), c.cy);
}

test "OSC strings are swallowed to their terminator" {
    var c = Console.init();
    feedAll(&c, "a\x1b]0;window title\x07b\x1b]2;more\x1b\\c"); // BEL-ended, then ST-ended
    try expectEqualSlices(u8, "abc", c.row(0)[0..3]);
}

test "a two-byte escape (keypad mode) is swallowed whole" {
    var c = Console.init();
    feedAll(&c, "a\x1b=b\x1b>c"); // DECKPAM / DECKPNM
    try expectEqualSlices(u8, "abc", c.row(0)[0..3]);
}

test "ESC c resets the console to its initial state" {
    var c = Console.init();
    feedAll(&c, "\x1b[31mhello\x1b[10;10H");
    feedAll(&c, "\x1bc");
    for (0..ROWS) |r| try expectBlankRow(&c, r);
    c.feed('x');
    try expectEqual(@as(u8, 'x'), c.row(0)[0]); // cursor went home
    try expectEqual(@as(vmconsole.Color, null), c.rowColors(0)[0]); // pen back to default
}

test "charset designations are swallowed; DEC graphics draw ASCII box art" {
    var c = Console.init();
    feedAll(&c, "a\x1b(Bb"); // designate US-ASCII into G0 — nothing visible
    try expectEqualSlices(u8, "ab", c.row(0)[0..2]);
    feedAll(&c, "\r\n\x1b(0lqqk"); // the graphics set into G0: corner, lines, corner
    try expectEqualSlices(u8, "+--+", c.row(1)[0..4]);
    feedAll(&c, "\x1b(Bx"); // back to ASCII: 'x' is a letter again, not a vertical bar
    try expectEqual(@as(u8, 'x'), c.row(1)[4]);
    // The SO/SI route ncurses takes: graphics designated into G1, shift-out
    // selects it, shift-in returns to the ASCII G0.
    feedAll(&c, "\r\n\x1b)0\x0eqx\x0fq");
    try expectEqualSlices(u8, "-|q", c.row(2)[0..3]);
}

test "a line feed at the bottom margin scrolls only the region" {
    var c = Console.init();
    feedAll(&c, "above"); // row 1, outside the region to be
    feedAll(&c, "\x1b[25;1Hbelow"); // bottom row, also outside
    feedAll(&c, "\x1b[10;20r"); // DECSTBM rows 10..20, homes the cursor
    try expectEqual(@as(u8, 0), c.cy);
    try expectEqual(@as(u8, 0), c.cx);
    feedAll(&c, "\x1b[20;1Hone\r\ntwo"); // the LF lands on the bottom margin
    try expectEqualSlices(u8, "one", c.row(18)[0..3]); // scrolled up within the region
    try expectEqualSlices(u8, "two", c.row(19)[0..3]);
    try expectEqualSlices(u8, "above", c.row(0)[0..5]); // rows outside: untouched
    try expectEqualSlices(u8, "below", c.row(ROWS - 1)[0..5]);
}

test "reverse index at the top margin scrolls the region down" {
    var c = Console.init();
    feedAll(&c, "\x1b[5;10r");
    feedAll(&c, "\x1b[5;1Hfirst\x1b[5;1H\x1bM"); // RI with the cursor on the top margin
    feedAll(&c, "newer");
    try expectEqualSlices(u8, "newer", c.row(4)[0..5]);
    try expectEqualSlices(u8, "first", c.row(5)[0..5]); // pushed down a row
}

test "insert and delete of lines and characters shift within bounds" {
    var c = Console.init();
    feedAll(&c, "one\r\ntwo\r\nthree");
    feedAll(&c, "\x1b[2;1H\x1b[L"); // insert a blank line at row 2
    try expectEqualSlices(u8, "one", c.row(0)[0..3]);
    try expectBlankRow(&c, 1);
    try expectEqualSlices(u8, "two", c.row(2)[0..3]);
    try expectEqualSlices(u8, "three", c.row(3)[0..5]);
    feedAll(&c, "\x1b[M"); // and delete it again
    try expectEqualSlices(u8, "two", c.row(1)[0..3]);
    try expectEqualSlices(u8, "three", c.row(2)[0..5]);
    feedAll(&c, "\x1b[1;1H\x1b[2@"); // push "one" right two cells
    try expectEqualSlices(u8, "  one", c.row(0)[0..5]);
    feedAll(&c, "\x1b[2P"); // and pull it back
    try expectEqualSlices(u8, "one  ", c.row(0)[0..5]);
    feedAll(&c, "\x1b[2X"); // erase two cells in place: no shift
    try expectEqualSlices(u8, "  e", c.row(0)[0..3]);
}

test "save/restore cursor round-trips (ESC 7/8 and CSI s/u)" {
    var c = Console.init();
    feedAll(&c, "\x1b[3;7H\x1b7"); // save at row 3, column 7
    feedAll(&c, "\x1b[20;40Hfar");
    feedAll(&c, "\x1b8S"); // restore: S lands at the saved cell
    try expectEqual(@as(u8, 'S'), c.row(2)[6]);
    feedAll(&c, "\x1b[10;10H\x1b[s\x1b[H\x1b[uT"); // the ANSI pair
    try expectEqual(@as(u8, 'T'), c.row(9)[9]);
}

test "a newt-style screen script renders to the expected grid" {
    var c = Console.init();
    // The gestures a newt/ncurses full-screen draw makes on a serial console:
    // clear + home, box art through the DEC graphics set, absolute cursor
    // addressing for each row, an SGR-highlighted menu line.
    feedAll(&c, "\x1b[2J\x1b[H");
    feedAll(&c, "\x1b(0lqqqqqqqqk\x1b(B"); // the frame's top edge
    feedAll(&c, "\x1b[2;1H\x1b(0x\x1b(B Debian \x1b(0x\x1b(B"); // walls around the title
    feedAll(&c, "\x1b[3;3H\x1b[7mEnglish\x1b[0m"); // the highlighted menu row
    try expectEqualSlices(u8, "+--------+", c.row(0)[0..10]);
    try expectEqualSlices(u8, "| Debian |", c.row(1)[0..10]);
    try expectEqualSlices(u8, "  English ", c.row(2)[0..10]);
    try expectBlankRow(&c, 3); // nothing leaked past the script's last row
}

test "garbage and control bytes leave the grid untouched" {
    var c = Console.init();
    feedAll(&c, "a\x00\x07\x7f\x01b"); // NUL, BEL, DEL, SOH between printables
    try expectEqualSlices(u8, "ab", c.row(0)[0..2]);
    try expectEqual(@as(u8, 2), c.cx);
    try expectEqual(@as(u8, 0), c.cy);
}

test "arrow keys encode as their VT100 cursor sequences" {
    try expectEqualSlices(u8, "\x1b[A", vmconsole.keySequence(keymap.KEY_UP).?);
    try expectEqualSlices(u8, "\x1b[B", vmconsole.keySequence(keymap.KEY_DOWN).?);
    try expectEqualSlices(u8, "\x1b[C", vmconsole.keySequence(keymap.KEY_RIGHT).?);
    try expectEqualSlices(u8, "\x1b[D", vmconsole.keySequence(keymap.KEY_LEFT).?);
    try expectEqual(@as(?[]const u8, null), vmconsole.keySequence('a')); // characters go as themselves
    try expectEqual(@as(?[]const u8, null), vmconsole.keySequence('\t')); // Tab is already its own byte
}

// VIRT-036: keystrokes reach the guest in the order they were typed. The
// mailbox ring is sized for a human; a machine delivers a whole command line at
// once, and a byte lost in the middle of one arrives as a MISTYPED command
// rather than a missing one — the failure that is hardest to attribute.

test "the serial queue hands bytes to the guest in order (VIRT-036)" {
    var q = vmconsole.SerialQueue{};
    for ("firefox\n") |b| try expect(q.offer(b));

    var got: [8]u8 = undefined;
    var n: usize = 0;
    while (q.next()) |b| {
        got[n] = b;
        n += 1;
        q.advance();
    }
    try expectEqualSlices(u8, "firefox\n", got[0..n]);
    try expect(q.isEmpty());
}

test "a byte the guest refuses stays at the head and blocks the rest (VIRT-036)" {
    var q = vmconsole.SerialQueue{};
    for ("abc") |b| try expect(q.offer(b));

    // next() must NOT consume: the guest's ring can still refuse the byte, and
    // one taken out of the queue and then refused is simply gone. Peeking twice
    // has to give the same byte.
    try expectEqual(@as(?u8, 'a'), q.next());
    try expectEqual(@as(?u8, 'a'), q.next());
    q.advance();
    // And the queue is FIFO under a stall: a later byte must never overtake the
    // one still waiting, or the guest reads a scrambled line.
    try expectEqual(@as(?u8, 'b'), q.next());
    try expect(q.offer('d'));
    try expectEqual(@as(?u8, 'b'), q.next());
}

test "a full serial queue refuses rather than overwriting (VIRT-036)" {
    var q = vmconsole.SerialQueue{};
    var sent: usize = 0;
    // BOUNDED, and the bound is part of the assertion. A queue that never
    // refuses is exactly the bug this test exists to catch, and an unbounded
    // `while (q.offer(...))` would not fail against it — it would spin forever,
    // which reads as a wedged machine rather than as a failing test.
    while (sent <= vmconsole.SerialQueue.CAP and q.offer('x')) sent += 1;
    try expectEqual(vmconsole.SerialQueue.CAP, sent);

    // Dropping the NEWEST byte truncates the command; dropping the oldest to
    // make room would splice two commands together and run the result. The
    // refusal is what lets the caller count the loss instead of discovering it
    // in the guest's shell history.
    try expect(sent > 0);
    try expect(!q.offer('y'));
    try expectEqual(@as(?u8, 'x'), q.next());
}

test "the guest's scanout is shown once it holds real pixels (VIRT-016)" {
    // The whole rule, and why it is two conditions rather than one: a guest arms
    // its scanout before drawing into it, so switching on the texture alone
    // would blank a console still carrying the boot log — the one thing worth
    // reading while a guest comes up.
    try expect(!vmconsole.showsScanout(false, false)); // nothing published yet
    try expect(!vmconsole.showsScanout(true, false)); // armed, never painted
    try expect(!vmconsole.showsScanout(false, true)); // flushed, texture retracted
    try expect(vmconsole.showsScanout(true, true)); // real pixels — show them
}
