//! Screenshot → /usbdisk/shots/SHOTnnnn.PNG (general FAT write).
//!
//! Writes each desktop capture to the PHYSICAL stick with a unique filename, so
//! a test harness reads the images AFTER QEMU exits by mounting the stick — no
//! slow KMR1/netdebug pull of a multi-MB image over 1200-byte UDP chunks. The
//! ramdisk copy (screenshot.zig) is unaffected; this is an additional sink.
//!
//! init() creates /shots on the stick if absent (fat.Volume.mkdir); save()
//! numbers files by trying SHOT0001.PNG upward until create() stops answering
//! FatExists, so every capture across every boot gets a fresh name with no
//! wall clock and no index file. A write failure disables the sink loudly — a
//! screenshot must never wedge the session loop.

const std = @import("std");
const fat = @import("../storage/fat.zig");
const log = @import("base/log.zig").gpu;
const shim = @import("base/shim.zig");

/// One pumped write slice of the image (see save()): big enough that the FAT/MSC
/// path stays efficient (many sectors per WRITE(10) burst), small enough that
/// the gaps between pumps stay well under a KMR1 client timeout.
const PUMP_CHUNK: usize = 512 * 1024;

const DIR = "shots";
const MAX_SHOTS = 9999;

var vol: ?*fat.Volume = null;
var next: u32 = 1; // first candidate number for the next save

/// Register the mounted volume and ensure /shots exists. Called once after the
/// FAT mount. Loud + disabled on failure; the ramdisk path is unaffected.
pub fn init(v: *fat.Volume) bool {
    switch (v.fileSys().kind(DIR) orelse .file) {
        .dir => {},
        .file => {
            // Absent (or a same-named file, which mkdir will refuse loudly).
            v.mkdir(DIR) catch |e| {
                log("gpu.usbshot: mkdir /usbdisk/shots failed: {s} — stick shots disabled\n", .{@errorName(e)});
                return false;
            };
        },
    }
    vol = v;
    return true;
}

pub fn active() bool {
    return vol != null;
}

/// Write one capture (the encoded PNG bytes) to the next free SHOTnnnn.PNG.
/// Returns the number used, or null if disabled/failed (loud).
pub fn save(bytes: []const u8) ?u32 {
    const v = vol orelse return null;
    var name: [32]u8 = undefined;
    while (next <= MAX_SHOTS) : (next += 1) {
        const p = std.fmt.bufPrint(&name, "{s}/SHOT{d:0>4}.PNG", .{ DIR, next }) catch return null;
        var f = v.create(p) catch |e| switch (e) {
            fat.Error.FatExists => continue, // taken (an earlier boot) — next number
            else => {
                log("gpu.usbshot: create {s} failed: {s} — stick shots disabled\n", .{ p, @errorName(e) });
                vol = null;
                return null;
            },
        };
        // Chunked, with the host channels pumped between chunks. A multi-MB image is
        // hundreds of MSC WRITE(10)s — several SECONDS during which one monolithic
        // append leaves the session loop mute and deaf: boot-2 phase 6 timed out
        // exactly here ("no reply after 8 attempts"), the same
        // long-work-starves-the-network disease as USB enumeration. Pumping per
        // chunk keeps KMR1 (LIST polls, OP_REBOOT) answerable throughout; the
        // ramdisk copy is complete before save() is called, so a concurrent READ
        // of screenshot.png serves consistent bytes.
        var off: usize = 0;
        while (off < bytes.len) {
            const end = @min(off + PUMP_CHUNK, bytes.len);
            f.append(bytes[off..end]) catch |e| {
                log("gpu.usbshot: append {s} failed: {s} — stick shots disabled\n", .{ p, @errorName(e) });
                vol = null;
                return null;
            };
            off = end;
            shim.netKeepalive();
        }
        log("gpu.usbshot: {s} saved ({} bytes) on the stick\n", .{ p, bytes.len });
        const used = next;
        next += 1;
        return used;
    }
    log("gpu.usbshot: SHOT numbers exhausted ({d}) — stick shots disabled\n", .{MAX_SHOTS});
    vol = null;
    return null;
}
