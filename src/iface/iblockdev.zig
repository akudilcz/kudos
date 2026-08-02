//! IBlockDev — the block-storage seam (512-byte sectors). Pure vtable-type
//! module. The ONLY real implementation is USB mass storage
//! (drivers/usb/msc.zig over xhci bulk endpoints) — kudos deliberately has
//! no NVMe/AHCI driver, so the machine's onboard disks are unaddressable by
//! construction. Host tests fake this over an in-memory image
//! (test/drivers/storage/fat_test.zig).

pub const SECTOR: usize = 512;

pub const Error = error{
    BlockOutOfRange, // lba+count beyond the device
    BlockIoFailed, // transport error (BOT/xHCI failure, device gone)
};

pub const IBlockDev = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read `count` sectors starting at `lba` into `buf`
        /// (buf.len == count*SECTOR — the caller sizes it exactly).
        read: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: []u8) Error!void,
        /// Write `count` sectors starting at `lba` from `buf`
        /// (buf.len == count*SECTOR). Does NOT flush the device cache — call
        /// `sync` when durability is required. Keeping write and sync SEPARATE
        /// lets the boot-log ring stream bulk writes cheaply (device cache) and
        /// pay the (~ms) SYNCHRONIZE CACHE only on the panic path — writing per
        /// line WITH a sync each time lagged the whole cooperative boot.
        /// The ONLY writer is the boot-log ring; there is no general fs write.
        write: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) Error!void,
        /// SYNCHRONIZE CACHE: commit all prior writes to non-volatile medium.
        /// Durability barrier — the flight recorder calls it on flushNow (panic).
        sync: *const fn (ctx: *anyopaque) Error!void,
        /// Total sectors on the device.
        nblocks: *const fn (ctx: *anyopaque) u64,
    };

    pub fn read(self: IBlockDev, lba: u64, count: u32, buf: []u8) Error!void {
        return self.vtable.read(self.ctx, lba, count, buf);
    }
    pub fn write(self: IBlockDev, lba: u64, count: u32, buf: []const u8) Error!void {
        return self.vtable.write(self.ctx, lba, count, buf);
    }
    pub fn sync(self: IBlockDev) Error!void {
        return self.vtable.sync(self.ctx);
    }
    pub fn nblocks(self: IBlockDev) u64 {
        return self.vtable.nblocks(self.ctx);
    }
};
