//! RM (resource-manager) object-model ABI — byte-exact `extern struct` mirrors of
//! NVIDIA's nvrm headers for the post-INIT_DONE display path
//! (cross-checked against nouveau `gsp/rm/r535/nvrm/{alloc,ctrl}.h`,
//! `r570/nvrm/disp.h`, and `nvif/class.h`).
//!
//! kudos loads firmware 570.144 → the **r570** RM. Where r535 and r570 disagree
//! (some NV0073 ctrl numbers, the NV0000 alloc-params size, the channel-alloc
//! subDeviceId/pbTargetAperture fields) the r570 form is used — see
//! the r570 nvrm headers. These layouts cross the GSP RPC boundary,
//! so field order/width/packing are firmware ABI, guarded by `comptime` asserts.

const std = @import("std");

// ── RPC function ids (r570 nvrm/rpcfn.h) ───────────────────────────────────────
pub const FUNCTION_GSP_RM_ALLOC: u32 = 103;
pub const FUNCTION_GSP_RM_CONTROL: u32 = 76;
pub const FUNCTION_FREE: u32 = 10;

// ── Object handles (gsp/rm/handles.h) ──────────────────────────────────────────
/// Single-client kudos: client id 0 → handle 0xc1d00000.
pub const RM_CLIENT0: u32 = 0xc1d00000;
pub const RM_DEVICE: u32 = 0xde1d0000;
pub const RM_SUBDEVICE: u32 = 0x5d1d0000;
pub const RM_DISP: u32 = 0x00730000;

// ── Object class ids (nvif/class.h; AD102 set from rm/ad10x.c) ──────────────────
pub const NV01_ROOT: u32 = 0x0;
pub const NV01_DEVICE_0: u32 = 0x0080;
pub const NV20_SUBDEVICE_0: u32 = 0x2080;
pub const NV04_DISPLAY_COMMON: u32 = 0x0073;
pub const AD102_DISP: u32 = 0xc770; // disp root
pub const AD102_DISP_CORE_CHANNEL_DMA: u32 = 0xc77d;
pub const GA102_DISP_WINDOW_CHANNEL_DMA: u32 = 0xc67e; // AD102 window
pub const GA102_DISP_WINDOW_IMM_CHANNEL_DMA: u32 = 0xc67b;
pub const GA102_DISP_CURSOR: u32 = 0xc67a;

// ── Display ctrl command numbers (r570 values; r535 differs for SYSTEM_*) ───────
pub const CTRL_INTERNAL_DISPLAY_WRITE_INST_MEM: u32 = 0x20800a49;
pub const CTRL_INTERNAL_DISPLAY_GET_STATIC_INFO: u32 = 0x20800a01;
pub const CTRL_INTERNAL_DISPLAY_CHANNEL_PUSHBUFFER: u32 = 0x20800a58;
pub const CTRL_SYSTEM_GET_SUPPORTED: u32 = 0x730107; // r570
pub const CTRL_SYSTEM_GET_CONNECT_STATE: u32 = 0x730108; // r570
pub const CTRL_SYSTEM_GET_NUM_HEADS: u32 = 0x730102;
pub const CTRL_SPECIFIC_GET_CONNECTOR_DATA: u32 = 0x730250;
pub const CTRL_SPECIFIC_GET_EDID_V2: u32 = 0x730245;
pub const CTRL_DFP_ASSIGN_SOR: u32 = 0x731152;
pub const CTRL_DP_CTRL: u32 = 0x731343;
pub const CTRL_SPECIFIC_SET_HDMI_ENABLE: u32 = 0x730273;
pub const CTRL_SPECIFIC_OR_GET_INFO: u32 = 0x73028b;
pub const CTRL_DP_GET_CAPS: u32 = 0x731369;
pub const CTRL_DP_CONFIG_STREAM: u32 = 0x731362;
pub const CTRL_DP_SET_MANUAL_DISPLAYPORT: u32 = 0x731365;
pub const CTRL_SPECIFIC_GET_ALL_HEAD_MASK: u32 = 0x730287;
pub const CTRL_DP_AUXCH_CTRL: u32 = 0x731341;

// ── Memory-target / cache enums (r570 nvrm/disp.h) ──────────────────────────────
pub const ADDR_SYSMEM: u32 = 1;
pub const ADDR_FBMEM: u32 = 2;
pub const MEMORY_WRITECOMBINED: u32 = 2;
pub const PBTARGET_PHYS_NVM: u32 = 1;

