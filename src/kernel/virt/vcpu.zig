//! The virtual CPU: VMCS allocation and initial-state programming, and the
//! VMLAUNCH/VMRESUME run loop that dispatches VM exits to a machine model. IO edge
//! — the field encodings, control math, and guest-state checks it relies on are
//! host-tested in vmcs.zig / vmxcaps.zig / vmcheck.zig.
//!
//! Interrupt model: external-interrupt
//! exiting is on and interrupts are NOT acknowledged on exit, so a host interrupt
//! aimed at this core forces a VM exit and stays pending; the loop then opens an
//! interrupt window (irqRestore) to let it deliver through the normal IDT before
//! resuming the guest. GS base needs no manual save/restore: the VMCS host-state
//! HOST_GS_BASE is written once with this core's per-CPU block, valid forever
//! because vCPU tasks are pinned and never migrate.

const cpu = @import("../cpu/cpu.zig");
const pmm = @import("../memory/pmm.zig");
const percpu = @import("../sched/percpu.zig");
const tsc = @import("../cpu/tsc.zig");
const klog = @import("../debug/klog.zig");
const gdt = @import("../cpu/gdt.zig");
const vmcs = @import("vmcs.zig");
const vmcheck = @import("vmcheck.zig");
const vmxcaps = @import("vmxcaps.zig");
const vmxasm = @import("vmxasm.zig");
const exitinfo = @import("exitinfo.zig");
const vmx = @import("vmx.zig");
const vmsr = @import("vmsr.zig");
const msrarea = @import("msrarea.zig");
const linuxload = @import("linuxload.zig");
const vfpu = @import("vfpu.zig");

/// The guest general-purpose registers, saved/restored by vmentry.asm. The field
/// ORDER and offsets must match vmentry.asm's R_* defines exactly.
pub const GuestRegs = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    rbp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
};

extern fn vmxEnter(regs: *GuestRegs, launched: bool, fpu: *vfpu.FpuSwap) u64;

/// What the machine model tells the run loop to do after handling an exit.
pub const Action = enum {
    /// Enter the guest again.
    resume_guest,
    /// The guest is idle (it executed HLT waiting for an interrupt). End the run
    /// slice so the driver can wait however suits its build — halting the core on
    /// SMP, returning to the desktop frame on the single-core build — instead of
    /// spinning through HLT exits.
    pause,
    /// The guest is finished; tear it down.
    shutdown,
};

/// The exit-handling callbacks the machine model supplies. `ctx` is the model's
/// own state pointer, passed back to every callback.
pub const MachineOps = struct {
    cpuid: *const fn (ctx: *anyopaque, vcpu: *Vcpu) Action,
    hlt: *const fn (ctx: *anyopaque, vcpu: *Vcpu) Action,
    io: *const fn (ctx: *anyopaque, vcpu: *Vcpu, info: exitinfo.IoInfo) Action,
    rdmsr: *const fn (ctx: *anyopaque, vcpu: *Vcpu, msr: u32) Action,
    wrmsr: *const fn (ctx: *anyopaque, vcpu: *Vcpu, msr: u32, value: u64) Action,
    mmio: *const fn (ctx: *anyopaque, vcpu: *Vcpu, gpa: u64, v: exitinfo.EptViolation) Action,
    /// Peek the highest-priority vector to inject when the guest is interruptible,
    /// or null when nothing is pending. Non-destructive — the vector is retired
    /// only by a following `commitInterrupt`, so a vector the guest cannot take
    /// yet is re-offered rather than lost.
    pollInterrupt: *const fn (ctx: *anyopaque, vcpu: *Vcpu) ?u8,
    /// The vCPU just injected the vector `pollInterrupt` last returned: retire it
    /// from its source (8259 INTA, or local-APIC IRR→ISR) so it is not offered
    /// again until the guest's EOI.
    commitInterrupt: *const fn (ctx: *anyopaque, vcpu: *Vcpu) void,
    /// Checked once per loop iteration, before entering the guest: true stops the
    /// guest at this exit boundary. This is what makes a shutdown GRACEFUL — the
    /// guest is never abandoned part-way through an instruction, only between
    /// them, with its full state resident in the VMCS the teardown then releases.
    stopRequested: *const fn (ctx: *anyopaque) bool,
};

// Guest segment access-rights values (SDM Vol 3C Table 24-2).
/// CR4.VMXE (SDM Vol 3C §23.8) — the bit the host keeps and the guest never sees.
const CR4_VMXE: u64 = 1 << 13;

/// IA32_EFER.LMA (SDM Vol 3A §2.2.1) — "long mode active". Hardware derives it
/// from CR0.PG and EFER.LME, so it is how the hypervisor reads back the mode a
/// guest put itself in without any instruction it could have trapped.
const EFER_LMA: u64 = 1 << 10;
/// IA32_EFER.LME — "long mode enable", the guest's own request for 64-bit mode.
const EFER_LME: u64 = 1 << 8;
/// CR0.PG — paging enable. With LME it is the whole of what LMA is derived from.
const CR0_PG: u64 = 1 << 31;

const AR_CODE64: u32 = 0xA09B; // present, code, S, L=1, D=0, G
const AR_DATA: u32 = 0xC093; // present, data r/w, S, DB, G
const AR_LDTR_UNUSABLE: u32 = 0x1_0000; // unusable bit
const AR_TR_BUSY64: u32 = 0x8B; // present, system, 64-bit busy TSS

const VMCS_LINK_NONE: u64 = ~@as(u64, 0);
const RFLAGS_IF: u64 = 1 << 9; // interrupt-enable flag

// Layout of the two MSR-load areas inside the vCPU's one MSR-area frame. The
// VM-entry MSR-load area (guest values) and the VM-exit MSR-load area (host values
// to restore) each hold one 16-byte entry per auto MSR; both offsets are 16-byte
// aligned as the CPU requires, trivially so inside a 4 KiB-aligned frame.
const AUTO_COUNT: usize = vmsr.AUTO_MSRS.len;
const ENTRY_LOAD_OFFSET: usize = 0;
const EXIT_LOAD_OFFSET: usize = AUTO_COUNT * msrarea.ENTRY_SIZE;
/// The VM-exit MSR-STORE area: where the CPU writes the guest's live values on
/// every exit. Required, not optional — `SWAPGS` changes IA32_KERNEL_GS_BASE
/// with no WRMSR to trap, so without this area the guest's swapped value is
/// lost at the next exit and the stale entry-load copy is restored on entry.
/// The guest's next `swapgs` then installs a GS base that is not its per-CPU
/// base, and every `%gs:`-relative access — `smp_processor_id()`,
/// `preempt_count` — reads garbage. That is a guest that cannot make progress,
/// which is exactly how it presents: an early `delay_tsc` that re-arms forever
/// because the CPU it thinks it is on keeps changing.
const EXIT_STORE_OFFSET: usize = 2 * AUTO_COUNT * msrarea.ENTRY_SIZE;

