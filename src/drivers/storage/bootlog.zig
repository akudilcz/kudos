//! Boot-log recorder → /usbdisk/bootlog.txt.
//!
//! A klog byte sink (registered once via `klog.addSink`) that mirrors the
//! whole kernel trace stream to a fixed-size file on the USB stick, so everything
//! already flushed survives a guest crash AND a host power-cycle — the black-box
//! recorder the netdebug UDP stream cannot be (it needs a live listener). The
//! in-flight sector at the moment of a power cut is what can still be lost.
//!
//! APPEND / RING across boots: the file is a fixed-size ring. A small header in
//! its first sector carries the write cursor and a monotonic wrap sequence, so
//! successive boots append after the previous boot's tail and wrap at the end;
//! a host de-ring tool (`scripts/debug/bootlog.py read <mount>`) reads the entries in
//! chronological order. The header is rewritten (one sector) on each flush so a
//! crash loses at most the un-flushed tail, never the ring structure.
//!
//! FLUSH POLICY — RAM-heavy, write-rare (we have plenty of RAM; a USB BOT write
//! + SYNCHRONIZE CACHE is ~ms and the system loop is cooperative, so writing
//! per line lags the whole boot). Bytes go into a LARGE in-RAM ring (BUF_BYTES).
//!   - `feed` (called from klog.putc, possibly IRQ/reentrant) does ONLY a
//!     memcpy into RAM — it NEVER touches the USB device. So logging is free at
//!     the trace site; there is no blocking BOT transaction on the hot path.
//!   - `service()` (called from the steady session loop, THROTTLED) drains only
//!     WHOLE sectors that have accumulated, in ONE multi-sector WRITE(10) per
//!     call (up to the transfer cap), leaving a partial trailing sector in RAM.
//!     No SYNCHRONIZE CACHE here — steady-state writes ride the device cache.
//!   - `flushNow` (panic path) drains everything AND issues the cache flush, so
//!     durability is paid exactly when it matters (a crash), not per line.
//! The file's data clusters are rewritten IN PLACE (fat.Volume.LogFile): no
//! cluster allocation, no dir-entry update — the crash-fragile FAT-write parts
//! never run.

const std = @import("std");
const fat = @import("fat.zig");
const klog = @import("../../kernel/debug/klog.zig");

/// The ring file kudos writes. Host-seeded at a fixed size (make-bootlog on the
/// stick); kudos never creates or grows it — a missing file disables the sink
/// loudly rather than attempting metadata writes.
pub const PATH = "/bootlog.txt"; // volume-relative (the /usbdisk mount root)

/// Header (first HEADER_BYTES of the file), ASCII so the raw file stays
/// human-readable: `KUDOSLOG v1 seq=<u32> cursor=<u64>\n` padded to the sector.
/// The body ring starts at HEADER_BYTES.
const HEADER_BYTES: u64 = 512;
const MAGIC = "KUDOSLOG";

/// The in-RAM staging ring: a whole boot's worth of trace with headroom, so
/// `feed` is always a cheap memcpy and the device is written only in bulk. 1 MiB
/// of static BSS is nothing against 64 GiB; a chatty GPU boot fits with room to
/// spare between service() drains.
const SECTOR: usize = 512;
const BUF_BYTES: usize = 1 << 20; // 1 MiB
var buf: [BUF_BYTES]u8 = undefined;
var head: usize = 0; // producer offset (feed writes here)
var tail: usize = 0; // consumer offset (service has written up to here to disk)
var dropped: u64 = 0; // bytes lost to overrun (buffer full before a drain)

/// Whole sectors are drained per service() call; cap the burst so one drain is a
/// single BOT WRITE(10) and does not monopolise the session loop. 64 sectors =
/// 32 KiB = msc.MAX_XFER_SECTORS.
const DRAIN_SECTORS_MAX: usize = 64;
/// 64 KiB-ALIGNED ON PURPOSE. This buffer is handed straight to a bulk TRB, and
/// xHCI forbids a TRB's data buffer from crossing a 64 KiB boundary. Unaligned, a
/// 32 KiB array crosses one whenever the linker happens to place it above the
/// midpoint of a 64 K page — a coin flip that silently re-rolled on every build,
/// corrupting boot-log writes on real silicon while QEMU (which does not enforce
/// the rule) stayed green. xhci.pushBulkTd now splits a straddling buffer anyway;
/// this alignment means the split never has to happen on the hot path.
var scratch: [DRAIN_SECTORS_MAX * SECTOR]u8 align(64 * 1024) = undefined;