// ── RPC wire headers (r535/nvrm/{alloc,ctrl}.h) ────────────────────────────────
// GSP_RM_ALLOC: params follow at offset 32.
pub const RpcRmAlloc = extern struct {
    hClient: u32,
    hParent: u32,
    hObject: u32,
    hClass: u32,
    status: u32,
    paramsSize: u32,
    flags: u32,
    reserved: [4]u8,
    // params[] at offset 32
};
comptime {
    std.debug.assert(@sizeOf(RpcRmAlloc) == 32);
}

// GSP_RM_CONTROL: params follow at offset 24.
pub const RpcRmControl = extern struct {
    hClient: u32,
    hObject: u32,
    cmd: u32,
    status: u32,
    paramsSize: u32,
    flags: u32,
    // params[] at offset 24
};
comptime {
    std.debug.assert(@sizeOf(RpcRmControl) == 24);
}

// ── Object alloc params ────────────────────────────────────────────────────────
// NV0000_ALLOC_PARAMETERS (r570 nvrm/client.h) — 120 bytes.
pub const NV_PROC_NAME_MAX_LENGTH: usize = 100;
pub const Nv0000AllocParams = extern struct {
    hClient: u32,
    processID: u32,
    processName: [NV_PROC_NAME_MAX_LENGTH]u8,
    pad: [4]u8,
    pOsPidInfo: u64 align(8),
};
comptime {
    std.debug.assert(@sizeOf(Nv0000AllocParams) == 120);
    std.debug.assert(@offsetOf(Nv0000AllocParams, "processName") == 8);
    std.debug.assert(@offsetOf(Nv0000AllocParams, "pOsPidInfo") == 112);
}

// NV0080_ALLOC_PARAMETERS (r535/nvrm/device.h) — 56 bytes.
pub const Nv0080AllocParams = extern struct {
    deviceId: u32,
    hClientShare: u32,
    hTargetClient: u32,
    hTargetDevice: u32,
    flags: u32,
    vaSpaceSize: u64 align(8),
    vaStartInternal: u64,
    vaLimitInternal: u64,
    vaMode: u32,
};
comptime {
    std.debug.assert(@sizeOf(Nv0080AllocParams) == 56);
    std.debug.assert(@offsetOf(Nv0080AllocParams, "vaSpaceSize") == 24);
    std.debug.assert(@offsetOf(Nv0080AllocParams, "vaMode") == 48);
}

// NV2080_ALLOC_PARAMETERS (r535/nvrm/device.h) — 4 bytes.
pub const Nv2080AllocParams = extern struct {
    subDeviceId: u32,
};
comptime {
    std.debug.assert(@sizeOf(Nv2080AllocParams) == 4);
}

// ── Display ctrl params ────────────────────────────────────────────────────────
// NV2080_CTRL_INTERNAL_DISPLAY_WRITE_INST_MEM_PARAMS (r535/nvrm/disp.h).
pub const WriteInstMemParams = extern struct {
    instMemPhysAddr: u64 align(8),
    instMemSize: u64 align(8),
    instMemAddrSpace: u32,
    instMemCpuCacheAttr: u32,
};
comptime {
    std.debug.assert(@sizeOf(WriteInstMemParams) == 24);
}

// NV0073_CTRL_SYSTEM_GET_SUPPORTED_PARAMS (r570 nvrm/disp.h) — 12 bytes.
pub const SystemGetSupportedParams = extern struct {
    subDeviceInstance: u32,
    displayMask: u32,
    displayMaskDDC: u32,
};
comptime {
    std.debug.assert(@sizeOf(SystemGetSupportedParams) == 12);
}

// NV0073_CTRL_SYSTEM_GET_CONNECT_STATE_PARAMS (r570 nvrm/disp.h) — 16 bytes.
pub const SystemGetConnectStateParams = extern struct {
    subDeviceInstance: u32,
    flags: u32,
    displayMask: u32,
    retryTimeMs: u32,
};
comptime {
    std.debug.assert(@sizeOf(SystemGetConnectStateParams) == 16);
}

