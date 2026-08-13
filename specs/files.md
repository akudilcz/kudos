# Files

File storage in the Kudos system: the ramdisk, the virtual file system that
unifies every mounted store, and FAT32 volumes.

## Storage

**STO-001.** The Kudos system shall maintain a ramdisk providing in-memory file
storage.

**STO-002.** The Kudos system shall unify access to all mounted stores behind a
single virtual file system, independent of the backing device.

**STO-003.** The Kudos system shall support the FAT32 file system.

**STO-004.** The Kudos system shall locate FAT32 volumes (STO-003) via the MBR
partition table.

**STO-005.** The Kudos system shall read VFAT long file names (STO-003).

**STO-006.** The Kudos system shall keep every FAT32 volume it writes (STO-003) valid,
such that the volume mounts on a stock Linux kernel.

**STO-007.** The Kudos system shall flush all pending file-system writes before
any reboot or power-off, so that every volume remains valid (STO-006).

**STO-008.** The Kudos system shall create, overwrite and delete ramdisk
(STO-001) files through the virtual file system (STO-002).

**STO-009.** The Kudos system shall present ramdisk (STO-001) files in a
hierarchy of directories, which it shall create and delete.

**STO-010.** The Kudos system shall refuse a write to a read-only store
(STO-002), stating that the store is read-only.
