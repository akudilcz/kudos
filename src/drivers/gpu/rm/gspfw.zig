//! GSP firmware ABI structures — byte-exact `extern struct` mirrors of NVIDIA's
//! nvrm headers (cross-checked against nouveau `gsp/rm/r535/nvrm/gsp.h`). The
//! signed firmware reads/writes these in DMA memory, so the layouts MUST match
//! exactly: field order, widths, and packing are part of the firmware ABI, not a
//! kudos choice.
//!
//! `comptime` size asserts guard the critical ones against accidental drift.

const std = @import("std");

/// GSP works in 4 KiB pages regardless of host page size.
pub const GSP_PAGE_SHIFT: u6 = 12;
pub const GSP_PAGE_SIZE: u64 = 1 << GSP_PAGE_SHIFT; // 0x1000

pub const GSP_FW_WPR_META_MAGIC: u64 = 0xdc3aae21371a60b3;
pub const GSP_FW_WPR_META_REVISION: u64 = 1;
pub const GSP_FW_WPR_META_VERIFIED: u64 = 0xa0a0a0a0a0a0a0a0;

/// Booter ⇄ GSP handoff descriptor. Exactly 256 bytes; the Booter validates the
/// magic/revision and DMAs the firmware per the sysmem addresses, then writes
/// `verified`. Mirrors `GspFwWprMeta` (nvrm/gsp.h ~418–555). The two unions are
/// flattened to their initial-boot variant (the only one M9 uses) plus padding to
/// preserve offsets.
pub const GspFwWprMeta = extern struct {
    magic: u64, // = GSP_FW_WPR_META_MAGIC
    revision: u64, // = GSP_FW_WPR_META_REVISION

    // data in SYSMEM (consumed by Booter for DMA)
    sysmemAddrOfRadix3Elf: u64,
    sizeOfRadix3Elf: u64,
    sysmemAddrOfBootloader: u64,
    sizeOfBootloader: u64,
    bootloaderCodeOffset: u64,
    bootloaderDataOffset: u64,
    bootloaderManifestOffset: u64,

    // union (initial-boot variant): signature address + size
    sysmemAddrOfSignature: u64,
    sizeOfSignature: u64,

    // FB layout
    gspFwRsvdStart: u64,
    nonWprHeapOffset: u64,
    nonWprHeapSize: u64,
    gspFwWprStart: u64,
    gspFwHeapOffset: u64,
    gspFwHeapSize: u64,
    gspFwOffset: u64, // size = sizeOfRadix3Elf
    bootBinOffset: u64, // size = sizeOfBootloader
    frtsOffset: u64,
    frtsSize: u64,
    gspFwWprEnd: u64,
    fbSize: u64,
    vgaWorkspaceOffset: u64,
    vgaWorkspaceSize: u64,
    bootCount: u64,

    // union (partitionRpc / crashReport): unused at initial boot — kept as raw
    // bytes to preserve the exact size/offsets. Sized so the whole struct lands
    // at the header's documented 256 bytes (verified by the assert below).
    union_partition: [32]u8,

    gspFwHeapVfPartitionCount: u8,
    padding: [7]u8,

    verified: u64, // Booter writes GSP_FW_WPR_META_VERIFIED on success

    comptime {
        // The header pads the struct to exactly 256 bytes.
        std.debug.assert(@sizeOf(GspFwWprMeta) == 256);
    }
};

/// Per-queue transmit header (`msgqTxHeader`, nvrm/gsp.h ~561). One sits at the
/// start of each queue's backing store.
pub const MsgqTxHeader = extern struct {
    version: u32, // queue version (=0)
    size: u32, // bytes, page aligned (=0x40000)
    msgSize: u32, // entry size, power-of-2, >=16 (=GSP_PAGE_SIZE)
    msgCount: u32, // (size - entryOff) / msgSize
    writePtr: u32, // message id of next slot
    flags: u32, // =1 ("want to swap RX")
    rxHdrOff: u32, // offset of MsgqRxHeader from backing-store start
    entryOff: u32, // offset of entries from backing-store start (=GSP_PAGE_SIZE)
};