// NV0073_CTRL_SPECIFIC_GET_EDID_V2_PARAMS (r535/nvrm/disp.h) — 2064 bytes.
pub const EDID_MAX_BYTES: usize = 2048;
pub const SpecificGetEdidV2Params = extern struct {
    subDeviceInstance: u32,
    displayId: u32,
    bufferSize: u32,
    flags: u32,
    edidBuffer: [EDID_MAX_BYTES]u8,
};
comptime {
    std.debug.assert(@sizeOf(SpecificGetEdidV2Params) == 2064);
}

// ── Disp channel-alloc params (r570 nvrm/disp.h) ────────────────────────────────
// (AD102_DISP_CORE_CHANNEL_DMA + CTRL_INTERNAL_DISPLAY_CHANNEL_PUSHBUFFER defined above.)
/// channelPBSize selector (PB_SIZE_4KB).
pub const DISP_CHANNEL_PB_SIZE_4KB: u32 = 0;
/// subDeviceId = BIT(0): the single-subdevice mask r570 expects on the disp path.
pub const DISP_SUBDEVICE_ID_BIT0: u32 = 1;

// NV2080_CTRL_INTERNAL_DISPLAY_CHANNEL_PUSHBUFFER_PARAMS — 56 bytes. Describes a
// channel's pushbuffer to the GSP. r570 fields pbTargetAperture + subDeviceId are
// required. Mind the 3-byte pad after `valid` (u8) before pbTargetAperture (u32).
pub const ChannelPushbufferParams = extern struct {
    addressSpace: u32, // ADDR_FBMEM
    physicalAddr: u64 align(8),
    limit: u64 align(8),
    cacheSnoop: u32,
    hclass: u32, // 0xc77d
    channelInstance: u32,
    valid: u8, // NvBool
    pbTargetAperture: u32, // PBTARGET_PHYS_NVM
    channelPBSize: u32, // PB_SIZE_4KB = 0
    subDeviceId: u32, // BIT(0)
};
comptime {
    std.debug.assert(@sizeOf(ChannelPushbufferParams) == 56);
    std.debug.assert(@offsetOf(ChannelPushbufferParams, "valid") == 36);
    std.debug.assert(@offsetOf(ChannelPushbufferParams, "pbTargetAperture") == 40);
    std.debug.assert(@offsetOf(ChannelPushbufferParams, "subDeviceId") == 48);
}

// NV50VAIO_CHANNELDMA_ALLOCATION_PARAMETERS — 40 bytes. RM fills pControl on return.
pub const ChannelDmaAllocParams = extern struct {
    channelInstance: u32,
    hObjectBuffer: u32,
    hObjectNotify: u32,
    offset: u32,
    pControl: u64 align(8),
    flags: u32,
    channelPBSize: u32,
    subDeviceId: u32, // BIT(0)
};
comptime {
    std.debug.assert(@sizeOf(ChannelDmaAllocParams) == 40);
    std.debug.assert(@offsetOf(ChannelDmaAllocParams, "pControl") == 16);
    std.debug.assert(@offsetOf(ChannelDmaAllocParams, "subDeviceId") == 32);
}

// NV50VAIO_CHANNELPIO_ALLOCATION_PARAMETERS (r535 nvrm/disp.h:717-723) — the
// cursor channel's alloc params (PIO: no pushbuffer). Only channelInstance
// (= head) is meaningful; notify/control stay 0 (r535_curs_init parity).
pub const ChannelPioAllocParams = extern struct {
    channelInstance: u32,
    hObjectNotify: u32,
    pControl: u64 align(8),
};
comptime {
    std.debug.assert(@sizeOf(ChannelPioAllocParams) == 16);
    std.debug.assert(@offsetOf(ChannelPioAllocParams, "pControl") == 8);
}

// ===========================================================================
// Host FIFO (GPFIFO) + copy engine — r570 ABI.
// ===========================================================================

pub const FERMI_VASPACE_A: u32 = 0x90f1;
pub const AMPERE_CHANNEL_GPFIFO_A: u32 = 0xc56f;
pub const AMPERE_DMA_COPY_B: u32 = 0xc7b5;

pub const NV2080_ENGINE_TYPE_COPY0: u32 = 0x09;

pub const CTRL_GPFIFO_BIND: u32 = 0xa06f0104;
pub const CTRL_GPFIFO_SCHEDULE: u32 = 0xa06f0103;
pub const CTRL_CE_GET_FAULT_METHOD_BUFFER_SIZE: u32 = 0x20802a08;
pub const CTRL_VASPACE_COPY_SERVER_RESERVED_PDES: u32 = 0x90f10106;

