//! The calculator home screen's visible ledger: the last ROWS evaluated lines
//! ("expr = result" text), newest last. When the ledger is full the oldest row
//! scrolls away — the screen shows a moving window over the session, never a
//! frozen prefix of it. Pure value logic; the calculator app owns the pixels.

pub const ROWS: usize = 8;
pub const CAP: usize = 96;

pub const History = struct {
    rows: [ROWS][CAP]u8 = undefined,
    lens: [ROWS]usize = [_]usize{0} ** ROWS,
    count: usize = 0, // rows in use, newest last

    /// Append one rendered line, scrolling the oldest row away when full and
    /// truncating over-long text to the row width rather than overrunning it.
    pub fn push(self: *History, text: []const u8) void {
        if (self.count == ROWS) {
            var i: usize = 1;
            while (i < ROWS) : (i += 1) {
                self.rows[i - 1] = self.rows[i];
                self.lens[i - 1] = self.lens[i];
            }
            self.count -= 1;
        }
        const n = @min(text.len, CAP);
        @memcpy(self.rows[self.count][0..n], text[0..n]);
        self.lens[self.count] = n;
        self.count += 1;
    }

    /// Row `i`'s text, oldest first.
    pub fn row(self: *const History, i: usize) []const u8 {
        return self.rows[i][0..self.lens[i]];
    }
};
