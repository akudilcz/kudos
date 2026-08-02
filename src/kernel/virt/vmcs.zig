//! VMCS field encodings and VMX control-bit vocabulary (Intel SDM Vol 3D
//! Appendix B; execution-control bits from Vol 3C §24.6–24.9). Pure data: every
//! constant here is a number the CPU decodes, so this module reads/writes no
//! hardware and host-tests fully (test/kernel/virt/vmcs_test.zig). The IO edge that actually
//! issues VMREAD/VMWRITE is virt/vmxasm.zig; it takes a `Field` from here.
//!
//! A VMCS field is named by a 32-bit encoding whose bits carry meaning
//! (SDM Vol 3D §B.1, Table B-1 note):
//!   bit 0      access type (0 = full, 1 = high dword of a 64-bit field)
//!   bits 9:1   index within (type, width)
//!   bits 11:10 field type: 0 control, 1 VM-exit info (read-only), 2 guest, 3 host
//!   bit 12     reserved (0)
//!   bits 14:13 width: 0 = 16-bit, 1 = 64-bit, 2 = 32-bit, 3 = natural
//! `width(f)` and `fieldType(f)` recover those from the encoding, which is the
//! invariant the host test pins: the declared category of every field must equal
//! the category its encoding decodes to.

/// VMCS field width class (encoding bits 14:13). Natural width is 64-bit in long
/// mode. A 64-bit field is accessed as one VMREAD/VMWRITE in 64-bit mode.
pub const Width = enum(u2) { w16 = 0, w64 = 1, w32 = 2, natural = 3 };

/// VMCS field type class (encoding bits 11:10).
pub const Kind = enum(u2) { control = 0, exit_info = 1, guest = 2, host = 3 };