// Memory address spaces for NV_MEMORY_DESC_PARAMS.
pub const ADDR_SPACE_SYSMEM: u32 = 1;
pub const ADDR_SPACE_VIDMEM: u32 = 2;

// The mandatory server-managed VA split (nvrm/vmm.h:28-29).
pub const SPLIT_VAS_SERVER_VA_START: u64 = 0x1_0000_0000;
pub const SPLIT_VAS_SERVER_VA_SIZE: u64 = 0x2000_0000;

/// NV_VASPACE_ALLOCATION_PARAMETERS — 48 bytes; all-zero for GPU_NEW.
pub const VaspaceAllocParams = extern struct {
    index: u32,
    flags: u32,
    vaSize: u64 align(8),
    vaStartInternal: u64 align(8),
    vaLimitInternal: u64 align(8),
    bigPageSize: u32,
    vaBase: u64 align(8),
};
comptime {
    std.debug.assert(@sizeOf(VaspaceAllocParams) == 48);
    std.debug.assert(@offsetOf(VaspaceAllocParams, "vaBase") == 40);
}

/// NV_MEMORY_DESC_PARAMS (nvrm/fifo.h:148-153) — 24 bytes.
pub const MemoryDescParams = extern struct {
    base: u64 align(8),
    size: u64 align(8),
    addressSpace: u32,
    cacheAttrib: u32,
};
comptime {
    std.debug.assert(@sizeOf(MemoryDescParams) == 24);
}

/// NV_CHANNELGPFIFO_ALLOCATION_PARAMETERS (nvrm/fifo.h:157-207) — 360 bytes.
pub const ChannelGpfifoAllocParams = extern struct {
    hObjectError: u32,
    hObjectBuffer: u32,
    gpFifoOffset: u64 align(8),
    gpFifoEntries: u32,
    flags: u32,
    hContextShare: u32,
    hVASpace: u32,
    hUserdMemory: [8]u32,
    userdOffset: [8]u64 align(8),
    engineType: u32,
    cid: u32,
    subDeviceId: u32,
    hObjectEccError: u32,
    instanceMem: MemoryDescParams,
    userdMem: MemoryDescParams,
    ramfcMem: MemoryDescParams,
    mthdbufMem: MemoryDescParams,
    hPhysChannelGroup: u32,
    internalFlags: u32,
    errorNotifierMem: MemoryDescParams,
    eccErrorNotifierMem: MemoryDescParams,
    ProcessID: u32,
    SubProcessID: u32,
    encryptIv: [3]u32,
    decryptIv: [3]u32,
    hmacNonce: [8]u32,
    tpcConfigID: u32, // r570 addition (rm/r570/nvrm/fifo.h:69) — absent in r535
};
comptime {
    std.debug.assert(@sizeOf(ChannelGpfifoAllocParams) == 368);
    std.debug.assert(@offsetOf(ChannelGpfifoAllocParams, "tpcConfigID") == 360);
    std.debug.assert(@offsetOf(ChannelGpfifoAllocParams, "engineType") == 128);
    std.debug.assert(@offsetOf(ChannelGpfifoAllocParams, "instanceMem") == 144);
    std.debug.assert(@offsetOf(ChannelGpfifoAllocParams, "hPhysChannelGroup") == 240);
    std.debug.assert(@offsetOf(ChannelGpfifoAllocParams, "hmacNonce") == 328);
}

/// NVC0B5_ALLOCATION_PARAMETERS — 8 bytes.
pub const Cb5AllocParams = extern struct {
    version: u32, // 1
    engineType: u32, // NV2080_ENGINE_TYPE_COPY0
};

/// NVA06F_CTRL_BIND_PARAMS — 4 bytes.
pub const GpfifoBindParams = extern struct {
    engineType: u32,
};

/// NVA06F_CTRL_GPFIFO_SCHEDULE_PARAMS — 2 bytes (NvBool = u8).
pub const GpfifoScheduleParams = extern struct {
    bEnable: u8,
    bSkipSubmit: u8,
};

