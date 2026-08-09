//! Host tests of src/apps/terminal.zig — the resize/grid re-layout contract
//! ("a resize is a VIEW change, not a content edit"). The grid is fixed at
//! MAX_COLS×MAX_ROWS; a resize only moves the visible cols/rows window over it,
//! so no resize ever copies, clips, or drops cells. The module comes in through
//! the testroot shim (src/test_root.zig) so terminal.zig's cross-group relative
//! imports resolve.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const troot = @import("testroot").terminal;
const terminal = troot.terminal;
const window = troot.window;
const font = troot.font;

const Terminal = terminal.Terminal;
const Window = window.Window;

/// A window + terminal pair on the testing allocator. Frees everything on deinit.
const Fixture = struct {
    a: std.mem.Allocator,
    win: *Window,
    term: *Terminal,

    fn init(w: usize, h: usize) !Fixture {
        const a = std.testing.allocator;
        const win = try window.create(a, 1, 0, 0, w, h, "t");
        errdefer a.destroy(win);
        const term = try Terminal.create(a, win, undefined, 0, null, false);
        return .{ .a = a, .win = win, .term = term };
    }

    fn deinit(self: *Fixture) void {
        self.term.destroy(self.a);
        self.a.destroy(self.win);
    }
};

test "the AI agent window prompts `ai>`; a shell terminal prompts `#<core>` (AGT-002)" {
    const a = std.testing.allocator;
    const win = try window.create(a, 1, 0, 0, 400, 300, "t");
    defer a.destroy(win);

    // Each writes a greeting and then its prompt. The distinguishing cell is the
    // first prompt character: `a` of `ai> ` for the agent, `#` of
    // `#<core>:<cwd>> ` for a shell.
    //
    // The prompt row is taken from the CURSOR, not assumed to be row 1: the
    // greetings are different lengths and are free to change, and pinning the
    // row made this test fail for a banner edit that broke nothing it claims to
    // check.
    const shell_term = try Terminal.create(a, win, undefined, 0, null, false);
    try expect(!shell_term.ai_mode);
    try expectEqual(@as(u8, '#'), shell_term.cells[shell_term.cy * terminal.MAX_COLS].ch);
    shell_term.destroy(a);

    const ai_term = try Terminal.create(a, win, undefined, 0, null, true);
    defer ai_term.destroy(a);
    try expect(ai_term.ai_mode);
    const row = ai_term.cy * terminal.MAX_COLS;
    try expectEqual(@as(u8, 'a'), ai_term.cells[row + 0].ch);
    try expectEqual(@as(u8, 'i'), ai_term.cells[row + 1].ch);
    try expectEqual(@as(u8, '>'), ai_term.cells[row + 2].ch);
}

test "visible cols/rows always follow the window's content area" {
    var f = try Fixture.init(400, 300);
    defer f.deinit();
    try expectEqual(f.win.contentW() / font.WIDTH, f.term.cols);
    try expectEqual(f.win.contentH() / font.HEIGHT, f.term.rows);

    // Grow by whole cells: the visible window over the grid follows exactly.
    f.win.resize(f.win.w + 8 * font.WIDTH, f.win.h + 4 * font.HEIGHT);
    try expect(f.term.onResize());
    try expectEqual(f.win.contentW() / font.WIDTH, f.term.cols);
    try expectEqual(f.win.contentH() / font.HEIGHT, f.term.rows);
}

test "sub-cell resize: outer size changes, cell counts do not" {
    var f = try Fixture.init(400, 300);
    defer f.deinit();
    const cols = f.term.cols;
    const rows = f.term.rows;

    // A final drag step too small to add a column: find a width delta
    // (1..font.WIDTH-1) that keeps contentW/font.WIDTH constant.
    var d: usize = 1;
    while (d < font.WIDTH) : (d += 1) {
        if ((f.win.contentW() + d) / font.WIDTH == cols) break;
    }
    try expect(d < font.WIDTH);
    f.win.resize(f.win.w + d, f.win.h);
    try expect(f.term.onResize());
    try expectEqual(cols, f.term.cols);
    try expectEqual(rows, f.term.rows);
}

test "shrink to a sliver then grow back: the grid never loses content" {
    var f = try Fixture.init(400, 300);
    defer f.deinit();
    // Fill content, remember the pre-shrink state (the lspci-then-shrink repro).
    var i: usize = 0;
    while (i < 12) : (i += 1) f.term.write("line\n");
    f.term.write("last");
    const cx = f.term.cx;
    const cy = f.term.cy;
    try expectEqual(@as(u8, 'k'), f.term.cells[0].ch); // 'k' of the greeting

    // Shrink so far that almost nothing is visible: the GRID is untouched —
    // cursor and cells keep their positions and content.
    f.win.resize(window.MIN_W, window.MIN_H);
    try expect(f.term.onResize());
    try expectEqual(cx, f.term.cx);
    try expectEqual(cy, f.term.cy);
    try expectEqual(@as(u8, 'l'), f.term.cells[cy * terminal.MAX_COLS].ch);

    // Growing back reveals it all again — same cells, nothing re-written.
    f.win.resize(400, 300);
    try expect(f.term.onResize());
    try expectEqual(@as(u8, 'k'), f.term.cells[0].ch); // greeting still row 0
    try expectEqual(@as(u8, 'l'), f.term.cells[cy * terminal.MAX_COLS].ch);
    try expectEqual(cx, f.term.cx);
    try expectEqual(cy, f.term.cy);
}

test "content taller than the window: the visible rows can't cover the cursor row without bottom-anchoring" {
    var f = try Fixture.init(400, 300);
    defer f.deinit();
    var i: usize = 0;
    while (i < 12) : (i += 1) f.term.write("line\n");
    f.term.write("last");
    const cy = f.term.cy;

    // Shrink the height so only a few rows are visible.
    f.win.resize(f.win.w, window.MIN_H + 4 * font.HEIGHT);
    try expect(f.term.onResize());
    try expect(f.term.rows < cy + 1); // content really is taller than the view
    try expectEqual(cy, f.term.cy); // grid coordinates never move on resize
    // The freshest text is on the cursor row — the row drawGl's bottom-anchored
    // view keeps on screen.
    try expectEqual(@as(u8, 'l'), f.term.cells[cy * terminal.MAX_COLS].ch);
}
