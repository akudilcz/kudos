//! The virtual machine: guest RAM, a vCPU, and the emulated device set (16550
//! serial, 8259 PIC pair, 8254 timer, MC146818 clock, x2APIC), wired together as
//! the MachineOps the vCPU run loop calls on each exit. IO edge — the device
//! state machines it drives are all host-tested (uart16550/i8259/i8254/mc146818/
//! x2apic/vcpuid/vmsr); this file is the glue that decodes an exit, routes it to
//! the right model, and reflects the result back into guest registers.
//!
//! Serial bytes cross to the VM console app through the ivirt mailbox: guest THR
//! writes become ivirt.conWrite, and keystrokes the app posts arrive via
//! ivirt.conFetch into the UART receive path. Every guest owns one mailbox slot
//! (`id`), so several VMs run side by side without seeing each other.

const std = @import("std");
const buildinfo = @import("buildinfo"); // -Dtest-hooks: the guest-console mirror below
const cpu = @import("../cpu/cpu.zig");
const tsc = @import("../cpu/tsc.zig");
const wallclock = @import("../timer/wallclock.zig");
const caldate = @import("../timer/caldate.zig");
const klog = @import("../debug/klog.zig");
const pmm = @import("../memory/pmm.zig");
const guestmem = @import("guestmem.zig");
const vcpu = @import("vcpu.zig");
const linuxload = @import("linuxload.zig");
const uart16550 = @import("uart16550.zig");
const pic8259 = @import("i8259.zig");
const pit8254 = @import("i8254.zig");
const rtcdev = @import("mc146818.zig");
const x2apic = @import("x2apic.zig");
const vcpuid = @import("vcpuid.zig");
const vmsr = @import("vmsr.zig");
const vmx = @import("vmx.zig");
const exitinfo = @import("exitinfo.zig");
const layout = @import("layout.zig");
const guestwalk = @import("guestwalk.zig");
const insn = @import("insn.zig");
const gpudev = @import("virtio/gpudev.zig");
const netdev = @import("virtio/netdev.zig");
const inputdev = @import("virtio/inputdev.zig");
const ivirt = @import("ivirt");
const netbridge = @import("netbridge.zig");

// Serial port block (COM1) and the IRQ line the UART drives.
const COM1_BASE: u16 = 0x3F8;
const COM1_TOP: u16 = 0x3FF;
const SERIAL_IRQ: u4 = 4;
/// How many missed PIT pulses one poll may deliver. A guest descheduled for a
/// while (its core ran the fetch, the desktop stalled) must not be handed a
/// thousand-interrupt storm it would spend its whole slice servicing; the
/// remainder stays counted in the PIT and drains over later polls, which is
/// exactly the lost-tick behavior Linux already tolerates.
const PIT_CATCH_UP_MAX: u64 = 4;
const VECTOR_GP: u8 = 13; // #GP — general-protection fault (SDM Vol 3A Table 6-1)

/// How long an idle guest (one that executed HLT with no interrupt pending and no
/// APIC deadline armed) may sleep before its vCPU looks at it again. It bounds
/// how long a keystroke or a stop request waits on an otherwise idle guest, so it
/// is a latency figure, not a timer period: short enough to feel immediate at a
/// serial console, long enough that an idle guest costs its core nothing.
const IDLE_SLICE_MS: u64 = 1;

/// Frames of host memory the display device's pixel stores occupy, taken once
/// per guest at creation (VIRT-007: nothing on an exit path allocates).
const STORE_FRAMES: usize = (gpudev.STORE_BYTES + pmm.FRAME_SIZE - 1) / pmm.FRAME_SIZE;

