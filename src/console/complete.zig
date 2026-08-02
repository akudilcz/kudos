//! Tab-key completion for the console line editor — the PURE core. Token
//! analysis + prefix matching over an INJECTED directory enumeration
//! (`Dirs`), so no VFS IO happens here: the terminal supplies a vfs-backed
//! seam, the host tests an in-memory fake (test/console/complete_test.zig).
//!
//! One Tab press does the most it can and says what it could not do. It
//! completes the COMMAND word when the cursor is on the first word of the
//! line and a PATH otherwise; it matches without regard to case when nothing
//! matches exactly, so a lower-case guess still finds a FAT volume's
//! `Box.glb`; and when several entries match it grows the line to the text
//! they share and reports how many matched, so the host can show them
//! (`eachMatch`) instead of appearing to ignore the key.

const std = @import("std");
const vfs = @import("vfs");
pub const ifilesys = @import("ifilesys");

/// The fixed mounts a BARE argument (no '/') falls back to when the cwd has
/// no match, in search order — the same grab-a-model convenience `show`
/// applies when resolving its PATH (cmd/show.zig imports this order).
pub const BARE_ROOTS = [_][]const u8{ "/ramdisk", "/usbdisk" };

/// Commands whose argument can only ever be a directory, so completion offers
/// only directories for them. This is a completion POLICY — what each word
/// does is still shell.zig's table, and the argument each accepts is still
/// its own cmd/ implementation.
const DIR_ONLY_CMDS = [_][]const u8{"cd"};

/// The directory-entry enumeration seam: `listFn` has vfs.list's shape plus
/// a context, so the terminal binds the live VFS and a host test binds an
/// in-memory tree. Enumeration is the one effect completion needs, and it is
/// real IO (USB FAT), which is why it is injected rather than imported.
pub const Dirs = struct {
    ctx: ?*anyopaque,
    listFn: *const fn (ctx: ?*anyopaque, abs: []const u8, cb: ifilesys.ListFn, cb_ctx: ?*anyopaque) ifilesys.Error!void,

    fn list(self: Dirs, abs: []const u8, cb: ifilesys.ListFn, cb_ctx: ?*anyopaque) ifilesys.Error!void {
        return self.listFn(self.ctx, abs, cb, cb_ctx);
    }
};

/// Where every candidate goes when the host asks to SHOW them (`eachMatch`):
/// one call per matching entry, in enumeration order.
pub const Each = struct {
    ctx: ?*anyopaque,
    entryFn: *const fn (ctx: ?*anyopaque, name: []const u8, kind: ifilesys.Kind) void,

    fn emit(self: Each, name: []const u8, kind: ifilesys.Kind) void {
        self.entryFn(self.ctx, name, kind);
    }
};

/// What one Tab press did to the line.
pub const Result = struct {
    /// The line's new length.
    len: usize,
    /// Characters the host must ERASE from the screen before echoing the new
    /// tail: a case-corrected completion (`box`⇥ → `Box.glb`) REWRITES what
    /// was typed rather than appending to it. The bytes to echo are then
    /// `buf[len_before - erased .. len]`, which for the ordinary append is
    /// exactly the appended bytes.
    erased: usize = 0,
    /// How many entries matched: 0 none, 1 unique, more than one ambiguous.
    /// A host that grew the line by nothing and sees more than one match
    /// LISTS them — otherwise the key looks broken.
    matches: usize = 0,
};

/// Accumulates matches during one enumeration. `name` holds the first match in
/// full and is shrunk to the longest common prefix as more matches arrive, so
/// after the scan `name[0..name_len]` IS the text the token can grow to
/// regardless of how many entries matched.
const Matches = struct {
    prefix: []const u8 = "",
    /// Compare without regard to case — the retry pass, entered only when
    /// exact matching found nothing.
    fold_case: bool = false,
    /// Offer directories only (the DIR_ONLY_CMDS policy).
    dirs_only: bool = false,
    /// Set when the host is SHOWING candidates rather than growing the line.
    each: ?Each = null,
    count: usize = 0,
    name: [vfs.MAX_PATH]u8 = undefined,
    name_len: usize = 0,
    /// Kind of the sole match — only meaningful when `count == 1`, where it
    /// decides the trailing '/'.
    kind: ifilesys.Kind = .file,
};

fn sameByte(a: u8, b: u8, fold_case: bool) bool {
    return if (fold_case) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

fn hasPrefix(name: []const u8, prefix: []const u8, fold_case: bool) bool {
    if (name.len < prefix.len) return false;
    for (prefix, name[0..prefix.len]) |p, n| if (!sameByte(p, n, fold_case)) return false;
    return true;
}

/// Fold one candidate — a directory entry or a command name — into the
/// accumulator.
fn onEntry(ctx: ?*anyopaque, e: ifilesys.Entry) void {
    const m: *Matches = @ptrCast(@alignCast(ctx.?));
    if (m.dirs_only and e.kind != .dir) return;
    if (!hasPrefix(e.name, m.prefix, m.fold_case)) return;
    // A name longer than MAX_PATH could never resolve as a path; keeping it
    // out of the fold keeps `name` a fixed buffer.
    if (e.name.len > m.name.len) return;
    m.count += 1;
    if (m.each) |sink| sink.emit(e.name, e.kind);
    if (m.count == 1) {
        @memcpy(m.name[0..e.name.len], e.name);
        m.name_len = e.name.len;
        m.kind = e.kind;
        return;
    }
    // The shared text, compared the way the match was: under case folding the
    // FIRST match's spelling is kept, and the line is rewritten to it.
    const lim = @min(m.name_len, e.name.len);
    var i: usize = 0;
    while (i < lim and sameByte(m.name[i], e.name[i], m.fold_case)) i += 1;
    m.name_len = i;
}

/// The word Tab acts on: the last whitespace-separated token, where it starts,
/// and whether it is the FIRST word of the line — the command name. A leading
/// run of spaces does not turn the first word into an argument.
const Token = struct {
    start: usize,
    text: []const u8,
    first: bool,
};

fn tokenOf(s: []const u8) Token {
    const start = if (std.mem.lastIndexOfAny(u8, s, " \t")) |i| i + 1 else 0;
    return .{
        .start = start,
        .text = s[start..],
        .first = std.mem.trim(u8, s[0..start], " \t").len == 0,
    };
}

/// The line's command word — what the argument being completed belongs to.
fn commandWord(s: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, s, " \t");
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return t[0..end];
}