/// The subset of VMCS fields the hypervisor reads or writes. Values are the SDM
/// encodings verbatim (Appendix B); the enum is non-exhaustive so a stray VMREAD
/// of an unlisted field still type-checks through @enumFromInt during debug dumps.
pub const Field = enum(u32) {
    // --- 16-bit control ---
    vpid = 0x0000,
    posted_int_notify_vector = 0x0002,
    eptp_index = 0x0004,

    // --- 16-bit guest state ---
    guest_es_sel = 0x0800,
    guest_cs_sel = 0x0802,
    guest_ss_sel = 0x0804,
    guest_ds_sel = 0x0806,
    guest_fs_sel = 0x0808,
    guest_gs_sel = 0x080A,
    guest_ldtr_sel = 0x080C,
    guest_tr_sel = 0x080E,
    guest_interrupt_status = 0x0810,

    // --- 16-bit host state ---
    host_es_sel = 0x0C00,
    host_cs_sel = 0x0C02,
    host_ss_sel = 0x0C04,
    host_ds_sel = 0x0C06,
    host_fs_sel = 0x0C08,
    host_gs_sel = 0x0C0A,
    host_tr_sel = 0x0C0C,

    // --- 64-bit control (full-dword encodings; high halves are +1) ---
    io_bitmap_a = 0x2000,
    io_bitmap_b = 0x2002,
    msr_bitmap = 0x2004,
    exit_msr_store_addr = 0x2006,
    exit_msr_load_addr = 0x2008,
    entry_msr_load_addr = 0x200A,
    tsc_offset = 0x2010,
    virtual_apic_addr = 0x2012,
    apic_access_addr = 0x2014,
    ept_pointer = 0x201A,

    // --- 64-bit read-only data ---
    guest_phys_addr = 0x2400,

    // --- 64-bit guest state ---
    vmcs_link_pointer = 0x2800,
    guest_ia32_debugctl = 0x2802,
    guest_ia32_pat = 0x2804,
    guest_ia32_efer = 0x2806,

    // --- 64-bit host state ---
    host_ia32_pat = 0x2C00,
    host_ia32_efer = 0x2C02,

    // --- 32-bit control ---
    pin_ctls = 0x4000,
    proc_ctls = 0x4002,
    exception_bitmap = 0x4004,
    page_fault_ec_mask = 0x4006,
    page_fault_ec_match = 0x4008,
    cr3_target_count = 0x400A,
    exit_ctls = 0x400C,
    exit_msr_store_count = 0x400E,
    exit_msr_load_count = 0x4010,
    entry_ctls = 0x4012,
    entry_msr_load_count = 0x4014,
    entry_interruption_info = 0x4016,
    entry_exception_ec = 0x4018,
    entry_instruction_len = 0x401A,
    tpr_threshold = 0x401C,
    proc_ctls2 = 0x401E,
    ple_gap = 0x4020,
    ple_window = 0x4022,

    // --- 32-bit read-only data ---
    vm_instruction_error = 0x4400,
    exit_reason = 0x4402,
    exit_interruption_info = 0x4404,
    exit_interruption_ec = 0x4406,
    idt_vectoring_info = 0x4408,
    idt_vectoring_ec = 0x440A,
    exit_instruction_len = 0x440C,
    exit_instruction_info = 0x440E,

    // --- 32-bit guest state ---
    guest_es_limit = 0x4800,
    guest_cs_limit = 0x4802,
    guest_ss_limit = 0x4804,
    guest_ds_limit = 0x4806,
    guest_fs_limit = 0x4808,
    guest_gs_limit = 0x480A,
    guest_ldtr_limit = 0x480C,
    guest_tr_limit = 0x480E,
    guest_gdtr_limit = 0x4810,
    guest_idtr_limit = 0x4812,
    guest_es_ar = 0x4814,
    guest_cs_ar = 0x4816,
    guest_ss_ar = 0x4818,
    guest_ds_ar = 0x481A,
    guest_fs_ar = 0x481C,
    guest_gs_ar = 0x481E,
    guest_ldtr_ar = 0x4820,
    guest_tr_ar = 0x4822,
    guest_interruptibility = 0x4824,
    guest_activity_state = 0x4826,
    guest_ia32_sysenter_cs = 0x482A,
    vmx_preempt_timer = 0x482E,

    // --- 32-bit host state ---
    host_ia32_sysenter_cs = 0x4C00,

    // --- natural-width control ---
    cr0_guest_host_mask = 0x6000,
    cr4_guest_host_mask = 0x6002,
    cr0_read_shadow = 0x6004,
    cr4_read_shadow = 0x6006,

    // --- natural-width read-only data ---
    exit_qualification = 0x6400,
    io_rcx = 0x6402,
    io_rsi = 0x6404,
    io_rdi = 0x6406,
    io_rip = 0x6408,
    guest_linear_addr = 0x640A,

    // --- natural-width guest state ---
    guest_cr0 = 0x6800,
    guest_cr3 = 0x6802,
    guest_cr4 = 0x6804,
    guest_es_base = 0x6806,
    guest_cs_base = 0x6808,
    guest_ss_base = 0x680A,
    guest_ds_base = 0x680C,
    guest_fs_base = 0x680E,
    guest_gs_base = 0x6810,
    guest_ldtr_base = 0x6812,
    guest_tr_base = 0x6814,
    guest_gdtr_base = 0x6816,
    guest_idtr_base = 0x6818,
    guest_dr7 = 0x681A,
    guest_rsp = 0x681C,
    guest_rip = 0x681E,
    guest_rflags = 0x6820,
    guest_pending_dbg = 0x6822,
    guest_ia32_sysenter_esp = 0x6824,
    guest_ia32_sysenter_eip = 0x6826,

    // --- natural-width host state ---
    host_cr0 = 0x6C00,
    host_cr3 = 0x6C02,
    host_cr4 = 0x6C04,
    host_fs_base = 0x6C06,
    host_gs_base = 0x6C08,
    host_tr_base = 0x6C0A,
    host_gdtr_base = 0x6C0C,
    host_idtr_base = 0x6C0E,
    host_ia32_sysenter_esp = 0x6C10,
    host_ia32_sysenter_eip = 0x6C12,
    host_rsp = 0x6C14,
    host_rip = 0x6C16,
    _,

    /// Decode the width class from encoding bits 14:13.
    pub fn width(f: Field) Width {
        return @enumFromInt(@as(u2, @truncate(@intFromEnum(f) >> 13)));
    }

    /// Decode the field type from encoding bits 11:10.
    pub fn fieldType(f: Field) Kind {
        return @enumFromInt(@as(u2, @truncate(@intFromEnum(f) >> 10)));
    }
};