/// Per-queue receive header (`msgqRxHeader`).
pub const MsgqRxHeader = extern struct {
    readPtr: u32, // message id of last message read
};

/// `MESSAGE_QUEUE_INIT_ARGUMENTS` — **r570 layout** (r570_gsp.h:497-502). The 570
/// firmware has NO lockless cmd/stat queue offsets (unlike r535). NvLength (u64)
/// 8-aligns, so a 4-byte pad after pageTableEntryCount → cmdQueueOffset @16.
pub const MessageQueueInitArguments = extern struct {
    sharedMemPhysAddr: u64, // off 0
    pageTableEntryCount: u32, // off 8
    _pad: u32 = 0, // off 12
    cmdQueueOffset: u64, // off 16
    statQueueOffset: u64, // off 24

    comptime {
        std.debug.assert(@sizeOf(MessageQueueInitArguments) == 32);
        std.debug.assert(@offsetOf(MessageQueueInitArguments, "cmdQueueOffset") == 16);
    }
};

/// `GSP_SR_INIT_ARGUMENTS` (r570_gsp.h:504-508).
pub const GspSrInitArguments = extern struct {
    oldLevel: u32,
    flags: u32,
    bInPMTransition: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

/// `GSP_ARGUMENTS_CACHED` — **r570 layout** (r570_gsp.h:510-522). r570 adds
/// `bDmemStack` (must be 1) after gpuInstance, before profilerArgs. The rmargs
/// buffer (0x1000) the libos "RMARGS" region points at.
pub const GspArgumentsCached = extern struct {
    messageQueueInitArguments: MessageQueueInitArguments, // off 0
    srInitArguments: GspSrInitArguments, // off 32
    gpuInstance: u32,
    bDmemStack: u8, // r570: set to 1
    _pad: [3]u8 = .{ 0, 0, 0 },
    profilerArgs_pa: u64,
    profilerArgs_size: u64,
};

/// `LibosMemoryRegionInitArgument` (nvrm/gsp.h:612-619). The GSP libos loader
/// indexes these contiguously; the C struct is 3×u64 + 2×u8 then padded to 32
/// (the array stride the loader assumes). `id8` is up to 8 ASCII chars packed
/// big-endian.
pub const LibosMemoryRegionInitArgument = extern struct {
    id8: u64, // off 0
    pa: u64, // off 8
    size: u64, // off 16
    kind: u8, // off 24  (LibosMemoryRegionKind)
    loc: u8, // off 25  (LibosMemoryRegionLoc)
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 }, // pad to 32-byte stride

    comptime {
        std.debug.assert(@sizeOf(LibosMemoryRegionInitArgument) == 32);
    }
};

pub const LIBOS_REGION_KIND_CONTIGUOUS: u8 = 1; // LIBOS_MEMORY_REGION_CONTIGUOUS
pub const LIBOS_REGION_LOC_SYSMEM: u8 = 1; // LIBOS_MEMORY_REGION_LOC_SYSMEM

/// Pack up to 8 ASCII chars into a u64, big-endian (r535_gsp_libos_id8):
/// id = 0; for each char: id = (id<<8)|c.
pub fn libosId8(name: []const u8) u64 {
    var id: u64 = 0;
    for (name) |c| id = (id << 8) | c;
    return id;
}

// --- GSP_SET_SYSTEM_INFO (fn 72) + SET_REGISTRY (fn 73) ---------------------
// The GSP RM consumes these two RPCs (queued into the cmdq during init, before
// the booter) as the first thing after it boots; without GSP_SET_SYSTEM_INFO the
// RM faults during init (Xid 62). nvrm/gsp.h GspSystemInfo + PACKED_REGISTRY_*.