/// Enumerate the directory the token names — its own directory part when it
/// has one, else the cwd and then the fixed mounts — folding every entry into
/// `m`. An unlistable directory counts as empty-handed, not as a failure.
fn scanPath(m: *Matches, token: []const u8, cwd: []const u8, dirs: Dirs) void {
    if (std.mem.lastIndexOfScalar(u8, token, '/')) |slash| {
        // The token names a directory to complete inside: resolve that
        // directory against the cwd and match on the rest.
        const dir_arg = if (slash == 0) "/" else token[0..slash];
        m.prefix = token[slash + 1 ..];
        var dir_buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = vfs.normalize(cwd, dir_arg, &dir_buf) orelse return;
        dirs.list(abs, onEntry, m) catch return;
        return;
    }
    m.prefix = token;
    dirs.list(cwd, onEntry, m) catch {};
    if (m.count == 0) for (BARE_ROOTS) |root| {
        dirs.list(root, onEntry, m) catch continue;
        if (m.count != 0) break;
    };
}

/// Fold the command names — the first word's candidates. Commands have no
/// kind; `.file` keeps them out of the directory-only path.
fn scanCommands(m: *Matches, token: []const u8, cmds: []const []const u8) void {
    m.prefix = token;
    for (cmds) |name| onEntry(m, .{ .name = name, .kind = .file, .size = 0 });
}

/// One gathering pass, then a case-folded RETRY when the exact pass found
/// nothing: a lower-case guess still finds `Box.glb` on a FAT volume, and a
/// volume that spells its names exactly as typed never pays for the retry.
fn gather(m: *Matches, t: Token, s: []const u8, cwd: []const u8, dirs: Dirs, cmds: []const []const u8) void {
    for ([_]bool{ false, true }) |fold_case| {
        m.* = .{
            .fold_case = fold_case,
            .dirs_only = !t.first and isDirOnly(commandWord(s)),
            .each = m.each,
        };
        if (t.first) scanCommands(m, t.text, cmds) else scanPath(m, t.text, cwd, dirs);
        if (m.count != 0) return;
    }
}

fn isDirOnly(cmd: []const u8) bool {
    for (DIR_ONLY_CMDS) |d| if (std.mem.eql(u8, cmd, d)) return true;
    return false;
}

/// Complete the last token of `buf[0..len]` in place (the cursor is at the end
/// of the line). The first word completes against `cmds` — the command names
/// the shell knows — and gains a trailing space when it completes to exactly
/// one; any later word completes against the file system, a unique directory
/// gaining a trailing '/'. Several matches grow the token to the text they all
/// share. Nothing matching leaves the line untouched. The caller redraws by
/// erasing `Result.erased` characters and echoing `buf[len - erased .. new]`.
pub fn line(buf: []u8, len: usize, cwd: []const u8, dirs: Dirs, cmds: []const []const u8) Result {
    const t = tokenOf(buf[0..len]);
    var m = Matches{};
    gather(&m, t, buf[0..len], cwd, dirs, cmds);
    if (m.count == 0) return .{ .len = len };

    // Where the matched text starts on the line: the token itself, or the
    // segment after its last '/'.
    const keep = len - m.prefix.len;
    const suffix: ?u8 = if (m.count != 1) null else if (t.first) ' ' else if (m.kind == .dir) @as(u8, '/') else null;
    const grown = keep + m.name_len + @intFromBool(suffix != null);
    // A completion that cannot fit changes nothing — but the match count still
    // stands, so the host can show what it found.
    if (grown > buf.len) return .{ .len = len, .matches = m.count };
    @memcpy(buf[keep..][0..m.name_len], m.name[0..m.name_len]);
    if (suffix) |c| buf[keep + m.name_len] = c;
    return .{
        .len = grown,
        // Case folding rewrites what was typed; exact matching only appends.
        .erased = if (m.fold_case) m.prefix.len else 0,
        .matches = m.count,
    };
}

/// Hand every candidate for the same token to `each` — what a host shows when
/// a Tab press could not finish the word. The scan is the one `line` did, so
/// the list is exactly the set that produced its match count.
pub fn eachMatch(text: []const u8, cwd: []const u8, dirs: Dirs, cmds: []const []const u8, each: Each) void {
    var m = Matches{ .each = each };
    gather(&m, tokenOf(text), text, cwd, dirs, cmds);
}