/// Basic exit reasons (SDM Vol 3C Appendix C). The low 16 bits of the exit-reason
/// field; bit 31 (entry-failure) is stripped by the caller before mapping here.
pub const ExitReason = enum(u16) {
    exception_nmi = 0,
    external_interrupt = 1,
    triple_fault = 2,
    init_signal = 3,
    sipi = 4,
    interrupt_window = 7,
    nmi_window = 8,
    task_switch = 9,
    cpuid = 10,
    hlt = 12,
    invd = 13,
    invlpg = 14,
    rdpmc = 15,
    rdtsc = 16,
    vmcall = 18,
    cr_access = 28,
    mov_dr = 29,
    io_instruction = 30,
    rdmsr = 31,
    wrmsr = 32,
    entry_fail_guest_state = 33,
    entry_fail_msr_load = 34,
    mwait = 36,
    monitor = 39,
    pause = 40,
    entry_fail_machine_check = 41,
    tpr_below_threshold = 43,
    apic_access = 44,
    eoi_induced = 45,
    gdtr_idtr_access = 46,
    ldtr_tr_access = 47,
    ept_violation = 48,
    ept_misconfig = 49,
    invept = 50,
    rdtscp = 51,
    preemption_timer = 52,
    invvpid = 53,
    wbinvd = 54,
    xsetbv = 55,
    apic_write = 56,
    rdrand = 57,
    invpcid = 58,
    vmfunc = 59,
    rdseed = 61,
    xsaves = 63,
    xrstors = 64,
    _,
};

/// Bit 31 of the exit-reason field: set when VM entry failed (the "exit" is an
/// entry failure, and bits 15:0 name the failure check). SDM Vol 3C §24.9.1.
pub const EXIT_REASON_ENTRY_FAILURE: u32 = 1 << 31;

// --- Pin-based VM-execution controls (SDM Vol 3C Table 24-5) ---
pub const PIN_EXTERNAL_INTERRUPT_EXITING: u32 = 1 << 0;
pub const PIN_NMI_EXITING: u32 = 1 << 3;
pub const PIN_VIRTUAL_NMIS: u32 = 1 << 5;
pub const PIN_PREEMPTION_TIMER: u32 = 1 << 6;
pub const PIN_POSTED_INTERRUPTS: u32 = 1 << 7;

// --- Primary processor-based controls (SDM Vol 3C Table 24-6) ---
pub const PROC_INTERRUPT_WINDOW_EXITING: u32 = 1 << 2;
pub const PROC_USE_TSC_OFFSETTING: u32 = 1 << 3;
pub const PROC_HLT_EXITING: u32 = 1 << 7;
pub const PROC_INVLPG_EXITING: u32 = 1 << 9;
pub const PROC_MWAIT_EXITING: u32 = 1 << 10;
pub const PROC_RDPMC_EXITING: u32 = 1 << 11;
pub const PROC_RDTSC_EXITING: u32 = 1 << 12;
pub const PROC_CR3_LOAD_EXITING: u32 = 1 << 15;
pub const PROC_CR3_STORE_EXITING: u32 = 1 << 16;
pub const PROC_CR8_LOAD_EXITING: u32 = 1 << 19;
pub const PROC_CR8_STORE_EXITING: u32 = 1 << 20;
pub const PROC_USE_TPR_SHADOW: u32 = 1 << 21;
pub const PROC_NMI_WINDOW_EXITING: u32 = 1 << 22;
pub const PROC_MOV_DR_EXITING: u32 = 1 << 23;
pub const PROC_UNCONDITIONAL_IO_EXITING: u32 = 1 << 24;
pub const PROC_USE_IO_BITMAPS: u32 = 1 << 25;
pub const PROC_USE_MSR_BITMAPS: u32 = 1 << 28;
pub const PROC_MONITOR_EXITING: u32 = 1 << 29;
pub const PROC_ACTIVATE_SECONDARY: u32 = 1 << 31;