/// NV90F1_CTRL_VASPACE_COPY_SERVER_RESERVED_PDES_PARAMS — 184 bytes.
pub const CopyServerReservedPdesParams = extern struct {
    hSubDevice: u32,
    subDeviceId: u32,
    pageSize: u64 align(8),
    virtAddrLo: u64 align(8),
    virtAddrHi: u64 align(8),
    numLevelsToCopy: u32,
    levels: [6]PdeLevel align(8),

    pub const PdeLevel = extern struct {
        physAddress: u64 align(8),
        size: u64 align(8),
        aperture: u32,
        pageShift: u32,
    };
};
comptime {
    std.debug.assert(@sizeOf(CopyServerReservedPdesParams) == 184);
    std.debug.assert(@offsetOf(CopyServerReservedPdesParams, "levels") == 40);
}

// ── GR engine (3D) ─────────────────────────────────────────────────────────────

/// ADA_A 3D class (nvif/class.h:207); object alloc takes NO params.
pub const ADA_A: u32 = 0xc997;
/// RM_ENGINE_TYPE_GR0 == NV2080_ENGINE_TYPE_GR0 (r535/nvrm/engine.h:126,181).
pub const NV2080_ENGINE_TYPE_GR0: u32 = 0x01;

/// NV2080_CTRL_CMD_INTERNAL_STATIC_KGR_GET_CONTEXT_BUFFERS_INFO (r570/nvrm/gr.h:11).
pub const CTRL_KGR_GET_CONTEXT_BUFFERS_INFO: u32 = 0x20800a32;
/// NV2080_CTRL_CMD_GPU_PROMOTE_CTX (r535/nvrm/fifo.h:327).
pub const CTRL_GPU_PROMOTE_CTX: u32 = 0x2080012b;

/// GR context-buffer engine ids (query index) + promote bufferIds
/// (r570/nvrm/gr.h:31-56, r535/nvrm/gr.h:58-70).
pub const GR_CTXBUF_COUNT: u32 = 0x1a; // r570 ENGINE_ID_COUNT (r535 was 0x19)
pub const GrBufferId = struct {
    pub const MAIN: u16 = 0;
    pub const PATCH: u16 = 2;
    pub const BUFFER_BUNDLE_CB: u16 = 3;
    pub const PAGEPOOL: u16 = 4;
    pub const ATTRIBUTE_CB: u16 = 5;
    pub const RTV_CB_GLOBAL: u16 = 6;
    pub const FECS_EVENT: u16 = 9;
    pub const PRIV_ACCESS_MAP: u16 = 10;
    pub const UNRESTRICTED_PRIV_ACCESS_MAP: u16 = 11;
};

/// NV2080_CTRL_INTERNAL_STATIC_GR_GET_CONTEXT_BUFFERS_INFO_PARAMS (r570 layout,
/// 8 engines x 0x1a buffers x {u32 size, u32 alignment} = 1664 B).
pub const GrCtxBuffersInfoParams = extern struct {
    pub const Info = extern struct { size: u32, alignment: u32 };
    engineContextBuffersInfo: [8][GR_CTXBUF_COUNT]Info,
};
comptime {
    std.debug.assert(@sizeOf(GrCtxBuffersInfoParams) == 1664);
}

/// NV2080_CTRL_GPU_PROMOTE_CTX_BUFFER_ENTRY (r535/nvrm/fifo.h:317-325), 32 B.
pub const PromoteCtxEntry = extern struct {
    gpuPhysAddr: u64 align(8),
    gpuVirtAddr: u64 align(8),
    size: u64 align(8),
    physAttr: u32,
    bufferId: u16,
    bInitialize: u8,
    bNonmapped: u8,
};

/// NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS (r535/nvrm/fifo.h:327-340), 560 B.
pub const PromoteCtxParams = extern struct {
    engineType: u32,
    hClient: u32,
    ChID: u32,
    hChanClient: u32,
    hObject: u32,
    hVirtMemory: u32,
    virtAddress: u64 align(8),
    size: u64 align(8),
    entryCount: u32,
    promoteEntry: [16]PromoteCtxEntry align(8),
};
comptime {
    std.debug.assert(@sizeOf(PromoteCtxEntry) == 32);
    std.debug.assert(@sizeOf(PromoteCtxParams) == 560);
    std.debug.assert(@offsetOf(PromoteCtxParams, "promoteEntry") == 48);
}

/// NVOS00_PARAMETERS_v03_00 — the FREE RPC payload (r535/nvrm/alloc.h:24-35).
pub const RpcFreeParams = extern struct {
    hRoot: u32,
    hObjectParent: u32,
    hObjectOld: u32,
    status: u32,
};
