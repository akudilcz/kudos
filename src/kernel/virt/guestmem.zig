//! Guest RAM and its EPT map. IO edge: grabs a contiguous physical region from the
//! frame allocator once at VM creation (never on a hot path), builds the EPT
//! second-level tables over it with the pure ept.zig builder, and hands out
//! directly-writable slices of guest memory.
//!
//! Because the kudos host address space is an identity map (host-physical ==
//! kernel-virtual), a guest-physical address `g` lives at host/kernel address
//! `ram_hpa + g`, so `slice(g, n)` is ordinary writable memory — this is what lets
//! the pure loader and device models fill guest RAM by slicing.

const pmm = @import("../memory/pmm.zig");
const ept = @import("ept.zig");
const vmxasm = @import("vmxasm.zig");
const vmxcaps = @import("vmxcaps.zig");

const FRAME_SIZE: u64 = pmm.FRAME_SIZE; // the frame allocator owns the frame size
const PAGE_2M: u64 = 2 * 1024 * 1024;

pub const GuestMem = struct {
    ram_hpa: u64, // 2 MiB-aligned guest-RAM base (== EPT hpa_base)
    ram_len: u64,
    ram_raw_hpa: u64, // the underlying allocation (may be below ram_hpa for alignment)
    ram_raw_frames: usize,
    ept_pool_hpa: u64,
    ept_pool_frames: usize,
    eptp: u64,

    /// A directly-writable view of `len` bytes of guest RAM starting at guest-phys
    /// `gpa`. Asserts the range is within guest RAM.
    pub fn slice(self: *const GuestMem, gpa: u64, len: usize) []u8 {
        if (gpa + len > self.ram_len) @panic("guestmem: slice out of guest RAM");
        return @as([*]u8, @ptrFromInt(self.ram_hpa + gpa))[0..len];
    }

    /// The whole guest RAM as one slice — the loader and device models base their
    /// GPA-indexed access on this.
    pub fn ram(self: *const GuestMem) []u8 {
        return @as([*]u8, @ptrFromInt(self.ram_hpa))[0..@intCast(self.ram_len)];
    }

    /// Release guest RAM and the EPT tables back to the frame allocator.
    pub fn deinit(self: *GuestMem) void {
        pmm.freeContiguous(self.ram_raw_hpa, self.ram_raw_frames);
        pmm.freeContiguous(self.ept_pool_hpa, self.ept_pool_frames);
        self.* = undefined;
    }
};

pub const CreateError = error{ NoGuestRam, NoEptTables, EptBuildFailed };

/// Allocate `ram_bytes` (rounded up to a 2 MiB multiple) of guest RAM plus its EPT
/// tables, build the identity-offset EPT map, and return the guest-memory handle.
/// Grab this early — the contiguous allocation scans the whole frame bitmap.
pub fn create(ram_bytes: u64, caps: vmxcaps.EptCaps) CreateError!GuestMem {
    const len = alignUp(ram_bytes, PAGE_2M);

    // Over-allocate by one 2 MiB page so the base can be rounded up to a 2 MiB
    // boundary — EPT large pages require 2 MiB-aligned host frames.
    const raw_frames: usize = @intCast((len + PAGE_2M) / FRAME_SIZE);
    const raw = pmm.allocContiguous(raw_frames) orelse return error.NoGuestRam;
    const ram_hpa = alignUp(raw, PAGE_2M);

    // EPT tables.
    const table_count = ept.tablePagesNeeded(len);
    const ept_frames = table_count; // one 4 KiB frame per table
    const pool_hpa = pmm.allocContiguous(ept_frames) orelse {
        pmm.freeContiguous(raw, raw_frames);
        return error.NoEptTables;
    };

    var pool = ept.TablePool{
        .tables = @as([*]ept.Table, @ptrFromInt(pool_hpa))[0..table_count],
        .base_hpa = pool_hpa,
    };
    const pml4_hpa = ept.buildOffsetMap(&pool, ram_hpa, len, caps) catch {
        pmm.freeContiguous(raw, raw_frames);
        pmm.freeContiguous(pool_hpa, ept_frames);
        return error.EptBuildFailed;
    };

    // A guest must never see another guest's or the host's leftover bytes.
    @memset(@as([*]u8, @ptrFromInt(ram_hpa))[0..@intCast(len)], 0);

    return .{
        .ram_hpa = ram_hpa,
        .ram_len = len,
        .ram_raw_hpa = raw,
        .ram_raw_frames = raw_frames,
        .ept_pool_hpa = pool_hpa,
        .ept_pool_frames = ept_frames,
        .eptp = ept.eptp(pml4_hpa, caps),
    };
}

fn alignUp(v: u64, a: u64) u64 {
    return (v + a - 1) & ~(a - 1);
}