pub const Vm = struct {
    /// This guest's mailbox slot — its console stream, scanout and lifecycle
    /// state. Assigned at creation and fixed for the guest's life.
    id: ivirt.Id,
    mem: guestmem.GuestMem,
    vcpu: vcpu.Vcpu = .{},
    uart: uart16550.Uart = .{},
    pic: pic8259.PicPair = .{},
    pit: pit8254.Pit = .{},
    cmos: rtcdev.Cmos = .{},
    apic: x2apic.Apic = .{},
    /// Whether this guest has already been told that the host has no wall clock.
    /// The warning is worth making once per guest and not once per CMOS read —
    /// Linux reads the clock a handful of times a second once it is up.
    clockless_reported: bool = false,
    /// The guest's display adapter. Wired by `start` (not `create`) because its
    /// transport backend holds interior pointers that a struct copy would break.
    gpu: gpudev.GpuDev = .{},
    /// The guest's network adapter, wired by `start` for the same reason. Its
    /// FrameSink stays unconnected until a NIC bridge claims it via
    /// `net.connectSink`; until then transmitted frames drop into the device's
    /// counters, never silently.
    net: netdev.NetDev = .{},
    /// The guest's keyboard and absolute pointer, wired by `start` for the same
    /// reason. A guest with a scanout but no input is a picture, not a machine.
    kbd: inputdev.InputDev = .{},
    tablet: inputdev.InputDev = .{},
    /// Host-physical base of the display's pixel stores, and the frame count to
    /// return at teardown.
    stores_hpa: usize = 0,
    entry: linuxload.EntryState = undefined,
    /// The interrupt `onPollInterrupt` last offered, retired by `onCommitInterrupt`
    /// once the vCPU actually injects it. Null between commits.
    pending: ?x2apic.Apic.Pending = null,
    /// Bytes the guest has written to the serial transmit register. A guest that
    /// prints nothing and a console that never reaches the screen look identical
    /// from outside; this tells them apart.
    serial_writes: u64 = 0,
    /// The last IO port the guest touched — with the exit-reason ranking this
    /// names WHICH device a probing/polling guest is banging on.
    io_last_port: u16 = 0,
    /// The first MSR-write targets, in order — a guest that dies after N
    /// writes is diagnosed by exactly this list (which LAPIC mode it tried,
    /// which write our model dropped).
    wrmsr_log: [16]u32 = .{0} ** 16,
    wrmsr_seen: usize = 0,

    const ops = vcpu.MachineOps{
        .cpuid = onCpuid,
        .hlt = onHlt,
        .io = onIo,
        .rdmsr = onRdmsr,
        .wrmsr = onWrmsr,
        .mmio = onMmio,
        .pollInterrupt = onPollInterrupt,
        .commitInterrupt = onCommitInterrupt,
        .stopRequested = onStopRequested,
    };

    /// Create guest RAM + EPT and load the kernel image and initramfs, bound to
    /// mailbox slot `id`, initializing `self` IN PLACE. In place is a
    /// correctness requirement twice over: the devices `start` wires hold
    /// interior pointers a struct copy would break, and a by-value Vm is a
    /// ~120 KiB stack temporary — no kernel task stack (sched.STACK_SIZE)
    /// can absorb that below a real call chain. Grabs the contiguous guest
    /// RAM once, so call it off any hot path.
    pub fn create(self: *Vm, id: ivirt.Id, ram_bytes: u64, bz_image: []const u8, initrd: []const u8, cmdline: []const u8) !void {
        var mem = try guestmem.create(ram_bytes, vmx.eptCaps());
        errdefer mem.deinit();
        const entry = try linuxload.load(mem.ram(), bz_image, initrd, cmdline);
        const stores_hpa = pmm.allocContiguous(STORE_FRAMES) orelse return error.NoGuestRam;
        self.* = .{
            .id = id,
            .mem = mem,
            .stores_hpa = stores_hpa,
            .entry = entry,
        };
    }

    /// Program the VMCS on the calling core — the one the vCPU task bound itself
    /// to, and the only core this guest may ever run on — wire the
    /// device models to this VM's final address, and make the guest ready to run.
    /// Pairs with `deinit`, which releases everything this allocates; a failure
    /// here leaves nothing acquired for the caller to unwind beyond what `create`
    /// took.
    pub fn start(self: *Vm) !void {
        try self.vcpu.initVmcs();
        try self.vcpu.setup(self.entry, self.mem.eptp);
        const store_words: usize = gpudev.STORE_BYTES / @sizeOf(u32);
        const pixels = @as([*]u32, @ptrFromInt(self.stores_hpa))[0..store_words];
        self.gpu.bind(self.id, gpudev.carveStores(pixels), self.mem.ram());
        self.net.bind(netdev.guestMac(self.id), self.mem.ram());
        // Transmitted guest frames cross to the system loop's bridge through
        // the mailbox — the device model never touches the real NIC, and the
        // rule that a guest's queues live on its own core is kept.
        self.net.connectSink(.{ .ctx = self, .put = sinkPut });
        self.kbd.bind(.keyboard, self.mem.ram());
        self.tablet.bind(.tablet, self.mem.ram());
        ivirt.setState(self.id, .running);
    }

    /// Run the guest on the calling core for a slice of `slice_us` microseconds.
    /// See vcpu.Vcpu.pump for the outcomes; `.finished` means the caller must now
    /// `deinit` this VM.
    pub fn pump(self: *Vm, slice_us: u64) vcpu.Vcpu.Pump {
        self.vcpu.makeCurrent() catch |e| {
            // The VMCS would not load on this core. Ending the guest without
            // saying so leaves it indistinguishable from one that halted.
            klog.puts("virt: vm could not be made current (");
            klog.puts(@errorName(e));
            klog.puts(") — guest ended\n");
            return .finished;
        };
        return self.vcpu.pump(&ops, @ptrCast(self), tsc.rdtsc() + tsc.usTicks(slice_us));
    }

    /// The TSC value at which an idle guest should next be looked at: its own
    /// armed APIC deadline when that is nearer, else one idle slice from now. The
    /// driver waits until this before pumping again, so an idle guest neither
    /// spins its core nor oversleeps its own timer.
    pub fn nextWakeTsc(self: *Vm) u64 {
        const slice = tsc.rdtsc() + tsc.msTicks(IDLE_SLICE_MS);
        const armed = self.apic.armedDeadline();
        return if (armed != 0 and armed < slice) armed else slice;
    }

    /// Release everything this guest holds: the VMCS and MSR-area frames, then
    /// the scanout — which points INTO the display's pixel stores, so it must be
    /// retracted BEFORE they are freed — then those stores, then guest RAM and
    /// its EPT tables. Must run on the core the VMCS was loaded on (teardown is core-local)
    /// and only after a `pump` returned `.finished`, so no VM entry can follow.
    /// The caller publishes the final lifecycle state afterwards, since only it
    /// knows whether this was a clean halt or a failure.
    pub fn deinit(self: *Vm) void {
        self.vcpu.deinit();
        ivirt.retractFb(self.id);
        if (self.stores_hpa != 0) {
            pmm.freeContiguous(self.stores_hpa, STORE_FRAMES);
            self.stores_hpa = 0;
        }
        self.mem.deinit();
    }

    // --- exit handlers (MachineOps) ---

    fn onCpuid(ctx: *anyopaque, v: *vcpu.Vcpu) vcpu.Action {
        _ = ctx;
        const host = cpu.cpuid(@truncate(v.regs.rax), @truncate(v.regs.rcx));
        const out = vcpuid.filter(
            .{ .eax = host.eax, .ebx = host.ebx, .ecx = host.ecx, .edx = host.edx },
            @truncate(v.regs.rax),
            @truncate(v.regs.rcx),
            tsc.hz(),
        );
        v.regs.rax = out.eax;
        v.regs.rbx = out.ebx;
        v.regs.rcx = out.ecx;
        v.regs.rdx = out.edx;
        v.skipInstruction();
        return .resume_guest;
    }

    fn onHlt(ctx: *anyopaque, v: *vcpu.Vcpu) vcpu.Action {
        _ = ctx;
        // The guest idled waiting for an interrupt. Skip the HLT and end the run
        // slice: re-entering immediately would spin the core through HLT exits at
        // no benefit, since only a device or timer event this side of the exit can
        // make the guest runnable again. The driver waits until `nextWakeTsc` (on
        // SMP that halts the core, KRN-007) and pumps again, at which point
        // serviceInterrupts injects whatever arrived.
        v.skipInstruction();
        return .pause;
    }

    /// Whether this guest should stop at the next exit boundary: its window asked
    /// it to (the mailbox stop flag), or the scheduler cancelled its vCPU task.
    fn onStopRequested(ctx: *anyopaque) bool {
        const self: *Vm = @ptrCast(@alignCast(ctx));
        return ivirt.takeStop(self.id);
    }

    fn onIo(ctx: *anyopaque, v: *vcpu.Vcpu, info: exitinfo.IoInfo) vcpu.Action {
        const self: *Vm = @ptrCast(@alignCast(ctx));
        self.io_last_port = info.port;
        if (info.port >= COM1_BASE and info.port <= COM1_TOP) {
            const off: u3 = @truncate(info.port - COM1_BASE);
            if (info.is_in) {
                const b = self.uart.ioRead(off);
                v.regs.rax = (v.regs.rax & ~@as(u64, 0xFF)) | b;
            } else {
                if (off == 0) self.serial_writes +%= 1;
                self.uart.ioWrite(off, @truncate(v.regs.rax));
                self.drainSerial();
            }
        } else if (pic8259.owns(info.port)) {
            if (info.is_in) {
                v.regs.rax = (v.regs.rax & ~@as(u64, 0xFF)) | self.pic.ioRead(info.port);
            } else {
                self.pic.ioWrite(info.port, @truncate(v.regs.rax));
            }
        } else if (pit8254.Pit.owns(info.port)) {
            // The legacy timer: the ONLY interrupt source a stock distribution
            // kernel has before it programs its local APIC.
            if (info.is_in) {
                v.regs.rax = (v.regs.rax & ~@as(u64, 0xFF)) | self.pit.ioRead(info.port);
            } else {
                self.pit.ioWrite(info.port, @truncate(v.regs.rax));
            }
        } else if (rtcdev.Cmos.owns(info.port)) {
            // The wall clock. Every Linux reads it early and spins forever on a
            // stuck update-in-progress bit, so this is a boot requirement, not a
            // convenience — see mc146818.zig.
            if (info.is_in) {
                v.regs.rax = (v.regs.rax & ~@as(u64, 0xFF)) | self.cmos.ioRead(info.port, self.guestTime());
            } else {
                self.cmos.ioWrite(info.port, @truncate(v.regs.rax));
            }
        } else if (info.is_in) {
            // An unpopulated port reads as all-ones.
            const mask: u64 = (@as(u64, 1) << @intCast(info.size * 8)) - 1;
            v.regs.rax |= mask;
        }
        v.skipInstruction();
        return .resume_guest;
    }

    fn onRdmsr(ctx: *anyopaque, v: *vcpu.Vcpu, msr: u32) vcpu.Action {
        const self: *Vm = @ptrCast(@alignCast(ctx));
        const value: u64 = switch (vmsr.classify(msr)) {
            .apic, .tsc_deadline => self.apic.msrRead(msr) orelse 0,
            // Read back the VMCS guest-state field the guest last wrote through.
            .guest_field => blk: {
                const field = vmsr.guestFieldRead(msr) orelse return injectGp(v);
                break :blk v.readField(field) orelse return injectGp(v);
            },
            // Read back the value carried in the VM-entry MSR-load area.
            .auto_msr => blk: {
                const slot = vmsr.autoIndexOf(msr) orelse return injectGp(v);
                break :blk v.autoMsr(slot);
            },
            .handled_here => switch (vmsr.read(msr)) {
                .value => |x| x,
                .gp => return injectGp(v),
            },
            .gp => return injectGp(v),
        };
        // IA32_TSC reads the real counter (passthrough).
        const final = if (msr == vmsr.IA32_TIME_STAMP_COUNTER) tsc.rdtsc() else value;
        v.regs.rax = final & 0xFFFFFFFF;
        v.regs.rdx = final >> 32;
        v.skipInstruction();
        return .resume_guest;
    }

    fn onWrmsr(ctx: *anyopaque, v: *vcpu.Vcpu, msr: u32, value: u64) vcpu.Action {
        const self: *Vm = @ptrCast(@alignCast(ctx));
        if (self.wrmsr_seen < self.wrmsr_log.len) {
            self.wrmsr_log[self.wrmsr_seen] = msr;
            self.wrmsr_seen += 1;
        }
        switch (vmsr.classify(msr)) {
            // The APIC applies its own state (arms its deadline, latches a
            // self-IPI/ICR vector into IRR); the machine polls it via
            // onPollInterrupt, so the returned action needs no further work.
            .apic, .tsc_deadline => _ = self.apic.msrWrite(msr, value),
            // Write the (validated) value through to its VMCS guest-state field so
            // the next VM entry loads it. EFER is validated against the guest's live
            // EFER/CR0 to keep the long-mode bits consistent.
            .guest_field => {
                const state = vmsr.WriteCtx{
                    .efer = v.readField(.guest_ia32_efer) orelse return injectGp(v),
                    .cr0 = v.readField(.guest_cr0) orelse return injectGp(v),
                };
                switch (vmsr.guestFieldWrite(msr, value, state)) {
                    .write => |w| v.writeField(w.field, w.value),
                    .gp => return injectGp(v),
                }
            },
            // Store the (validated) value into the VM-entry MSR-load area so the
            // next VM entry loads it into the real MSR.
            .auto_msr => {
                const slot = vmsr.autoIndexOf(msr) orelse return injectGp(v);
                switch (vmsr.autoWrite(msr, value)) {
                    .value => |x| v.setAutoMsr(slot, x),
                    .gp => return injectGp(v),
                }
            },
            .handled_here => switch (vmsr.write(msr, value)) {
                .ok => {},
                .gp => return injectGp(v),
            },
            .gp => return injectGp(v),
        }
        v.skipInstruction();
        return .resume_guest;
    }

    /// Serve a guest access to a memory-mapped device. The exit reports the
    /// faulting guest-physical address but not the operand size, direction, or
    /// register, so those are recovered by fetching the faulting instruction
    /// through the guest's own page tables and decoding it. Anything the
    /// hypervisor cannot emulate — an address outside the device window, an
    /// unfetchable or undecodable instruction — is logged with everything needed
    /// to extend the decoder and ends the guest, never the host (VIRT-017).
    fn onMmio(ctx: *anyopaque, v: *vcpu.Vcpu, gpa: u64, info: exitinfo.EptViolation) vcpu.Action {
        const self: *Vm = @ptrCast(@alignCast(ctx));
        const in_virtio = gpa >= layout.VIRTIO_MMIO_GPA and gpa < layout.VIRTIO_MMIO_END;
        const in_lapic = gpa >= layout.LAPIC_GPA and gpa < layout.LAPIC_END;
        if (!in_virtio and !in_lapic)
            return self.mmioFailed(v, gpa, "no device at this address", null);

        // In 64-bit mode the code segment's base is 0, so RIP is the linear
        // address the guest's page tables translate.
        const rip = v.readField(.guest_rip) orelse
            return self.mmioFailed(v, gpa, "guest RIP unreadable", null);
        const cr3 = v.readField(.guest_cr3) orelse
            return self.mmioFailed(v, gpa, "guest CR3 unreadable", null);
        var bytes: [insn.MAX_BYTES]u8 = undefined;
        if (!guestwalk.fetch(self.mem.ram(), cr3, rip, &bytes))
            return self.mmioFailed(v, gpa, "instruction unfetchable", null);
        const dec = insn.decode(&bytes) orelse
            return self.mmioFailed(v, gpa, "instruction outside the decoded subset", &bytes);

        if (in_lapic) return self.apicMmio(v, gpa, gpa - layout.LAPIC_GPA, dec, &bytes);

        const slot: layout.VirtioSlot = @enumFromInt((gpa - layout.VIRTIO_MMIO_GPA) / layout.VIRTIO_MMIO_STRIDE);
        const off = gpa - slot.gpa();
        switch (dec.op) {
            .load => |l| {
                // The transport is a 32-bit register file; a wider load has no
                // meaning against it.
                if (l.size > 4) return self.mmioFailed(v, gpa, "load wider than a device register", &bytes);
                const val = self.deviceRead(slot, off, l.size);
                const dst = v.gpr(l.reg) orelse
                    return self.mmioFailed(v, gpa, "load into RSP", &bytes);
                dst.* = switch (l.ext) {
                    // A 32-bit or MOVZX destination is replaced outright; a
                    // narrower MOV merges into the low bytes.
                    .zero => val,
                    .none => mergeLow(dst.*, val, l.size),
                };
            },
            .store => |s| {
                if (s.size > 4) return self.mmioFailed(v, gpa, "store wider than a device register", &bytes);
                const val: u64 = switch (s.src) {
                    .imm => |imm| imm,
                    .reg => |r| (v.gpr(r) orelse
                        return self.mmioFailed(v, gpa, "store from RSP", &bytes)).*,
                };
                self.deviceWrite(slot, off, s.size, @truncate(val));
            },
        }
        _ = info;
        v.skipInstruction();
        return .resume_guest;
    }

    /// Serve a decoded access to the local APIC's memory-mapped window. The
    /// registers are 32-bit throughout, and the action a write sets in motion
    /// needs no follow-up here for the same reason the MSR path needs none: the
    /// APIC has already applied it to itself, and `onPollInterrupt` reads it back
    /// before the next entry.
    fn apicMmio(self: *Vm, v: *vcpu.Vcpu, gpa: u64, off: u64, dec: insn.Decoded, bytes: *const [insn.MAX_BYTES]u8) vcpu.Action {
        switch (dec.op) {
            .load => |l| {
                if (l.size > 4) return self.mmioFailed(v, gpa, "APIC load wider than a register", bytes);
                const dst = v.gpr(l.reg) orelse
                    return self.mmioFailed(v, gpa, "APIC load into RSP", bytes);
                const val = self.apic.mmioRead(off);
                dst.* = switch (l.ext) {
                    .zero => val,
                    .none => mergeLow(dst.*, val, l.size),
                };
            },
            .store => |s| {
                if (s.size > 4) return self.mmioFailed(v, gpa, "APIC store wider than a register", bytes);
                const val: u64 = switch (s.src) {
                    .imm => |imm| imm,
                    .reg => |r| (v.gpr(r) orelse
                        return self.mmioFailed(v, gpa, "APIC store from RSP", bytes)).*,
                };
                _ = self.apic.mmioWrite(off, @truncate(val));
            },
        }
        v.skipInstruction();
        return .resume_guest;
    }

    /// Route a decoded device access to the model that owns the window slot.
    /// Slots with no device answer as absent hardware: reads all-zero, writes
    /// dropped — what a driver probing an empty slot must see.
    fn deviceRead(self: *Vm, slot: layout.VirtioSlot, off: u64, size: u8) u32 {
        return switch (slot) {
            .gpu => self.gpu.read(off, size),
            .net => self.net.read(off, size),
            .keyboard => self.kbd.read(off, size),
            .tablet => self.tablet.read(off, size),
            else => 0,
        };
    }

    fn deviceWrite(self: *Vm, slot: layout.VirtioSlot, off: u64, size: u8, val: u32) void {
        switch (slot) {
            .gpu => self.gpu.write(off, size, val),
            .net => self.net.write(off, size, val),
            .keyboard => self.kbd.write(off, size, val),
            .tablet => self.tablet.write(off, size, val),
            else => {},
        }
    }

    /// The Unix time the guest's CMOS clock should report: the host's own wall
    /// clock, which already advances between reads. When the host never got a
    /// stable RTC read of its own there is nothing truthful to offer, so the
    /// guest is handed the epoch and told so once — a guest whose clock reads
    /// 1970 boots and complains, which is strictly better than one that hangs.
    fn guestEpoch(self: *Vm) i64 {
        return wallclock.epochSeconds() orelse {
            if (!self.clockless_reported) {
                self.clockless_reported = true;
                klog.puts("virt: host has no wall clock — the guest's RTC reads 1970\n");
            }
            return 0;
        };
    }

    /// The instant the guest's CMOS clock should report, as its registers want
    /// it: the host's wall clock, turned into a civil date by the one module that
    /// owns calendar arithmetic.
    fn guestTime(self: *Vm) rtcdev.Time {
        const c = caldate.civilFromEpoch(self.guestEpoch());
        return .{
            .second = c.second,
            .minute = c.minute,
            .hour = c.hour,
            .weekday = c.weekday,
            .day = c.day,
            .month = c.month,
            .year = @intCast(c.year),
        };
    }

    /// Report a device access the hypervisor cannot emulate and end the guest.
    /// The instruction bytes are the breadcrumb for extending virt/insn.zig, so
    /// they are logged whenever the fetch got far enough to have them.
    fn mmioFailed(self: *Vm, v: *vcpu.Vcpu, gpa: u64, why: []const u8, bytes: ?*const [insn.MAX_BYTES]u8) vcpu.Action {
        _ = self;
        klog.puts("virt: unemulated MMIO at gpa=");
        klog.putHex(gpa);
        klog.puts(" rip=");
        klog.putHex(v.readField(.guest_rip) orelse 0);
        klog.puts(" (");
        klog.puts(why);
        klog.puts(")");
        if (bytes) |b| {
            klog.puts(" insn=");
            for (b) |byte| {
                klog.putHex(byte);
                klog.puts(" ");
            }
        }
        klog.puts("\n");
        return .shutdown;
    }

    /// netdev's FrameSink: one guest-transmitted Ethernet frame, posted to the
    /// bridge mailbox. Runs on the guest's core; a full ring is a counted drop.
    ///
    /// This is the guest's bridge PORT, so it is where the port's source
    /// address is enforced: a frame whose source is not this guest's own MAC is
    /// refused (netdev counts it in `tx_dropped`). Without that check a guest
    /// could claim a sibling's or the host's address, and since the bridge
    /// forwards purely on destination, the replies would then be delivered to
    /// the impersonated port. A guest has exactly one address (VIRT-027) and
    /// nothing legitimate transmits from another.
    fn sinkPut(ctx: *anyopaque, frame: []const u8) bool {
        const self: *Vm = @ptrCast(@alignCast(ctx));
        if (!netbridge.portAccepts(self.id, frame)) return false;
        return ivirt.netPost(self.id, frame);
    }

    /// Peek the highest-priority interrupt to inject before the next entry:
    /// sample the serial line into the PIC, fold in an expired LAPIC timer
    /// deadline, and arbitrate the PIC's ExtINT against the LAPIC. Non-destructive
    /// — `onCommitInterrupt` retires the winner only once the vCPU injects it, so
    /// a vector the guest cannot yet take is not acknowledged and lost.
    fn onPollInterrupt(ctx: *anyopaque, v: *vcpu.Vcpu) ?u8 {
        const self: *Vm = @ptrCast(@alignCast(ctx));
        _ = v;

        // Pull any keystrokes the app posted into the UART receive path.
        while (ivirt.conFetch(self.id)) |b| {
            if (!self.uart.pushRx(b)) break;
        }

        // …and any key or pointer events into the input devices. Both drains
        // happen HERE, on the guest's own core: the window that produced them
        // runs on core 0, and a device's queues may only be touched by the core
        // driving the vCPU (the same rule netdev's seam states).
        while (ivirt.inputFetch(self.id)) |ev| switch (ev) {
            .key => |k| self.kbd.key(k.code, k.down),
            .button => |b| self.tablet.key(b.code, b.down),
            .motion => |m| self.tablet.motion(m.x, m.y),
        };

        // …and the bridge's inbound Ethernet frames into the NIC's receive
        // queue — same core rule. The device is asked FIRST whether it has a
        // free receive buffer, and only then is a frame taken from the ring:
        // this poll runs orders of magnitude more often than the system loop
        // refills the ring, so taking a frame the guest cannot yet hold — while
        // its driver is still coming up, or between buffer refills — would bleed
        // the ring dry one frame per poll. Whatever the guest is not ready for
        // waits where it is. A frame the device accepts a buffer for and still
        // refuses (a chain too small for it) is a genuine loss, counted there.
        var net_buf: [ivirt.NET_FRAME_BYTES]u8 = undefined;
        while (self.net.rxReady()) {
            const len = ivirt.netPeek(self.id, &net_buf) orelse break;
            _ = self.net.pushRx(net_buf[0..len]);
            ivirt.netCommit(self.id);
        }

        // The legacy timer: convert the host TSC into PIT clock ticks and ask
        // the counter how many output pulses came due, then present each as an
        // IRQ 0 edge. This is the guest's ONLY timekeeping before it programs
        // its local APIC — jiffies advance from here, and every early boot
        // loop that waits on them depends on it.
        const now_pit: u64 = @intCast(@as(u128, tsc.rdtsc()) * pit8254.PIT_HZ / @max(1, tsc.hz()));
        const ticks = self.pit.expired(now_pit, PIT_CATCH_UP_MAX);
        if (ticks > 0) {
            // A level the PIC latches: lower then raise so a second pulse
            // arriving before the guest's EOI is a fresh edge, not a no-op.
            self.pic.lower(pit8254.TIMER_IRQ);
            self.pic.raise(pit8254.TIMER_IRQ);
        }

        // Reflect each device's interrupt level into the PIC.
        if (self.uart.irqLevel()) self.pic.raise(SERIAL_IRQ) else self.pic.lower(SERIAL_IRQ);
        const gpu_irq = layout.VirtioSlot.gpu.irq();
        if (self.gpu.irqLevel()) self.pic.raise(gpu_irq) else self.pic.lower(gpu_irq);
        const net_irq = layout.VirtioSlot.net.irq();
        if (self.net.irqLevel()) self.pic.raise(net_irq) else self.pic.lower(net_irq);
        const kbd_irq = layout.VirtioSlot.keyboard.irq();
        if (self.kbd.irqLevel()) self.pic.raise(kbd_irq) else self.pic.lower(kbd_irq);
        const tablet_irq = layout.VirtioSlot.tablet.irq();
        if (self.tablet.irqLevel()) self.pic.raise(tablet_irq) else self.pic.lower(tablet_irq);

        // An expired TSC deadline fires the LAPIC timer (disarms the MSR, raises
        // the vector into IRR).
        const deadline = self.apic.armedDeadline();
        if (deadline != 0 and tsc.rdtsc() >= deadline) self.apic.fireTimer();

        const extint = self.pic.peek(); // candidate ExtINT vector, not yet acked
        self.pending = self.apic.nextPending(extint);
        return if (self.pending) |p| p.vector else null;
    }

    /// The vCPU injected the vector `onPollInterrupt` offered: retire it from its
    /// source so it is not offered again until the guest's EOI.
    fn onCommitInterrupt(ctx: *anyopaque, v: *vcpu.Vcpu) void {
        const self: *Vm = @ptrCast(@alignCast(ctx));
        _ = v;
        if (self.pending) |p| {
            switch (p.source) {
                .apic => self.apic.accept(p.vector), // IRR → ISR
                .extint => _ = self.pic.ack(), // the real 8259 INTA, now that it is delivered
            }
            self.pending = null;
        }
    }

    fn drainSerial(self: *Vm) void {
        while (self.uart.popTx()) |b| {
            _ = ivirt.conWrite(self.id, b);
            if (comptime buildinfo.test_hooks) mirrorSerial(self.id, b);
        }
    }
};