var log: ?fat.Volume.LogFile = null;
var body_size: u64 = 0; // ring capacity = file size - HEADER_BYTES
var cursor: u64 = 0; // next write offset within the body ring [0, body_size)
var seq: u32 = 0; // wrap counter (bumped each time cursor wraps to 0)
var installed = false;

/// The ring file's size when kudos creates it itself (absent on a fresh stick):
/// 8 MiB holds several chatty GPU boots between wraps.
const CREATE_BYTES: u64 = 8 * 1024 * 1024;

/// Bring the recorder up: open the bootlog file on the mounted volume — or
/// CREATE it (fat create/append, one-time ~1 s on a fresh stick) — then
/// read+advance the ring header (so this boot appends after the last), queue a
/// boot banner, and register the klog sink. Returns false (loudly, via the
/// caller's log) on any failure — the sink is simply not installed;
/// the trace are unaffected.
pub fn init(vol: *fat.Volume, build_number: u32) bool {
    const lf = vol.openLog(PATH) catch |e| blk: {
        if (e != fat.Error.FatNotFound) return false;
        // First boot with this stick: create the fixed-size ring file once.
        // Newline fill = clean text padding (rodata, not 32 KiB of stack).
        const fill: [32 * 1024]u8 = comptime [_]u8{'\n'} ** (32 * 1024);
        var f = vol.create(PATH) catch return false;
        var left: u64 = CREATE_BYTES;
        while (left > 0) {
            const n: usize = @intCast(@min(left, fill.len));
            f.append(fill[0..n]) catch return false;
            left -= n;
        }
        break :blk vol.openLog(PATH) catch return false;
    };
    if (lf.size <= HEADER_BYTES + 64) return false; // too small to be a ring
    log = lf;
    body_size = lf.size - HEADER_BYTES;

    // Read the existing header; continue its ring if valid, else start fresh.
    var hdr: [HEADER_BYTES]u8 = undefined;
    if (log.?.readAt(0, &hdr)) |_| {
        parseHeader(&hdr);
    } else |_| {
        cursor = 0;
        seq = 0;
    }

    // Boot banner into the RAM buffer so a reader can delimit boots (drained to
    // disk by the first service() call — no device write during init).
    var banner: [96]u8 = undefined;
    const b = std.fmt.bufPrint(&banner, "\n===== kudos boot #{d} (log seq {d}) =====\n", .{ build_number, seq }) catch "\n===== kudos boot =====\n";
    push(b);

    installed = true;
    klog.addSink(&feed); // THE single registration — the one place a sink is added
    return true;
}

/// Parse `KUDOSLOG v1 seq=<n> cursor=<n>` from the header; reset on mismatch.
fn parseHeader(hdr: []const u8) void {
    if (!std.mem.startsWith(u8, hdr, MAGIC)) {
        cursor = 0;
        seq = 0;
        return;
    }
    seq = fieldU32(hdr, "seq=") orelse 0;
    cursor = fieldU64(hdr, "cursor=") orelse 0;
    if (cursor >= body_size) cursor = 0; // corrupt cursor → restart the ring
}

fn fieldU32(s: []const u8, key: []const u8) ?u32 {
    const v = fieldU64(s, key) orelse return null;
    return @truncate(v);
}
fn fieldU64(s: []const u8, key: []const u8) ?u64 {
    const i = std.mem.indexOf(u8, s, key) orelse return null;
    var j = i + key.len;
    var v: u64 = 0;
    var any = false;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
        v = v * 10 + (s[j] - '0');
        any = true;
    }
    return if (any) v else null;
}

/// klog.addSink callback: a SPAN of the trace stream (a whole puts string
/// arrives as one call). The hot path — possibly reentrant/IRQ — so it does
/// NOTHING but a RAM memcpy. No device I/O ever happens here.
fn feed(bytes: []const u8) void {
    if (!installed) return;
    push(bytes);
}

/// Enqueue a byte SLICE into the RAM ring: wrap-aware memcpy (at most two
/// spans), not a per-byte loop. On overrun (the buffer filled before a
/// service() drain) the excess is dropped and counted — losing the OLDEST
/// unflushed tail would corrupt ordering; dropping the newest keeps what is
/// already committed intact, and `dropped` is reported so loss is never silent.
fn push(bytes: []const u8) void {
    const t = tail % BUF_BYTES;
    // Free space, leaving one slot so head==tail stays unambiguous (empty).
    const free = (t + BUF_BYTES - head - 1) % BUF_BYTES;
    const n = @min(bytes.len, free);
    dropped += bytes.len - n;
    const first = @min(n, BUF_BYTES - head);
    @memcpy(buf[head..][0..first], bytes[0..first]);
    @memcpy(buf[0 .. n - first], bytes[first..n]);
    head = (head + n) % BUF_BYTES;
}