pub const GSP_SET_SYSTEM_INFO: u32 = 72;
pub const SET_REGISTRY: u32 = 73;

/// BUSINFO (nvrm/gsp.h:242-249): u16×4 + u8, C-padded.
pub const BusInfo = extern struct {
    deviceID: u16,
    vendorID: u16,
    subdeviceID: u16,
    subvendorID: u16,
    revisionID: u8,
};

/// ACPI_METHOD_DATA (nvrm/gsp.h:290-297). All zero for kudos (no ACPI); modelled
/// with the exact nested sizes so GspSystemInfo's total size matches C.
pub const DodMethodData = extern struct { status: u32, acpiIdListLen: u32, acpiIdList: [16]u32 };
pub const JtMethodData = extern struct { status: u32, jtCaps: u32, jtRevId: u16, bSBIOSCaps: u8 };
pub const MuxElement = extern struct { acpiId: u32, mode: u32, status: u32 };
/// r570 MUX_METHOD_DATA has THREE 16-element tables (mode/part/state) — the r535
/// version had only two. The added stateTable is exactly the 192-byte gap that
/// made GspSystemInfo 0x2e0 instead of the firmware-expected 0x3a0 (r570_gsp.h).
pub const MuxMethodData = extern struct {
    tableLen: u32,
    modeTable: [16]MuxElement,
    partTable: [16]MuxElement,
    stateTable: [16]MuxElement,
};
pub const CapsMethodData = extern struct { status: u32, optimusCaps: u32 };
pub const AcpiMethodData = extern struct {
    bValid: u8,
    dod: DodMethodData,
    jt: JtMethodData,
    mux: MuxMethodData,
    caps: CapsMethodData,
};

pub const GspVfInfo = extern struct {
    totalVFs: u32,
    firstVFOffset: u32,
    FirstVFBar0Address: u64,
    FirstVFBar1Address: u64,
    FirstVFBar2Address: u64,
    b64bitBar0: u8,
    b64bitBar1: u8,
    b64bitBar2: u8,
};

/// GSP_PCIE_CONFIG_REG (r570_gsp.h:276-280).
pub const GspPcieConfigReg = extern struct { linkCap: u32 };

/// GspSystemInfo — **r570 layout** (r570_gsp.h:282-332). 570.144 firmware. This
/// differs substantially from r535: extra gpuPhysIoAddr, notifyOpSharedSurface,
/// PCIDeviceID/SubDeviceID/RevisionID, pcieAtomicsCplDeviceCapMask, bFlrSupported,
/// b64bBar0Supported, chipsetL1ssEnable, bSystemHasMux, bIsPrimary, isGridBuild,
/// pcieConfigReg, and a tail of capability bools + hostPageSize. Filling these
/// for the r535 layout (what we did before) corrupts everything the GSP reads.
pub const GspSystemInfo = extern struct {
    gpuPhysAddr: u64,
    gpuPhysFbAddr: u64,
    gpuPhysInstAddr: u64,
    gpuPhysIoAddr: u64,
    nvDomainBusDeviceFunc: u64,
    simAccessBufPhysAddr: u64,
    notifyOpSharedSurfacePhysAddr: u64,
    pcieAtomicsOpMask: u64,
    consoleMemSize: u64,
    maxUserVa: u64,
    pciConfigMirrorBase: u32,
    pciConfigMirrorSize: u32,
    PCIDeviceID: u32,
    PCISubDeviceID: u32,
    PCIRevisionID: u32,
    pcieAtomicsCplDeviceCapMask: u32,
    oorArch: u8,
    clPdbProperties: u64,
    Chipset: u32,
    bGpuBehindBridge: u8,
    bFlrSupported: u8,
    b64bBar0Supported: u8,
    bMnocAvailable: u8,
    chipsetL1ssEnable: u32,
    bUpstreamL0sUnsupported: u8,
    bUpstreamL1Unsupported: u8,
    bUpstreamL1PorSupported: u8,
    bUpstreamL1PorMobileOnly: u8,
    bSystemHasMux: u8,
    upstreamAddressValid: u8,
    FHBBusInfo: BusInfo,
    chipsetIDInfo: BusInfo,
    acpiMethodData: AcpiMethodData,
    hypervisorType: u32,
    bIsPassthru: u8,
    sysTimerOffsetNs: u64,
    gspVFInfo: GspVfInfo,
    bIsPrimary: u8,
    isGridBuild: u8,
    pcieConfigReg: GspPcieConfigReg,
    gridBuildCsp: u32,
    bPreserveVideoMemoryAllocations: u8,
    bTdrEventSupported: u8,
    bFeatureStretchVblankCapable: u8,
    bEnableDynamicGranularityPageArrays: u8,
    bClockBoostSupported: u8,
    bRouteDispIntrsToCPU: u8,
    hostPageSize: u64,

    comptime {
        // The 570.144 firmware sends fn:72 with payload 0x3a0 (nouveau trace).
        // Guard against nested-struct drift (e.g. the 3-table r570 MUX_METHOD_DATA).
        std.debug.assert(@sizeOf(GspSystemInfo) == 0x3a0);
    }
};