/// Line buffers for the guest-console mirror, one per VM slot.
var mirror_buf: [ivirt.MAX_VMS][MIRROR_LINE]u8 = undefined;
var mirror_len: [ivirt.MAX_VMS]usize = [_]usize{0} ** ivirt.MAX_VMS;
/// Whether the mirror is part-way through a terminal escape sequence.
var mirror_esc: [ivirt.MAX_VMS]bool = [_]bool{false} ** ivirt.MAX_VMS;
/// Longest guest line the mirror carries whole; a longer one is emitted in pieces
/// rather than truncated, because a boot message cut in half reads as a fault.
const MIRROR_LINE = 180;

/// Mirror one guest serial byte into the kernel trace, a line at a time
/// (`-Dtest-hooks` builds only).
///
/// The guest's console normally reaches a person through the VM window, which
/// needs the GPU. A machine with no display — the QEMU boot the integration
/// suites use — would then have no way to see whether a guest booted at all, so
/// the test-hooks build sends the same bytes to the trace bus, where netdebug
/// carries them off the machine. This is the receipt that a guest ran.
fn mirrorSerial(id: ivirt.Id, b: u8) void {
    // Terminal escape sequences are dropped WHOLE. Dropping only the escape byte
    // and keeping what follows is worse than useless: a colour code arrives as
    // "[1;34mbin" and the reader is left deciding which characters the guest
    // meant. The window's own grid swallows these the same way (apps/vmconsole).
    if (mirror_esc[id]) {
        if (b == '[') return; // the CSI introducer, still part of the sequence
        if (b >= 0x40 and b <= 0x7E) mirror_esc[id] = false; // final byte: done
        return;
    }
    if (b == 0x1B) {
        mirror_esc[id] = true;
        return;
    }

    const n = &mirror_len[id];
    if (b == '\n' or n.* == MIRROR_LINE) {
        emitMirror(id);
        if (b == '\n') return;
    }
    // Remaining control bytes would break the trace's line framing; the guest's
    // own carriage returns are the common case and carry nothing.
    if (b >= 0x20 and b < 0x7F) {
        mirror_buf[id][n.*] = b;
        n.* += 1;
    }
}

fn emitMirror(id: ivirt.Id) void {
    const n = mirror_len[id];
    mirror_len[id] = 0;
    if (n == 0) return;
    var line: [MIRROR_LINE + 24]u8 = undefined;
    const rec = std.fmt.bufPrint(&line, "vm{d}: {s}\n", .{ id, mirror_buf[id][0..n] }) catch return;
    klog.puts(rec);
}

/// Replace the low `size` bytes of `old` with those of `val`, preserving the
/// rest — the write-back rule for an 8- or 16-bit MOV into a 64-bit register.
fn mergeLow(old: u64, val: u32, size: u8) u64 {
    const mask: u64 = (@as(u64, 1) << @intCast(size * 8)) - 1;
    return (old & ~mask) | (@as(u64, val) & mask);
}

/// Deliver a general-protection fault to the guest (an unhandled MSR access).
fn injectGp(v: *vcpu.Vcpu) vcpu.Action {
    // #GP is a hardware exception that pushes an error code (0 for a #GP that is
    // not a segment-selector fault) — injected as such, not as an external
    // interrupt, or the guest handler reads a misaligned exception frame.
    v.injectException(VECTOR_GP, 0);
    return .resume_guest;
}