// --- Secondary processor-based controls (SDM Vol 3C Table 24-7) ---
pub const PROC2_VIRTUALIZE_APIC_ACCESSES: u32 = 1 << 0;
pub const PROC2_ENABLE_EPT: u32 = 1 << 1;
pub const PROC2_DESCRIPTOR_TABLE_EXITING: u32 = 1 << 2;
pub const PROC2_ENABLE_RDTSCP: u32 = 1 << 3;
pub const PROC2_VIRTUALIZE_X2APIC: u32 = 1 << 4;
pub const PROC2_ENABLE_VPID: u32 = 1 << 5;
pub const PROC2_WBINVD_EXITING: u32 = 1 << 6;
pub const PROC2_UNRESTRICTED_GUEST: u32 = 1 << 7;
pub const PROC2_ENABLE_INVPCID: u32 = 1 << 12;
pub const PROC2_ENABLE_XSAVES: u32 = 1 << 20;

// --- VM-exit controls (SDM Vol 3C Table 24-13) ---
pub const EXIT_SAVE_DEBUG_CONTROLS: u32 = 1 << 2;
pub const EXIT_HOST_ADDR_SPACE_SIZE: u32 = 1 << 9; // host is 64-bit after exit
pub const EXIT_LOAD_IA32_PERF_GLOBAL_CTRL: u32 = 1 << 12;
pub const EXIT_ACK_INTERRUPT_ON_EXIT: u32 = 1 << 15;
pub const EXIT_SAVE_IA32_PAT: u32 = 1 << 18;
pub const EXIT_LOAD_IA32_PAT: u32 = 1 << 19;
pub const EXIT_SAVE_IA32_EFER: u32 = 1 << 20;
pub const EXIT_LOAD_IA32_EFER: u32 = 1 << 21;
pub const EXIT_SAVE_PREEMPTION_TIMER: u32 = 1 << 22;

// --- VM-entry controls (SDM Vol 3C Table 24-16) ---
pub const ENTRY_LOAD_DEBUG_CONTROLS: u32 = 1 << 2;
pub const ENTRY_IA32E_MODE_GUEST: u32 = 1 << 9; // guest enters in 64-bit mode
pub const ENTRY_SMM: u32 = 1 << 10;
pub const ENTRY_DEACTIVATE_DUAL_MONITOR: u32 = 1 << 11;
pub const ENTRY_LOAD_IA32_PERF_GLOBAL_CTRL: u32 = 1 << 13;
pub const ENTRY_LOAD_IA32_PAT: u32 = 1 << 14;
pub const ENTRY_LOAD_IA32_EFER: u32 = 1 << 15;

/// VM-entry interruption-information field layout (SDM Vol 3C §24.8.3). Written to
/// `entry_interruption_info` to inject an event on the next VM entry.
pub const EntryIntrInfo = struct {
    pub const VALID: u32 = 1 << 31;
    pub const TYPE_EXTERNAL: u32 = 0 << 8;
    pub const TYPE_NMI: u32 = 2 << 8;
    pub const TYPE_HARDWARE_EXCEPTION: u32 = 3 << 8;
    pub const TYPE_SOFTWARE_INTERRUPT: u32 = 4 << 8;
    pub const DELIVER_ERROR_CODE: u32 = 1 << 11;

    /// Compose a valid external-interrupt injection for `vector`.
    pub fn externalInterrupt(vector: u8) u32 {
        return VALID | TYPE_EXTERNAL | vector;
    }

    /// Compose a valid hardware-exception injection for `vector` that also
    /// delivers an error code (the caller writes the code into
    /// `entry_exception_ec`). Faults such as #GP push an error code, so the
    /// injection must set DELIVER_ERROR_CODE or the guest handler reads a
    /// misaligned stack frame.
    pub fn hardwareExceptionWithCode(vector: u8) u32 {
        return VALID | TYPE_HARDWARE_EXCEPTION | DELIVER_ERROR_CODE | vector;
    }
};

/// Guest interruptibility-state bits (SDM Vol 3C Table 24-3). A set bit blocks
/// interrupt injection until the guest clears the corresponding condition.
pub const INTERRUPTIBILITY_BLOCK_STI: u32 = 1 << 0;
pub const INTERRUPTIBILITY_BLOCK_MOV_SS: u32 = 1 << 1;