/// PACKED_REGISTRY_TABLE header (nvrm/gsp.h:235-240). `size` is the total bytes,
/// `numEntries` the count; entries[] follow. An empty table (numEntries=0,
/// size=8) is valid — the GSP uses defaults.
pub const PackedRegistryTable = extern struct {
    size: u32,
    numEntries: u32,
};

/// RPC message header (`rpc_message_header_v03_00`, nvrm/gsp.h ~793). Followed by
/// the function-specific payload.
pub const RpcMessageHeader = extern struct {
    header_version: u32,
    signature: u32,
    length: u32,
    function: u32, // NV_VGPU_MSG_* id (see msgfn/rpcfn)
    rpc_result: u32,
    rpc_result_private: u32,
    sequence: u32,
    u: u32, // union field (kept as a single dword for M9)
    // payload follows
};

/// Queue element wrapping an RPC message (`GSP_MSG_QUEUE_ELEMENT` / nouveau
/// `struct r535_gsp_msg`, rm_r535_rpc.c:94-117). The element header is exactly 48
/// bytes (GSP_MSG_HDR_SIZE); the RPC header starts at offset 48, payload at 80.
pub const GspMsgQueueElement = extern struct {
    authTagBuffer: [16]u8, // off 0
    aadBuffer: [16]u8, // off 16
    checkSum: u32, // off 32  (XOR over element == 0)
    seqNum: u32, // off 36
    elemCount: u32, // off 40  (number of 0x1000 pages this msg spans)
    _pad: u32 = 0, // off 44  (8-aligns the rpc that follows)
    // data[] (the RpcMessageHeader) follows at offset 48

    comptime {
        std.debug.assert(@sizeOf(GspMsgQueueElement) == 48);
    }
};

/// Element-header size (offset of the RPC header within an element).
pub const GSP_MSG_HDR_SIZE: u32 = 48;

/// A few NV_VGPU_MSG event ids the M9 handshake polls for (msgfn.h). Filled as
/// needed; GSP_INIT_DONE is the boot-complete signal.
pub const MsgEvent = enum(u32) {
    first_event = 0x1000, // NV_VGPU_MSG_EVENT_FIRST_EVENT
    gsp_init_done = 0x1001, // boot-complete signal the M9 handshake polls for
    gsp_run_cpu_sequencer = 0x1002,
    post_event = 0x1003,
    rc_triggered = 0x1004,
    mmu_fault_queued = 0x1005,
    os_error_log = 0x1006, // carries exceptType (Xid) + errString
    ucode_libos_print = 0x100c,
    post_nocat_record = 0x1020, // GSP catastrophe/diag record (NV2080 NOCAT entry)
    _,
};