/// Bytes queued in RAM but not yet written to the stick.
fn pending() usize {
    return (head + BUF_BYTES - (tail % BUF_BYTES)) % BUF_BYTES;
}

/// Drain WHOLE sectors of queued bytes to the stick — called from the steady
/// session loop, throttled by the caller. One bulk multi-sector WRITE(10) per
/// call (≤ DRAIN_SECTORS_MAX), leaving any partial trailing sector in RAM for a
/// later drain (or flushNow). NO SYNCHRONIZE CACHE here — steady writes ride the
/// device cache; durability is a flushNow (panic) concern. Cheap when there is
/// less than a sector pending (the common idle case): returns immediately.
pub fn service() void {
    if (!installed) return;
    const whole = pending() / SECTOR;
    if (whole == 0) return;
    const secs = @min(whole, DRAIN_SECTORS_MAX);
    const n = secs * SECTOR;
    // Copy the (possibly wrapped) ring span into the linear scratch buffer.
    const t = tail % BUF_BYTES;
    if (t + n <= BUF_BYTES) {
        @memcpy(scratch[0..n], buf[t..][0..n]);
    } else {
        const first = BUF_BYTES - t;
        @memcpy(scratch[0..first], buf[t..][0..first]);
        @memcpy(scratch[first..n], buf[0..(n - first)]);
    }
    writeBody(scratch[0..n]) catch return disable();
    tail += n;
}

/// Write `bytes` (a whole number of sectors) into the file's body ring at the
/// current `cursor`, wrapping at body_size and bumping `seq`. Splits at the ring
/// wrap only; each piece is a single multi-sector IBlockDev.write. Does NOT sync
/// (see service) unless `sync` is set (flushNow).
fn writeBody(bytes: []const u8) fat.Error!void {
    var rest = bytes;
    while (rest.len > 0) {
        // cursor is kept sector-aligned by construction (only whole sectors
        // written), so the LogFile write stays sector-aligned too.
        const room: usize = @intCast(body_size - cursor);
        const n = @min(room - (room % SECTOR), rest.len);
        const chunk = if (n == 0) rest.len else n; // room < SECTOR shouldn't happen (body is sector-multiple)
        try log.?.writeAt(HEADER_BYTES + cursor, rest[0..chunk]);
        cursor += chunk;
        rest = rest[chunk..];
        if (cursor >= body_size) {
            cursor = 0;
            seq +%= 1;
        }
    }
    try writeHeader();
}

fn writeHeader() fat.Error!void {
    var hdr: [HEADER_BYTES]u8 = undefined;
    @memset(&hdr, ' ');
    _ = std.fmt.bufPrint(&hdr, "{s} v1 seq={d} cursor={d}", .{ MAGIC, seq, cursor }) catch return;
    hdr[HEADER_BYTES - 1] = '\n'; // the raw file's first line is the header
    try log.?.writeAt(0, &hdr);
}

fn disable() void {
    installed = false;
    klog.puts("bootlog: write failed — /usbdisk/bootlog.txt sink disabled\n");
}

/// Panic/reset path: drain EVERYTHING still in RAM (including the partial
/// trailing sector, zero-padded) and issue SYNCHRONIZE CACHE so the crash's
/// last lines are durable on the stick. Best-effort; called from the panic
/// handler after the netdebug flush.
pub fn flushNow() void {
    if (!installed) return;
    // Drain all whole sectors first.
    while (pending() >= SECTOR) service();
    // Then the partial tail (wrap-aware two-span copy), padded to a sector.
    const rem = pending();
    if (rem > 0) {
        const t = tail % BUF_BYTES;
        const first = @min(rem, BUF_BYTES - t);
        @memcpy(scratch[0..first], buf[t..][0..first]);
        @memcpy(scratch[first..rem], buf[0 .. rem - first]);
        @memset(scratch[rem..SECTOR], '\n'); // pad the sector so the file stays clean text
        writeBody(scratch[0..SECTOR]) catch return disable();
        tail += rem;
    }
    // Durability barrier: ONE SYNCHRONIZE CACHE commits every write above to the
    // non-volatile medium — paid exactly here (panic), never per line.
    (log.?.sync()) catch return disable();
}