comptime {
    // All three blocks live in the one MSR-area frame; a future MSR added to
    // AUTO_MSRS must not silently walk off it.
    if (EXIT_STORE_OFFSET + AUTO_COUNT * msrarea.ENTRY_SIZE > pmm.FRAME_SIZE)
        @compileError("MSR areas exceed one frame — raise the allocation");
}

/// The VMCS physically loaded on each core — the hypervisor's shadow of the
/// CPU's current-VMCS pointer, by cpu index. VMLAUNCH/VMRESUME and every
/// VMREAD/VMWRITE operate on whatever VMCS is CURRENT, not on any particular
/// vCPU: two vCPU tasks preempted mid-slice on one core alternate their loads,
/// so each must reconcile this shadow with its own VMCS before touching guest
/// state (ensureCurrentLocked) or it reads and corrupts its sibling's guest.
/// Written only with interrupts masked, so the shadow and the CPU's pointer
/// change as one.
var core_vmcs: [percpu.MAX_CPUS]u64 = .{0} ** percpu.MAX_CPUS;

/// This core's slot in `core_vmcs`: the scheduler's cpu index once per-CPU
/// state is live, else 0 (the single-core build pumps every guest on core 0
/// with no per-CPU block).
fn coreSlot() u32 {
    return if (percpu.selfLive()) percpu.index() else 0;
}

pub const Vcpu = struct {
    regs: GuestRegs = .{},
    /// The x87/SSE files swapped around every VM transition. The guest starts
    /// with the register file a real processor has at reset.
    fpu: vfpu.FpuSwap = .{ .host = vfpu.FpuArea.atReset(), .guest = vfpu.FpuArea.atReset() },
    vmcs_pa: u64 = 0,
    msr_area_pa: u64 = 0, // frame holding the VM-entry/exit MSR-load areas
    launched: bool = false,
    exits: u64 = 0,
    /// The last exit's basic reason and guest RIP — kept so a progress trace can
    /// say what a silent guest is actually doing (test-hooks builds read it).
    last_exit_reason: u64 = 0,
    last_exit_rip: u64 = 0,
    /// Guest RSP at the last exit — with the stack it names the CALLER of a
    /// spinning function, which is what a stuck early boot is diagnosed by.
    last_exit_rsp: u64 = 0,
    /// Per-reason exit counts (basic exit reasons are < 64). THE ranking that
    /// says where a guest's virtualization overhead actually goes — every
    /// performance fix starts by reading this, not by guessing.
    exit_counts: [64]u64 = .{0} ** 64,
    int_window_open: bool = false, // interrupt-window-exiting currently requested
    vmx_faults: u64 = 0, // VMREAD/VMWRITE failures on the exit path — must stay 0
    /// Times this vCPU found another guest's VMCS current on its core and
    /// re-loaded its own (ensureCurrentLocked). Nonzero simply means two vCPU
    /// tasks shared a core and preemption interleaved them — expected then,
    /// but every count is an alias that would have corrupted a guest unseen.
    vmcs_reloads: u64 = 0,
    /// The VM-entry controls as last written, kept so `trackGuestMode` can flip
    /// ENTRY_IA32E_MODE_GUEST without re-deriving the whole field (and without a
    /// VMREAD) every time the guest changes paging mode.
    entry_ctls: u32 = 0,
    /// How many times the guest's 64-bit-mode entry control had to be re-aimed.
    /// Non-zero is normal and expected — it is a kernel switching paging modes,
    /// twice per boot for the decompressor trampoline.
    mode_switches: u64 = 0,
    /// The CR0 bits this hypervisor owns on the guest's behalf (the VMX must-be-1
    /// bits unrestricted-guest does not exempt), as written into the CR0
    /// guest/host mask. Kept so the CR-write emulation can re-apply exactly them.
    cr0_pinned: u64 = 0,

    /// Allocate and clear a VMCS and the MSR-load-area frame for this vCPU (call on
    /// the core that will run it). Owner of both frames; `deinit` is their release
    /// path. On any failure both allocations are unwound and `self` is left clear.
    pub fn initVmcs(self: *Vcpu) !void {
        const region = pmm.alloc() orelse return error.NoVmcs;
        errdefer pmm.free(region);
        // ZERO THE PAGE FIRST. The frame allocator hands out memory as the last
        // user left it, and a VMCS field this code never writes keeps whatever was
        // there — a stale CR3-target count or MSR-store count is all it takes for
        // VM entry to refuse with "invalid control field" and name nothing. The
        // architecture calls the region's contents undefined until written, so
        // starting from zero is the only defined footing.
        @memset(@as([*]u8, @ptrFromInt(region))[0..pmm.FRAME_SIZE], 0);
        @as(*volatile u32, @ptrFromInt(region)).* = vmxcaps.revisionId(vmx.capabilities().basic);
        const msr_region = pmm.alloc() orelse return error.NoMsrArea;
        errdefer pmm.free(msr_region);
        // Same for the MSR-load areas: the entries past the ones in use are read
        // by nothing, but an area that starts as anything but zero is a trap for
        // the next person to raise a count.
        @memset(@as([*]u8, @ptrFromInt(msr_region))[0..pmm.FRAME_SIZE], 0);
        try vmxasm.vmclear(region);
        self.vmcs_pa = region;
        self.msr_area_pa = msr_region;
        errdefer {
            self.vmcs_pa = 0;
            self.msr_area_pa = 0;
        }
        try self.makeCurrent();
    }

    /// Release the VMCS and MSR-area frames back to the frame allocator. Idempotent:
    /// a vCPU whose `initVmcs` never ran (both fields zero) frees nothing.
    ///
    /// VMCLEAR first: while a VMCS is current on a core the CPU may hold parts of
    /// it in an implementation-specific cache, and VMCLEAR is what flushes that
    /// and drops the current-VMCS pointer (SDM Vol 3C §24.11.1). Handing the frame
    /// back to the allocator without it would let the next owner of that page —
    /// another guest's RAM, a DMA ring — be written by the CPU's cached copy.
    /// Must run on the core the vCPU ran on, which owns the teardown.
    pub fn deinit(self: *Vcpu) void {
        if (self.vmcs_pa != 0) {
            vmxasm.vmclear(self.vmcs_pa) catch self.noteVmxFault();
            // VMCLEAR dropped the CPU's current-VMCS pointer; the shadow must
            // fall with it or a later sibling load would be judged against a
            // VMCS that no longer exists.
            const if_was = cpu.irqSave();
            if (core_vmcs[coreSlot()] == self.vmcs_pa) core_vmcs[coreSlot()] = 0;
            cpu.irqRestore(if_was);
        }
        if (self.msr_area_pa != 0) pmm.free(self.msr_area_pa);
        if (self.vmcs_pa != 0) pmm.free(self.vmcs_pa);
        self.msr_area_pa = 0;
        self.vmcs_pa = 0;
        self.launched = false;
    }

    /// Make this vCPU's VMCS the current one on the calling core. Cheap and
    /// required before every run slice: a core that hosts more than one guest
    /// (the single-core build pumps them all from the desktop frame) alternates
    /// between VMCSs, and the guest's launch state travels with the VMCS, so the
    /// following entry still picks VMRESUME correctly.
    pub fn makeCurrent(self: *Vcpu) !void {
        const if_was = cpu.irqSave();
        defer cpu.irqRestore(if_was);
        try vmxasm.vmptrld(self.vmcs_pa);
        core_vmcs[coreSlot()] = self.vmcs_pa;
    }

    /// Reconcile the CPU's current-VMCS pointer with this vCPU — interrupts
    /// must be masked. Between two of this task's VMCS accesses the scheduler
    /// may have run a sibling vCPU task on this core, whose load displaced
    /// ours; one shadow compare catches that, and the re-load is counted
    /// (vmcs_reloads) — an alias fixed silently would hide that two guests are
    /// contending for one core.
    fn ensureCurrentLocked(self: *Vcpu) !void {
        if (core_vmcs[coreSlot()] == self.vmcs_pa) return;
        try vmxasm.vmptrld(self.vmcs_pa);
        core_vmcs[coreSlot()] = self.vmcs_pa;
        self.vmcs_reloads += 1;
    }

    /// Program the VMCS from the loader's entry state and the guest's EPT pointer.
    /// Must run with the VMCS current on this core (after initVmcs).
    pub fn setup(self: *Vcpu, es: linuxload.EntryState, eptp: u64) !void {
        const caps = vmx.capabilities();

        try self.writeControls(caps);
        try self.writeHostState();
        try self.writeGuestState(es);
        // RSI carries the boot_params pointer into the kernel — the 64-bit boot
        // protocol's one register argument. It is not a VMCS field: general
        // registers are restored from `regs` by the entry stub, so the loader's
        // value has to be planted there or the kernel reads its boot_params from
        // address zero, sizes its stack from a zero init_size, and triple-faults
        // on the first push.
        self.regs.rsi = es.rsi;
        try self.writeMsrAreas();
        try vmxasm.vmwrite(.ept_pointer, eptp);
        try vmxasm.vmwrite(.vmcs_link_pointer, VMCS_LINK_NONE);
    }

    /// Fill and wire all three MSR areas for the MSRs with no VMCS guest-state
    /// field (SYSCALL STAR/LSTAR/CSTAR/FMASK and KERNEL_GS_BASE):
    ///  - VM-entry LOAD: the guest copy the CPU loads on entry (boot value zero;
    ///    a trapped guest WRMSR updates it via `setAutoMsr`, and every exit
    ///    refreshes it from the store area below).
    ///  - VM-exit LOAD: this core's host copy, reloaded on exit so guest values
    ///    never leak into the host's own SYSCALL/GS state.
    ///  - VM-exit STORE: where the CPU writes the guest's LIVE values on exit.
    ///    `SWAPGS` mutates KERNEL_GS_BASE with no WRMSR to trap, so this is the
    ///    only way the hypervisor learns the guest's real value (see
    ///    EXIT_STORE_OFFSET for what breaks without it).
    /// Must run with the VMCS current.
    fn writeMsrAreas(self: *Vcpu) !void {
        const entry = self.entryLoad();
        const exit = self.exitLoad();
        const store = self.exitStore();
        for (vmsr.AUTO_MSRS, 0..) |msr, i| {
            entry[i] = .{ .index = msr, .data = 0 };
            exit[i] = .{ .index = msr, .data = cpu.rdmsr(msr) };
            store[i] = .{ .index = msr, .data = 0 };
        }
        try vmxasm.vmwrite(.entry_msr_load_addr, self.msr_area_pa + ENTRY_LOAD_OFFSET);
        try vmxasm.vmwrite(.entry_msr_load_count, @as(u64, AUTO_COUNT));
        try vmxasm.vmwrite(.exit_msr_load_addr, self.msr_area_pa + EXIT_LOAD_OFFSET);
        try vmxasm.vmwrite(.exit_msr_load_count, @as(u64, AUTO_COUNT));
        try vmxasm.vmwrite(.exit_msr_store_addr, self.msr_area_pa + EXIT_STORE_OFFSET);
        try vmxasm.vmwrite(.exit_msr_store_count, @as(u64, AUTO_COUNT));
    }

    /// Carry the guest values the CPU stored at this exit into the entry-load
    /// area, so the next entry restores what the guest actually had rather than
    /// the last value it wrote through a trapped WRMSR. Called once per exit,
    /// before any host code can touch these MSRs. No allocation, no VMCS
    /// access — two small array walks over memory this vCPU owns.
    fn adoptStoredMsrs(self: *Vcpu) void {
        const entry = self.entryLoad();
        const store = self.exitStore();
        for (store, 0..) |s, i| entry[i].data = s.data;
    }

    /// Re-aim the VM-entry "IA-32e mode guest" control at the mode the guest is
    /// ACTUALLY in, reading the EFER the CPU just saved. VM entry requires the
    /// control and the guest's IA32_EFER.LMA to agree exactly, in both
    /// directions, so a guest that has left long mode cannot be re-entered under
    /// a control that still claims 64-bit — the entry fails outright and the
    /// guest is gone with no fault to diagnose.
    ///
    /// That is not a corner case. Every Linux before ~6.1 leaves long mode on
    /// purpose during its decompressor's 32-bit trampoline; a host timer tick
    /// landing in that window is an exit taken in 32-bit protected mode. Called
    /// once per exit rather than once per entry: the mode at the next entry is
    /// the mode at this exit, and the check costs one VMREAD against an exit's
    /// thousands of cycles — a VMWRITE only on the rare pass that changes it.
    fn trackGuestMode(self: *Vcpu) void {
        const efer = vmxasm.vmread(.guest_ia32_efer) catch return self.noteVmxFault();
        const want: u32 = if (efer & EFER_LMA != 0) vmcs.ENTRY_IA32E_MODE_GUEST else 0;
        if (self.entry_ctls & vmcs.ENTRY_IA32E_MODE_GUEST == want) return;
        const next = (self.entry_ctls & ~vmcs.ENTRY_IA32E_MODE_GUEST) | want;
        vmxasm.vmwrite(.entry_ctls, next) catch return self.noteVmxFault();
        self.entry_ctls = next;
        self.mode_switches += 1;
    }

    fn entryLoad(self: *Vcpu) []msrarea.Entry {
        return @as([*]msrarea.Entry, @ptrFromInt(self.msr_area_pa + ENTRY_LOAD_OFFSET))[0..AUTO_COUNT];
    }

    fn exitLoad(self: *Vcpu) []msrarea.Entry {
        return @as([*]msrarea.Entry, @ptrFromInt(self.msr_area_pa + EXIT_LOAD_OFFSET))[0..AUTO_COUNT];
    }

    fn exitStore(self: *Vcpu) []msrarea.Entry {
        return @as([*]msrarea.Entry, @ptrFromInt(self.msr_area_pa + EXIT_STORE_OFFSET))[0..AUTO_COUNT];
    }

    /// The guest value of the auto MSR at `slot` (what the next VM entry loads and a
    /// guest RDMSR reads back).
    pub fn autoMsr(self: *Vcpu, slot: usize) u64 {
        return self.entryLoad()[slot].data;
    }

    /// Store `value` as the guest auto MSR at `slot`: the next VM entry loads it
    /// into the real MSR, so a guest WRMSR to a SYSCALL/KERNEL_GS_BASE MSR persists.
    pub fn setAutoMsr(self: *Vcpu, slot: usize, value: u64) void {
        self.entryLoad()[slot].data = value;
    }

    /// The saved guest register an x86 instruction encoding names — the encoding
    /// order (0=RAX, 1=RCX, 2=RDX, 3=RBX, 4=RSP, 5=RBP, 6=RSI, 7=RDI, 8..15=R8..R15),
    /// which is NOT the order `GuestRegs` stores them in. Index 4 yields null:
    /// RSP is guest state in the VMCS, not in this register file, so a caller
    /// that must serve it reads `.guest_rsp` instead.
    pub fn gpr(self: *Vcpu, index: u4) ?*u64 {
        return switch (index) {
            0 => &self.regs.rax,
            1 => &self.regs.rcx,
            2 => &self.regs.rdx,
            3 => &self.regs.rbx,
            4 => null,
            5 => &self.regs.rbp,
            6 => &self.regs.rsi,
            7 => &self.regs.rdi,
            8 => &self.regs.r8,
            9 => &self.regs.r9,
            10 => &self.regs.r10,
            11 => &self.regs.r11,
            12 => &self.regs.r12,
            13 => &self.regs.r13,
            14 => &self.regs.r14,
            15 => &self.regs.r15,
        };
    }

    /// Read a VMCS field, counting a VMREAD failure. Returns null on failure so the
    /// caller declines rather than acting on unknown guest state.
    pub fn readField(self: *Vcpu, f: vmcs.Field) ?u64 {
        return vmxasm.vmread(f) catch return self.noteVmxFaultNull();
    }

    /// Write a VMCS field, counting a VMWRITE failure.
    pub fn writeField(self: *Vcpu, f: vmcs.Field, value: u64) void {
        vmxasm.vmwrite(f, value) catch self.noteVmxFault();
    }

    fn writeControls(self: *Vcpu, caps: *const vmxcaps.CapMsrs) !void {
        const pin = try vmxcaps.adjustControls(caps.pinbased, vmcs.PIN_EXTERNAL_INTERRUPT_EXITING | vmcs.PIN_NMI_EXITING, 0);
        try vmxasm.vmwrite(.pin_ctls, pin);

        // Unconditional I/O exiting (trap the serial port), HLT exiting, MSR bitmaps
        // off (so every RDMSR/WRMSR exits to the model), and secondary controls on.
        const proc = try vmxcaps.adjustControls(caps.procbased, vmcs.PROC_HLT_EXITING | vmcs.PROC_UNCONDITIONAL_IO_EXITING | vmcs.PROC_ACTIVATE_SECONDARY, vmcs.PROC_USE_MSR_BITMAPS);
        try vmxasm.vmwrite(.proc_ctls, proc);

        // EPT, plus UNRESTRICTED GUEST — the control that lets the guest run with
        // paging off. Without it VMX pins CR0.PG to 1, and Linux's decompressor,
        // which drops paging in a 32-bit trampoline and has no IDT, turns the
        // resulting #GP into a triple fault. Required, not optional: UNRESTRICTED
        // GUEST shares its vintage with EPT, so a CPU offering one offers the other.
        const proc2 = try vmxcaps.adjustControls(caps.procbased2, vmcs.PROC2_ENABLE_EPT | vmcs.PROC2_UNRESTRICTED_GUEST, 0);
        try vmxasm.vmwrite(.proc_ctls2, proc2);

        // Host returns to 64-bit mode and reloads its full EFER on exit, so the
        // guest's EFER (NXE/SCE) cannot leak into host paging. SAVE_IA32_EFER
        // keeps the guest's own EFER field current: the guest's LMA follows its
        // CR0.PG, and an entry that reloaded a stale EFER would put the guest
        // back in a mode it had left.
        const exit_ctls = try vmxcaps.adjustControls(caps.exit, vmcs.EXIT_HOST_ADDR_SPACE_SIZE | vmcs.EXIT_LOAD_IA32_EFER | vmcs.EXIT_SAVE_IA32_EFER, 0);
        try vmxasm.vmwrite(.exit_ctls, exit_ctls);

        // Guest enters 64-bit mode; load its EFER from the guest-state field.
        // IA32E_MODE_GUEST is not fixed for the guest's whole life — it must
        // mirror the guest's IA32_EFER.LMA at every entry, which `trackGuestMode`
        // maintains once the guest starts changing modes.
        const entry_ctls = try vmxcaps.adjustControls(caps.entry, vmcs.ENTRY_IA32E_MODE_GUEST | vmcs.ENTRY_LOAD_IA32_EFER, 0);
        try vmxasm.vmwrite(.entry_ctls, entry_ctls);
        self.entry_ctls = entry_ctls;

        try vmxasm.vmwrite(.exception_bitmap, 0); // guest handles its own faults
        try vmxasm.vmwrite(.entry_interruption_info, 0);
    }

    fn writeHostState(_: *Vcpu) !void {
        try vmxasm.vmwrite(.host_cr0, cpu.readCr0());
        try vmxasm.vmwrite(.host_cr3, cpu.readCr3());
        try vmxasm.vmwrite(.host_cr4, cpu.readCr4());

        try vmxasm.vmwrite(.host_cs_sel, gdt.SEL_CODE);
        try vmxasm.vmwrite(.host_ss_sel, gdt.SEL_DATA);
        try vmxasm.vmwrite(.host_ds_sel, gdt.SEL_DATA);
        try vmxasm.vmwrite(.host_es_sel, gdt.SEL_DATA);
        try vmxasm.vmwrite(.host_fs_sel, 0);
        try vmxasm.vmwrite(.host_gs_sel, 0);
        try vmxasm.vmwrite(.host_tr_sel, gdt.SEL_TSS);

        try vmxasm.vmwrite(.host_fs_base, cpu.rdmsr(vmxcaps.IA32_FS_BASE));
        try vmxasm.vmwrite(.host_gs_base, cpu.rdmsr(vmxcaps.IA32_GS_BASE));
        try vmxasm.vmwrite(.host_ia32_efer, cpu.rdmsr(vmxcaps.IA32_EFER)); // reloaded on exit
        try vmxasm.vmwrite(.host_tr_base, gdt.tssBase());
        try vmxasm.vmwrite(.host_gdtr_base, cpu.sgdt().base);
        try vmxasm.vmwrite(.host_idtr_base, cpu.sidt().base);
        // host_rsp / host_rip are written by vmentry.asm on each entry.
    }

    fn writeGuestState(self: *Vcpu, es: linuxload.EntryState) !void {
        const caps = vmx.capabilities();
        // Control registers, forced legal by the VMX fixed bits. The guest's CR0
        // uses the unrestricted-guest rule (see writeControls): PE and PG are the
        // guest's own, so a kernel may leave protected mode or turn paging off.
        try vmxasm.vmwrite(.guest_cr0, vmxcaps.applyGuestCr0Fixed(es.cr0, caps.cr0_fixed0, caps.cr0_fixed1));
        try vmxasm.vmwrite(.guest_cr3, es.cr3);
        try vmxasm.vmwrite(.guest_cr4, vmxcaps.applyCrFixed(es.cr4, caps.cr4_fixed0, caps.cr4_fixed1));
        // CR4.VMXE has to stay set for as long as the processor is in VMX
        // operation, and the guest must neither see it nor be able to clear it:
        // Linux's 64-bit entry path narrows CR4 down to a couple of bits within
        // the first hundred instructions, and a write that really cleared VMXE
        // faults — with no guest IDT yet, straight to a triple fault. Owning that
        // one bit (set in the mask, clear in the read shadow) keeps the hardware
        // requirement and the guest's own picture of CR4 both true, and costs no
        // exit: a write matching the shadow in every masked bit does not exit,
        // and the masked bit keeps its real value. Every other bit stays the
        // guest's own.
        //
        // CR0 is owned the same way, for the bits VMX pins that unrestricted
        // guest does not exempt — CR0.NE on every current part. Linux's
        // decompressor re-enables paging with a flat `CR0 = PG|PE`, NE clear;
        // left to the guest that write raises a #GP inside a trampoline with no
        // IDT behind it. Masked, it becomes a handled exit (`emulateCrWrite`).
        // Twice a boot, against a shadow that keeps telling the guest the truth
        // about what it wrote.
        self.cr0_pinned = vmxcaps.guestCr0PinnedBits(caps.cr0_fixed0);
        try vmxasm.vmwrite(.cr0_guest_host_mask, self.cr0_pinned);
        try vmxasm.vmwrite(.cr4_guest_host_mask, CR4_VMXE);
        try vmxasm.vmwrite(.cr0_read_shadow, es.cr0);
        try vmxasm.vmwrite(.cr4_read_shadow, es.cr4 & ~CR4_VMXE);

        try vmxasm.vmwrite(.guest_ia32_efer, es.efer);
        try vmxasm.vmwrite(.guest_rflags, 0x2); // reserved bit 1 set, IF clear
        try vmxasm.vmwrite(.guest_rip, es.rip);
        try vmxasm.vmwrite(.guest_rsp, es.rsp);
        try vmxasm.vmwrite(.guest_dr7, 0x400); // power-on default

        try writeSegment(.guest_cs_sel, .guest_cs_base, .guest_cs_limit, .guest_cs_ar, es.cs_sel, 0, 0xFFFFF, AR_CODE64);
        try writeSegment(.guest_ss_sel, .guest_ss_base, .guest_ss_limit, .guest_ss_ar, es.ds_sel, 0, 0xFFFFF, AR_DATA);
        try writeSegment(.guest_ds_sel, .guest_ds_base, .guest_ds_limit, .guest_ds_ar, es.ds_sel, 0, 0xFFFFF, AR_DATA);
        try writeSegment(.guest_es_sel, .guest_es_base, .guest_es_limit, .guest_es_ar, es.ds_sel, 0, 0xFFFFF, AR_DATA);
        try writeSegment(.guest_fs_sel, .guest_fs_base, .guest_fs_limit, .guest_fs_ar, es.ds_sel, 0, 0xFFFFF, AR_DATA);
        try writeSegment(.guest_gs_sel, .guest_gs_base, .guest_gs_limit, .guest_gs_ar, es.ds_sel, 0, 0xFFFFF, AR_DATA);
        try writeSegment(.guest_ldtr_sel, .guest_ldtr_base, .guest_ldtr_limit, .guest_ldtr_ar, 0, 0, 0, AR_LDTR_UNUSABLE);
        // A minimal usable busy 64-bit TSS so the guest-state TR check passes until
        // the guest installs its own.
        try writeSegment(.guest_tr_sel, .guest_tr_base, .guest_tr_limit, .guest_tr_ar, 0, 0, 0xFFFF, AR_TR_BUSY64);

        try vmxasm.vmwrite(.guest_gdtr_base, es.gdtr_base);
        try vmxasm.vmwrite(.guest_gdtr_limit, es.gdtr_limit);
        try vmxasm.vmwrite(.guest_idtr_base, 0);
        try vmxasm.vmwrite(.guest_idtr_limit, 0xFFFF);

        try vmxasm.vmwrite(.guest_interruptibility, 0);
        try vmxasm.vmwrite(.guest_activity_state, 0); // active
    }

    /// Re-derive the guest's IA32_EFER.LMA from the CR0 it is being given, as a
    /// real MOV to CR0 would: LMA is set exactly when paging is on and long mode
    /// is enabled. Returns false if the VMCS would not cooperate, so the caller
    /// can decline rather than leave the guest in a state entry will reject.
    fn syncLongModeActive(self: *Vcpu, cr0: u64) bool {
        const efer = vmxasm.vmread(.guest_ia32_efer) catch {
            self.noteVmxFault();
            return false;
        };
        const active = (cr0 & CR0_PG != 0) and (efer & EFER_LME != 0);
        const next = if (active) efer | EFER_LMA else efer & ~EFER_LMA;
        if (next == efer) return true;
        vmxasm.vmwrite(.guest_ia32_efer, next) catch {
            self.noteVmxFault();
            return false;
        };
        return true;
    }

    /// Emulate the guest's `MOV to CR0`/`MOV to CR4` that this exit interrupted.
    ///
    /// The guest owns every bit of these registers except the few the hardware
    /// pins while in VMX operation (`cr0_pinned`, and CR4.VMXE). Those bits stay
    /// at their required value in the REAL register, while the read shadow keeps
    /// the value the guest believes it wrote — so the guest's own picture of its
    /// control registers is never a lie, and the hardware requirement never
    /// breaks. A write agreeing with the shadow on every owned bit does not exit
    /// at all, so this runs a couple of times per guest boot.
    ///
    /// Returns false for an access this does not model (a CR the mask never
    /// selects, or CLTS/LMSW, which no 64-bit Linux issues); the caller then ends
    /// the guest rather than resuming it past an instruction it did not perform.
    fn emulateCrWrite(self: *Vcpu, acc: exitinfo.CrAccess) bool {
        if (acc.kind != .mov_to_cr) return false;
        const src = self.gpr(acc.gp_register) orelse return false;
        const value = src.*;
        const caps = vmx.capabilities();
        // Handler context — same VMCS-displacement hazard as skipInstruction:
        // these writes must land in THIS guest's VMCS, atomically with the
        // reconcile.
        const if_was = cpu.irqSave();
        defer cpu.irqRestore(if_was);
        self.ensureCurrentLocked() catch return false;
        switch (acc.cr) {
            0 => {
                vmxasm.vmwrite(.guest_cr0, vmxcaps.applyGuestCr0Fixed(value, caps.cr0_fixed0, caps.cr0_fixed1)) catch return false;
                vmxasm.vmwrite(.cr0_read_shadow, value) catch return false;
                // A real MOV to CR0 does more than write CR0: the processor
                // re-derives IA32_EFER.LMA from CR0.PG and EFER.LME. Emulating
                // the write means owning that side effect too, and the guest
                // state VM entry accepts is exactly the state where CR0.PG,
                // EFER.LMA and the entry control all agree. Leave LMA stale and
                // the very next entry fails "invalid guest state" — which is what
                // a Linux decompressor sees the instant it re-enables paging.
                if (!self.syncLongModeActive(value)) return false;
                self.trackGuestMode();
            },
            4 => {
                vmxasm.vmwrite(.guest_cr4, vmxcaps.applyCrFixed(value, caps.cr4_fixed0, caps.cr4_fixed1)) catch return false;
                vmxasm.vmwrite(.cr4_read_shadow, value & ~CR4_VMXE) catch return false;
            },
            else => return false,
        }
        self.skipInstruction();
        return true;
    }

    /// Advance guest RIP past the instruction that caused this exit. Handler
    /// context: interrupts are open between exits, so a sibling vCPU task may
    /// have displaced this guest's VMCS — reconcile before the RIP rewrite
    /// (against the wrong VMCS it would corrupt the sibling's guest), and mask
    /// so the reconcile cannot be displaced again mid-write.
    pub fn skipInstruction(self: *Vcpu) void {
        const if_was = cpu.irqSave();
        defer cpu.irqRestore(if_was);
        self.ensureCurrentLocked() catch return self.noteVmxFault();
        const len = vmxasm.vmread(.exit_instruction_len) catch return self.noteVmxFault();
        const rip = vmxasm.vmread(.guest_rip) catch return self.noteVmxFault();
        vmxasm.vmwrite(.guest_rip, rip + len) catch self.noteVmxFault();
    }

    /// Inject an external (maskable) interrupt on the next entry (SDM §24.8.3).
    pub fn injectInterrupt(self: *Vcpu, vector: u8) void {
        vmxasm.vmwrite(.entry_interruption_info, vmcs.EntryIntrInfo.externalInterrupt(vector)) catch self.noteVmxFault();
    }

    /// Inject a hardware exception carrying error code `code` on the next entry.
    /// A fault such as #GP pushes an error code, so the injection must supply one
    /// or the guest handler reads a misaligned exception frame.
    pub fn injectException(self: *Vcpu, vector: u8, code: u32) void {
        // Handler context — same VMCS-displacement hazard as skipInstruction.
        const if_was = cpu.irqSave();
        defer cpu.irqRestore(if_was);
        self.ensureCurrentLocked() catch return self.noteVmxFault();
        vmxasm.vmwrite(.entry_exception_ec, code) catch return self.noteVmxFault();
        vmxasm.vmwrite(.entry_interruption_info, vmcs.EntryIntrInfo.hardwareExceptionWithCode(vector)) catch self.noteVmxFault();
    }

    /// Whether the guest can accept an interrupt now (IF set, no STI/MOV-SS shadow).
    /// A VMREAD failure conservatively reports "not interruptible" so a vector is
    /// never injected against unknown guest state.
    pub fn interruptible(self: *Vcpu) bool {
        const rflags = vmxasm.vmread(.guest_rflags) catch return self.noteVmxFaultFalse();
        const block = vmxasm.vmread(.guest_interruptibility) catch return self.noteVmxFaultFalse();
        return (rflags & RFLAGS_IF) != 0 and (block & (vmcs.INTERRUPTIBILITY_BLOCK_STI | vmcs.INTERRUPTIBILITY_BLOCK_MOV_SS)) == 0;
    }

    /// Request (or clear) an interrupt-window exit so a pending interrupt can be
    /// injected as soon as the guest is interruptible.
    pub fn setInterruptWindow(self: *Vcpu, want: bool) void {
        if (self.int_window_open == want) return;
        var proc = vmxasm.vmread(.proc_ctls) catch return self.noteVmxFault();
        if (want) proc |= vmcs.PROC_INTERRUPT_WINDOW_EXITING else proc &= ~@as(u64, vmcs.PROC_INTERRUPT_WINDOW_EXITING);
        vmxasm.vmwrite(.proc_ctls, proc) catch return self.noteVmxFault();
        self.int_window_open = want;
    }

    fn noteVmxFault(self: *Vcpu) void {
        self.vmx_faults += 1;
    }

    fn noteVmxFaultFalse(self: *Vcpu) bool {
        self.vmx_faults += 1;
        return false;
    }

    fn noteVmxFaultNull(self: *Vcpu) ?u64 {
        self.vmx_faults += 1;
        return null;
    }

    /// Why a `pump` slice ended.
    pub const Pump = enum {
        /// The slice ran out with the guest still alive — call `pump` again to
        /// keep running it.
        yielded,
        /// The guest halted waiting for an interrupt. It is alive and will resume
        /// on the next `pump`; until then the driver should wait rather than
        /// re-enter, or the core spins through HLT exits (KRN-007).
        idle,
        /// The guest is finished: it shut itself down, its entry failed, or a stop
        /// was requested. The caller must tear it down; a further `pump` would
        /// enter an undefined guest.
        finished,
    };

    /// Run the guest until the TSC reaches `deadline_tsc` — the VMLAUNCH/VMRESUME
    /// loop, bounded in TIME so the caller keeps control. Returns `.finished` when
    /// the machine model asks to shut down, a VM entry fails, or a stop is
    /// requested; `.yielded` when the deadline passes with the guest still alive.
    ///
    /// A time bound, not an exit count, because that is what both callers actually
    /// need: "do not hold this CPU past this instant". It is what lets one loop
    /// body serve both builds — the SMP vCPU task owns its core and takes long
    /// slices, while the single-core build takes short ones between servicing
    /// input and the display, so a guest can never delay a frame (PERF-003). The
    /// deadline is checked once per exit, which costs one TSC read against a VM
    /// exit's thousand-odd cycles.
    ///
    /// The VMCS must be current on this core — call `makeCurrent` first.
    pub fn pump(self: *Vcpu, ops: *const MachineOps, ctx: *anyopaque, deadline_tsc: u64) Pump {
        while (tsc.rdtsc() < deadline_tsc) {
            // Stop at an exit boundary, before entering the guest again: the
            // guest's whole state stays consistent in the VMCS for teardown.
            if (ops.stopRequested(ctx)) return .finished;

            // Interrupts masked from here through the post-exit reads: the
            // preemption that displaces the current VMCS (a sibling vCPU task
            // scheduled onto this core) must not land between the reconcile
            // below and the guest-state accesses that depend on it.
            const was = cpu.irqSave();
            self.ensureCurrentLocked() catch {
                cpu.irqRestore(was);
                self.noteVmxFault();
                klog.puts("virt: could not re-load the VMCS on this core — guest ended\n");
                return .finished;
            };

            // Offer a pending interrupt before entry.
            self.serviceInterrupts(ops, ctx);

            const fail = vmxEnter(&self.regs, self.launched, &self.fpu);
            if (fail != 0) {
                cpu.irqRestore(was);
                self.reportEntryFailure();
                return .finished;
            }
            self.launched = true;
            self.exits += 1;
            const reason_raw = vmxasm.vmread(.exit_reason) catch {
                cpu.irqRestore(was);
                // The one exit that cannot be diagnosed from its reason, because
                // reading the reason is what failed. Say so: silently ending the
                // guest here is indistinguishable from a guest that halted.
                self.noteVmxFault();
                klog.puts("virt: could not read the exit reason — guest ended undiagnosed\n");
                return .finished;
            };
            // The guest's live SWAPGS-able MSRs, as the CPU just stored them:
            // adopt them before anything else so the next entry restores the
            // guest's own state (see writeMsrAreas).
            self.adoptStoredMsrs();
            // The guest may have changed paging mode since the last entry; the
            // next entry's controls must describe the mode it is in NOW.
            self.trackGuestMode();
            self.last_exit_reason = exitinfo.basicExitReason(reason_raw);
            self.last_exit_rip = vmxasm.vmread(.guest_rip) catch 0;
            self.last_exit_rsp = vmxasm.vmread(.guest_rsp) catch 0;
            self.exit_counts[self.last_exit_reason & 63] += 1;
            // Exit qualification + guest-physical address, captured while the
            // VMCS is still guaranteed current (two cheap VMREADs against a
            // thousand-cycle exit): the dispatch handlers run with interrupts
            // open below, where a preemption could displace the VMCS, and a
            // qualification read from a sibling's VMCS would route a decoded
            // access to the wrong device. Null marks a failed read, which the
            // arms that need the value turn into a shutdown.
            const qual: ?u64 = vmxasm.vmread(.exit_qualification) catch null;
            const gpa: ?u64 = vmxasm.vmread(.guest_phys_addr) catch null;
            // Open the interrupt window: any host IRQ that forced this exit (timer
            // tick, wake IPI) delivers here through the normal IDT.
            cpu.irqRestore(was);

            if (exitinfo.isEntryFailure(reason_raw)) {
                self.reportGuestStateFailure(reason_raw);
                return .finished;
            }
            switch (self.dispatch(ops, ctx, exitinfo.basicExitReason(reason_raw), qual, gpa)) {
                .resume_guest => {},
                .pause => return .idle,
                .shutdown => return .finished,
            }
        }
        return .yielded;
    }

    fn serviceInterrupts(self: *Vcpu, ops: *const MachineOps, ctx: *anyopaque) void {
        if (ops.pollInterrupt(ctx, self)) |vector| {
            if (self.interruptible()) {
                self.injectInterrupt(vector);
                ops.commitInterrupt(ctx, self); // retire the vector we just injected
                self.setInterruptWindow(false);
            } else {
                self.setInterruptWindow(true);
            }
        } else {
            self.setInterruptWindow(false);
        }
    }

    /// Route one exit to its handler. `qual`/`gpa` were read by pump while the
    /// VMCS was guaranteed current; null means the read failed, which the arms
    /// that need the value turn into a shutdown.
    fn dispatch(self: *Vcpu, ops: *const MachineOps, ctx: *anyopaque, reason: u16, qual: ?u64, gpa: ?u64) Action {
        const r: vmcs.ExitReason = @enumFromInt(reason);
        return switch (r) {
            .cpuid => ops.cpuid(ctx, self),
            .hlt => ops.hlt(ctx, self),
            .io_instruction => blk: {
                const q = qual orelse break :blk .shutdown;
                break :blk ops.io(ctx, self, exitinfo.IoInfo.decode(q));
            },
            // A write to a control register whose pinned bits this hypervisor
            // owns (see writeGuestState). Emulated here rather than in the
            // machine model: it is a property of how the VMCS is programmed, not
            // of any device the guest can see.
            .cr_access => blk: {
                const q = qual orelse break :blk .shutdown;
                const acc = exitinfo.CrAccess.decode(q);
                if (self.emulateCrWrite(acc)) break :blk .resume_guest;
                klog.puts("virt: unmodelled control-register access cr=");
                klog.putHex(acc.cr);
                klog.puts(" kind=");
                klog.putHex(@intFromEnum(acc.kind));
                klog.puts("\n");
                break :blk .shutdown;
            },
            .rdmsr => ops.rdmsr(ctx, self, @truncate(self.regs.rcx)),
            .wrmsr => ops.wrmsr(ctx, self, @truncate(self.regs.rcx), (self.regs.rdx << 32) | (self.regs.rax & 0xFFFFFFFF)),
            .ept_violation => blk: {
                const q = qual orelse break :blk .shutdown;
                const a = gpa orelse break :blk .shutdown;
                break :blk ops.mmio(ctx, self, a, exitinfo.EptViolation.decode(q));
            },
            // The interrupt window opened / an external interrupt caused the exit;
            // the IF window already let the host handle it. Re-offer on resume.
            .interrupt_window, .external_interrupt, .nmi_window => .resume_guest,
            // NMI-exiting is on, so a host NMI during the guest forces this exit
            // (the guest's own exceptions do not exit — the exception bitmap is 0).
            // Resume rather than kill the guest over a host/spurious NMI.
            .exception_nmi => .resume_guest,
            .triple_fault, .ept_misconfig => {
                // Two very different faults share this arm: a guest that faulted
                // its way to shutdown, and an EPT entry the processor could not
                // read. Say which, and where — a fatal exit with no address is
                // undiagnosable.
                klog.puts("virt: guest fatal exit reason=");
                klog.putHex(reason);
                klog.puts(" rip=");
                klog.putHex(vmxasm.vmread(.guest_rip) catch 0);
                klog.puts(" gpa=");
                klog.putHex(gpa orelse 0);
                klog.puts(" qual=");
                klog.putHex(qual orelse 0);
                klog.puts("\n");
                klog.puts("virt:   guest cr3=");
                klog.putHex(vmxasm.vmread(.guest_cr3) catch 0);
                klog.puts(" rsp=");
                klog.putHex(vmxasm.vmread(.guest_rsp) catch 0);
                klog.puts(" cr2=");
                klog.putHex(cpu.readCr2());
                klog.puts(" cr0=");
                klog.putHex(vmxasm.vmread(.guest_cr0) catch 0);
                klog.puts(" cr4=");
                klog.putHex(vmxasm.vmread(.guest_cr4) catch 0);
                klog.puts("\n");
                return .shutdown;
            },
            else => {
                klog.puts("virt: unhandled VM exit\n");
                return .shutdown;
            },
        };
    }

    fn reportEntryFailure(self: *Vcpu) void {
        _ = self;
        const err = vmxasm.instructionError();
        klog.puts("virt: VM entry failed, vm-instruction-error=");
        klog.putHex(err);
        klog.puts("\n");
        dumpEntryInputs();
    }

    /// The fields VM entry judges, as the CPU sees them, beside the capability
    /// masks that decide what is legal. "Invalid control field" names no field, so
    /// a failed entry is only diagnosable by reading back what was programmed and
    /// comparing it with what the processor allows — which is what this prints.
    fn dumpEntryInputs() void {
        const caps = vmx.capabilities();
        pair("pin ", .pin_ctls, caps.pinbased);
        pair("proc", .proc_ctls, caps.procbased);
        pair("pro2", .proc_ctls2, caps.procbased2);
        pair("exit", .exit_ctls, caps.exit);
        pair("entr", .entry_ctls, caps.entry);
        field("eptp", .ept_pointer);
        field("link", .vmcs_link_pointer);
        field("emla", .entry_msr_load_addr);
        field("emlc", .entry_msr_load_count);
        field("xmla", .exit_msr_load_addr);
        field("xmlc", .exit_msr_load_count);
        klog.puts("virt: vmx_misc=");
        klog.putHex(cpu.rdmsr(vmxcaps.IA32_VMX_MISC));
        klog.puts("\n");
    }

    fn pair(name: []const u8, f: vmcs.Field, allowed: u64) void {
        klog.puts("virt: ");
        klog.puts(name);
        klog.puts("=");
        klog.putHex(vmxasm.vmread(f) catch 0);
        klog.puts(" allowed0=");
        klog.putHex(allowed & 0xFFFFFFFF);
        klog.puts(" allowed1=");
        klog.putHex(allowed >> 32);
        klog.puts("\n");
    }

    fn field(name: []const u8, f: vmcs.Field) void {
        klog.puts("virt: ");
        klog.puts(name);
        klog.puts("=");
        klog.putHex(vmxasm.vmread(f) catch 0);
        klog.puts("\n");
    }

    fn reportGuestStateFailure(self: *Vcpu, reason_raw: u64) void {
        // Distinguish the three entry-failure reasons (invalid guest state 33,
        // MSR load 34, machine check 41) instead of always naming 33.
        klog.puts("virt: VM entry failed, exit reason=");
        klog.putHex(exitinfo.basicExitReason(reason_raw));
        // For "invalid guest state" the exit qualification is the NUMBER of the
        // check that failed (SDM Vol 3C §27.7), which is the difference between a
        // diagnosis and a guess.
        klog.puts(" failing-check=");
        klog.putHex(vmxasm.vmread(.exit_qualification) catch 0);
        klog.puts("\n");
        // The mode-consistency quartet: VM entry insists that the entry control's
        // claim about 64-bit mode, the guest's EFER.LMA, its CR0.PG and its CS.L
        // all agree. A guest mid-way through changing paging mode is exactly where
        // they stop agreeing, so print all four together.
        klog.puts("virt:   entry_ctls=");
        klog.putHex(self.entry_ctls);
        klog.puts(" efer=");
        klog.putHex(vmxasm.vmread(.guest_ia32_efer) catch 0);
        klog.puts(" cr0=");
        klog.putHex(vmxasm.vmread(.guest_cr0) catch 0);
        klog.puts(" cr4=");
        klog.putHex(vmxasm.vmread(.guest_cr4) catch 0);
        klog.puts("\n");
        klog.puts("virt:   cs_ar=");
        klog.putHex(vmxasm.vmread(.guest_cs_ar) catch 0);
        klog.puts(" ss_ar=");
        klog.putHex(vmxasm.vmread(.guest_ss_ar) catch 0);
        klog.puts(" rflags=");
        klog.putHex(vmxasm.vmread(.guest_rflags) catch 0);
        klog.puts(" rip=");
        klog.putHex(vmxasm.vmread(.guest_rip) catch 0);
        klog.puts(" mode_switches=");
        klog.putHex(self.mode_switches);
        klog.puts("\n");
    }
};

fn writeSegment(sel_f: vmcs.Field, base_f: vmcs.Field, limit_f: vmcs.Field, ar_f: vmcs.Field, sel: u16, base: u64, limit: u32, ar: u32) !void {
    try vmxasm.vmwrite(sel_f, sel);
    try vmxasm.vmwrite(base_f, base);
    try vmxasm.vmwrite(limit_f, limit);
    try vmxasm.vmwrite(ar_f, ar);
}
