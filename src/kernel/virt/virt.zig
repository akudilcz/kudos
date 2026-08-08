//! The virtualization subsystem facade: capability probing, and the lifecycle of
//! every guest VM — create it, run it, stop it, and give its resources back. IO
//! edge — it wires the host-tested pure layers (vmcs/vmxcaps/ept/machine model,
//! and the vmslots retirement handshake) to the scheduler and the ivirt app seam.
//!
//! SEVERAL guests at once (up to ivirt.MAX_VMS), each with its own console
//! window, identified by its mailbox slot id — which is also its index into this
//! file's VM storage.
//!
//! Two run drivers, one loop body (`machine.Vm.pump`):
//!
//!   SMP           each guest's virtual processor is an ordinary scheduled task
//!                 (VIRT-021), placed by the scheduler on whichever core is free
//!                 like anything else (KRN-009). It pins itself the instant it
//!                 starts — `sched.pinHere` — because from the moment its VMCS is
//!                 loaded it belongs to that physical core and may never move.
//!                 The placement is free; only the binding is the hardware's.
//!   single-core   there is no scheduler to host a vCPU task, so the desktop
//!                 pumps every live guest for a small slice once per frame
//!                 (`pumpAll`). The guest runs — slowly, sharing the core with
//!                 the desktop, which always gets the frame first.
//!
//! Teardown is owned by whichever context runs the guest, never by the window:
//! closing a window only REQUESTS a stop. The guest then stops at its next VM
//! exit boundary and its own core frees the VMCS, the MSR area, guest RAM and the
//! EPT tables before releasing its slot. That split is what makes the close
//! race-free — see vmslots.zig for the retirement handshake.

const buildinfo = @import("buildinfo");
const klog = @import("../debug/klog.zig");
const timer = @import("../timer/timer.zig");
const tsc = @import("../cpu/tsc.zig");
const heap = @import("../memory/heap.zig");
const inet = @import("inet");
const sched = @import("../sched/sched.zig");
const schedsleep = @import("../sched/sleep.zig");
const percpu = @import("../sched/percpu.zig");
const smp = @import("../smp/smp.zig");
const vmx = @import("vmx.zig");
const vmxcaps = @import("vmxcaps.zig");
const machine = @import("machine.zig");
const netdev = @import("virtio/netdev.zig");
const vmslots = @import("vmslots.zig");
const gueststage = @import("gueststage.zig");
const layout = @import("layout.zig");
const ivirt = @import("ivirt");

/// The command line every staged guest boots with: the serial console kudos
/// emulates, plus the discovery argument for each virtio device the machine
/// model wires up (there is no device tree or PCI bus in a kudos guest). The
/// framebuffer console comes first so kernel messages land on the guest's
/// display, while ttyS0 — named last — stays /dev/console for the shell.
pub const STAGED_CMDLINE = "console=tty0 console=ttyS0 " ++ layout.WIRED_DEVICES;

/// How long one `pump` slice runs before the driver looks at the world again.
///
/// SMP: the guest owns its core, so the only reason to come up for air is to
/// notice a stop request — a millisecond keeps the exit loop tight while making
/// a window close feel instant.
const SMP_SLICE_US: u64 = 1_000;
/// Single-core: every live guest gets a share of this much of each pass through
/// the system loop, which also polls input and repaints. Two milliseconds keeps
/// input latency far inside the one-frame budget (PERF-008) while still giving a
/// guest most of an idle core, since the loop runs this many times a second.
const LOOP_SLICE_US: u64 = 2_000;

var probed = false;

/// Storage for every guest, indexed by mailbox slot id. `registry` says which
/// entries are live; an entry is written only by the core that runs its guest.
var storage: [ivirt.MAX_VMS]machine.Vm = undefined;
var registry = vmslots.Registry(ivirt.MAX_VMS).init;
// The registry's transitions are plain read-modify-writes, and they now run on
// genuinely concurrent tasks: the system task claims/retires slots while each
// guest's vCPU task reports its core and its exit from whatever processor runs
// it. One lock over every registry call.
var registry_lock = @import("../sync/spinlock.zig").SpinLock{};

fn regLock() bool {
    return registry_lock.acquireIrqSave();
}
fn regUnlock(if_was: bool) void {
    registry_lock.releaseIrqRestore(if_was);
}

/// Probe VT-x once at boot. Never fails boot: a machine without VMX simply reports
/// the subsystem as unavailable.
pub fn init() void {
    if (!vmx.supported()) {
        klog.puts("virt: no VT-x on this CPU; virtualization unavailable\n");
        return;
    }
    vmx.probe();
    probed = true;
    const caps = vmx.eptCaps();
    klog.puts("virt: VT-x present; EPT ");
    klog.puts(if (caps.page_2m) "with 2 MiB pages\n" else "without large pages\n");
}

/// Whether virtualization is available on this machine.
pub fn available() bool {
    return probed;
}

// ── status ──────────────────────────────────────────────────────────────────

/// A snapshot of the subsystem for the `vm` console command.
pub const Status = struct {
    available: bool,
    ept_2m: bool,
    ept_1g: bool,
    /// Guests that hold a slot: running, or halted with their window still open.
    in_use: usize,
    /// The most guests that can exist at once.
    capacity: usize,
};

/// Why the last `StartFailed` failed, for a report that can say more than "it
/// did not work" — the bring-up has a dozen distinct failure points and the
/// difference between them is the whole diagnosis.
var last_start_error: []const u8 = "none";

pub fn lastStartError() []const u8 {
    return last_start_error;
}

/// The machine state behind the last start failure, when the failing layer
/// recorded one. Empty when it did not.
pub fn lastStartDetail() []const u8 {
    return vmx.vmxonDiag();
}

pub fn status() Status {
    const caps = if (probed) vmx.eptCaps() else vmxcaps.EptCaps{
        .execute_only = false,
        .walk_length_4 = false,
        .memtype_wb = false,
        .page_2m = false,
        .page_1g = false,
        .invept_supported = false,
        .ad_bits = false,
        .invept_single = false,
        .invept_all = false,
    };
    return .{
        .available = probed,
        .ept_2m = caps.page_2m,
        .ept_1g = caps.page_1g,
        .in_use = registry.inUseCount(),
        .capacity = ivirt.MAX_VMS,
    };
}

/// A snapshot of one guest for the `vm` listing.
pub const GuestInfo = struct {
    id: ivirt.Id,
    /// The core this guest's vCPU bound itself to, or null before it has
    /// started. Optional rather than 0, because core 0 is an ordinary core
    /// (ARCH-016) and cannot double as "none".
    core: ?u32,
    state: ivirt.State,
    stopping: bool,
    exits: u64,
};

/// Snapshot every in-use guest into `out`, returning the count. Called on core 0
/// for `vm status`; `exits` is read while its core may be incrementing it, which
/// for an aligned u64 on x86-64 cannot tear.
pub fn snapshot(out: []GuestInfo) usize {
    var n: usize = 0;
    var id: ivirt.Id = 0;
    while (id < ivirt.MAX_VMS) : (id += 1) {
        if (!registry.inUse(id)) continue;
        if (n >= out.len) break;
        out[n] = .{
            .id = id,
            .core = registry.coreOf(id),
            .state = ivirt.state(id),
            .stopping = ivirt.stopRequested(id),
            .exits = storage[id].vcpu.exits,
        };
        n += 1;
    }
    return n;
}

// ── boot ────────────────────────────────────────────────────────────────────

pub const BootError = error{
    /// No VT-x on this CPU.
    NotAvailable,
    /// VT-x is present, but entering VMX operation or programming the guest's
    /// VMCS failed on this core — a different fault entirely from having no
    /// VT-x, and one whose cause `lastStartError` names.
    StartFailed,
    /// No guest image is staged into this build.
    NotStaged,
    /// Every VM slot is in use.
    NoVmSlot,
    /// Guest RAM (or its nested page tables) could not be allocated — the slot
    /// is fine; physical memory is what ran short.
    GuestRamExhausted,
    /// The `vm boot <n>` number names no catalog image (guestlist.zig).
    BadImage,
    /// A network image boot is already in flight — one at a time (there is one
    /// background-fetch connection system-wide).
    Busy,
    /// The network is not up (no lease), so an image cannot be fetched.
    NoNetwork,
};

/// How much RAM the staged guest needs, measured from the image this build
/// carries — the size a caller of `bootStaged` should hand it.
pub const stagedRamBytes = gueststage.ramBytes;

/// Bring up the guest staged into this build with `ram_bytes` of RAM, and
/// return the mailbox slot the caller must open a console window on. The SMP
/// build spawns the guest's vCPU as a floating task (VIRT-021); the single-core
/// build pumps it from the system loop.
///
/// On return the guest is starting, not started: either path publishes
/// `.running` once the VMCS is live. Every failure leaves nothing allocated and
/// no slot held.
pub fn bootStaged(ram_bytes: u64, cmdline: []const u8) BootError!ivirt.Id {
    if (!probed) return error.NotAvailable;
    if (!gueststage.staged()) return error.NotStaged;
    return boot(ram_bytes, gueststage.bzImage(), gueststage.initramfs(), cmdline);
}

/// Whether a bootable guest image is staged into this build (gueststage.zig).
pub fn guestStaged() bool {
    return gueststage.staged();
}

/// The core guest `id` bound itself to, or null before its vCPU has started —
/// for the window's status strip, so which core a guest holds stays visible.
pub fn guestCore(id: ivirt.Id) ?u32 {
    return registry.coreOf(id);
}

// ── the guest NIC bridge (VIRT-027) ─────────────────────────────────────────
//
// kudos' guests share the machine's one physical NIC at layer 2. The network
// stack knows nothing of guests: it exposes a Bridge hook (net.connectBridge),
// the apex wires that hook to these two functions, and the frames themselves
// cross cores through the ivirt mailbox — the same seam every other guest-bound
// byte uses. Both run on the system loop's core; the guest's own core drains
// and fills the rings at interrupt-poll time.

/// Offer one received wire frame to the guests. Consumes (returns true) exactly
/// the unicast frames addressed to a running guest's MAC; broadcast and
/// multicast are COPIED to every running guest and left for kudos' own stack —
/// an ARP request is everyone's. A full guest ring counts the drop in ivirt.
pub fn bridgeOffer(frame: []const u8) bool {
    if (frame.len < 14) return false;
    const dst = frame[0..6];
    if (dst[0] & 1 == 1) {
        for (0..ivirt.MAX_VMS) |id| {
            if (ivirt.state(id) == .running) _ = ivirt.netDeliver(id, frame);
        }
        return false;
    }
    const id = netdev.guestIdFor(dst) orelse return false;
    if (ivirt.state(id) != .running) return false;
    _ = ivirt.netDeliver(id, frame);
    return true;
}

/// Round-robin cursor for `bridgePoll`, so one chatty guest cannot starve
/// another of the wire.
var bridge_next: ivirt.Id = 0;

/// Copy the next guest-transmitted frame into `buf` and return its length, or
/// null when no guest has anything to send.
pub fn bridgePoll(buf: []u8) ?usize {
    for (0..ivirt.MAX_VMS) |i| {
        const id = (bridge_next + i) % ivirt.MAX_VMS;
        if (ivirt.netFetch(id, buf)) |len| {
            bridge_next = (id + 1) % ivirt.MAX_VMS;
            return len;
        }
    }
    return null;
}

// ── network image boots (VIRT-019/VIRT-020) ─────────────────────────────────

/// The `vm boot` catalog, re-exported so the console command lists it without
/// naming a kernel-internal path.
pub const images = @import("guestlist.zig");

/// The one in-flight network image boot. One at a time by design: there is
/// one background-fetch connection system-wide (net.zig), and a guest image
/// is two sequential fetches on it.
const Netboot = struct {
    active: bool = false,
    img: *const images.Image = undefined,
    id: ivirt.Id = 0,
    /// The fetched kernel, copied out of the first fetch's transient body;
    /// freed once machine creation has copied it into guest RAM.
    kernel: ?[]u8 = null,
    /// The initramfs fetch must start OUTSIDE the kernel fetch's completion
    /// callback — the background-fetch channel frees only after the callback
    /// returns — so the kernel callback arms this and `pumpNetboot` (the
    /// system loop) starts it on the next pass.
    want_initrd: bool = false,
    since_tsc: u64 = 0,
};
var netboot: Netboot = .{};

/// How long the queued initramfs fetch may wait for the background channel:
/// it frees within one loop pass in the normal case, so a full minute only
/// elapses when some other transfer holds it wedged.
const NETBOOT_CHAIN_BUDGET_MS: u64 = 60_000;

/// Record why a boot could not even begin, so a caller's error message names the
/// cause (the same channel asynchronous failures use).
pub fn setStartError(name: []const u8) void {
    last_start_error = name;
}

/// Core 0: begin booting catalog image `image_no` (a `vm boot` list number,
/// 2..images.COUNT). Claims the slot (state `.fetching`) and starts the kernel
/// fetch; the initramfs fetch and the machine build follow from the fetch
/// callbacks, all on the job pump — the loop never blocks. The built guest's
/// vCPU is spawned as an ordinary task and placed wherever there is a free core
/// (VIRT-021).
///
/// Returns the slot id the caller must open a VM window on; on any later
/// (asynchronous) failure that slot shows `.failed` with `lastStartError` set.
pub fn netbootBegin(image_no: u8) BootError!ivirt.Id {
    if (!probed) return error.NotAvailable;
    const img = images.byNumber(image_no) orelse return error.BadImage;
    if (netboot.active) return error.Busy;
    const net = inet.instance orelse return error.NoNetwork;
    if (!net.isUp()) return error.NoNetwork;

    const claim_if = regLock();
    const id = registry.claim() orelse {
        regUnlock(claim_if);
        return error.NoVmSlot;
    };
    regUnlock(claim_if);
    ivirt.reset(id);
    ivirt.setState(id, .fetching);

    netboot = .{ .active = true, .img = img, .id = id, .since_tsc = tsc.rdtsc() };
    net.fetchBackground(heap.allocator(), img.kernel_url, &netboot, nbKernelDone) catch {
        nbFail("kernel fetch would not start (network busy or bad URL)");
        // No window exists for this slot and none will be opened (we are about
        // to return an error) — nbFail's vcpuDone alone would leave the window
        // hold set and leak the slot forever.
        const reg_if = regLock();
        registry.abandon(id);
        regUnlock(reg_if);
        return error.Busy;
    };
    klog.puts("virt: fetching guest image over HTTP (kernel half)\n");
    return id;
}

/// A fetched image half's transport fingerprint: its length and a rolling
/// 64-bit sum of its bytes. Traced for BOTH halves so a truncated or corrupted
/// download is proven, not assumed — the same numbers are reproducible on the
/// host (`wc -c` and a byte sum of the same URL), which is what makes the
/// comparison evidence rather than a guess.
fn fingerprint(bytes: []const u8) u64 {
    var sum: u64 = 0;
    for (bytes) |b| sum = sum *% 131 +% b;
    return sum;
}

/// Trace one fetched half's length + fingerprint under the name `what`.
fn traceFetched(what: []const u8, bytes: []const u8) void {
    klog.puts("virt: fetched ");
    klog.puts(what);
    klog.puts(" len=");
    klog.putHex(bytes.len);
    klog.puts(" fp=");
    klog.putHex(fingerprint(bytes));
    klog.puts("\n");
}

/// First fetch landed: stash the kernel (the callback's body dies with the
/// callback) and queue the initramfs fetch for the next loop pass — the
/// background channel is still held by THIS transfer until we return.
fn nbKernelDone(_: *anyopaque, body: ?[]const u8) void {
    if (!netboot.active) return; // cancelled mid-fetch (window closed)
    const b = body orelse return nbFail("kernel fetch failed (see the trace)");
    traceFetched("kernel", b);
    const copy = heap.allocator().alloc(u8, b.len) catch return nbFail("kernel too large for the heap");
    @memcpy(copy, b);
    netboot.kernel = copy;
    netboot.want_initrd = true;
    klog.puts("virt: kernel fetched; initramfs fetch queued\n");
}

/// Core 0 (system loop): keep a netboot moving. Starts the queued initramfs
/// fetch once the background channel is free, and while a half is in flight
/// publishes its download standing to the slot's mailbox — what the VM
/// window's progress bar reads. A no-op almost always.
pub fn pumpNetboot() void {
    if (!netboot.active) return;
    if (netboot.want_initrd) {
        const net = inet.instance orelse return nbFail("network went away mid-boot");
        net.fetchBackground(heap.allocator(), netboot.img.initramfs_url, &netboot, nbInitrdDone) catch |e| {
            if (e == error.Busy) {
                // Channel not free yet (normally one pass). Budgeted, never forever.
                if (tsc.elapsedMs(netboot.since_tsc) > NETBOOT_CHAIN_BUDGET_MS)
                    nbFail("background fetch channel never freed for the initramfs");
                return;
            }
            return nbFail(@errorName(e));
        };
        netboot.want_initrd = false;
        klog.puts("virt: fetching the initramfs half\n");
        return;
    }
    // A half is in flight, so the background channel is ours: its progress is
    // this netboot's progress. (Between the halves `want_initrd` is set and the
    // branch above returns, so a stranger's transfer is never read.)
    const net = inet.instance orelse return;
    if (net.fetchProgress()) |p| {
        const half: ivirt.FetchHalf = if (netboot.kernel == null) .kernel else .initramfs;
        ivirt.setFetchProgress(netboot.id, half, p.received, p.total orelse 0);
    }
}

/// Second fetch landed: build the machine while the body is still alive
/// (machine creation copies both halves into guest RAM), then route the
/// built guest to its run driver.
fn nbInitrdDone(_: *anyopaque, body: ?[]const u8) void {
    // A cancelled netboot's late completion must not rebuild state over a slot
    // that has since been retired or reclaimed (see windowClosed).
    if (!netboot.active) return;
    const initrd = body orelse return nbFail("initramfs fetch failed (see the trace)");
    traceFetched("initramfs", initrd);
    const kernel = netboot.kernel orelse return nbFail("kernel half went missing");
    traceFetched("kernel(kept)", kernel);
    const id = netboot.id;
    const ram_bytes: u64 = @as(u64, netboot.img.ram_mb) * 1024 * 1024;

    ivirt.setState(id, .booting);
    machine.Vm.create(&storage[id], id, ram_bytes, kernel, initrd, netboot.img.cmdline) catch {
        return nbFail("guest RAM/EPT allocation failed (image too large?)");
    };
    // A machine now occupies the slot, so a run driver may execute it. Until
    // this line the slot was reserved but empty — see vmslots.zig.
    {
        const reg_if = regLock();
        defer regUnlock(reg_if);
        registry.vcpuStarted(id);
    }
    heap.allocator().free(kernel);
    netboot.kernel = null;
    netboot.active = false;

    if (buildinfo.smp) {
        spawnVcpu(id) catch {
            storage[id].deinit();
            return nbFail("could not start a vCPU task for the fetched guest");
        };
        return;
    }
    // Single-core: this callback runs on core 0's job pump — start here and
    // let pumpAll drive the guest per frame, exactly like a staged boot.
    startHere(id) catch |e| {
        last_start_error = @errorName(e);
        vmx.disableOnCore();
        storage[id].deinit();
        ivirt.setState(id, .failed);
        {
            const reg_if = regLock();
            defer regUnlock(reg_if);
            registry.vcpuDone(id);
        }
        return;
    };
}

/// A network boot failed: name the reason, free whatever was fetched, release
/// the vCPU hold (the still-open VM window keeps the slot until closed — same
/// aliasing rule as an abandoned pinned boot), and wake a pinned waiter.
fn nbFail(reason: []const u8) void {
    last_start_error = reason;
    klog.puts("virt: image boot failed: ");
    klog.puts(reason);
    klog.puts("\n");
    if (netboot.kernel) |k| heap.allocator().free(k);
    netboot.kernel = null;
    netboot.active = false;
    ivirt.setState(netboot.id, .failed);
    {
        const reg_if = regLock();
        defer regUnlock(reg_if);
        registry.vcpuDone(netboot.id);
    }
}

/// Create a guest from `bz_image` + `initrd` and start it. See `bootStaged`; the
/// images are read during the load and need not outlive it.
fn boot(ram_bytes: u64, bz_image: []const u8, initrd: []const u8, cmdline: []const u8) BootError!ivirt.Id {
    const claim_if = regLock();
    const id = registry.claim() orelse {
        regUnlock(claim_if);
        return error.NoVmSlot;
    };
    regUnlock(claim_if);
    // From here every failure must give the slot back: nothing else can, because
    // no vCPU exists yet to own the teardown.
    errdefer registry.abandon(id);

    ivirt.reset(id); // a recycled slot starts clean — see vmslots.zig
    ivirt.setState(id, .booting);
    machine.Vm.create(&storage[id], id, ram_bytes, bz_image, initrd, cmdline) catch {
        ivirt.setState(id, .failed);
        return error.GuestRamExhausted;
    };
    // A machine now occupies the slot, so a run driver may execute it.
    {
        const reg_if = regLock();
        defer regUnlock(reg_if);
        registry.vcpuStarted(id);
    }

    if (buildinfo.smp) {
        // Spawn the vCPU as an ordinary task and let the scheduler place it
        // (VIRT-021). It pins itself to whatever core it lands on before it
        // touches the VMCS — see vcpuEntry.
        spawnVcpu(id) catch {
            storage[id].deinit();
            ivirt.setState(id, .failed);
            return error.StartFailed;
        };
    } else {
        // No per-core scheduler to hand it to — core 0 both owns and runs this
        // guest, so bring it up here and let `pumpAll` drive it per frame.
        startHere(id) catch |e| {
            last_start_error = @errorName(e);
            klog.puts("virt: guest start failed: ");
            klog.puts(last_start_error);
            klog.puts("\n");
            vmx.disableOnCore(); // drop the reference startHere took
            storage[id].deinit();
            ivirt.setState(id, .failed);
            return error.StartFailed;
        };
    }
    return id;
}

/// Enter VMX operation on the calling core and program the guest's VMCS. The
/// caller always follows up with `disableOnCore`, whatever happens here: a failed
/// `start` leaves the VMX reference taken (so it must be dropped), and a failed
/// `enableOnCore` took none (so dropping it is a no-op). One release path, rather
/// than two that have to agree.
fn startHere(id: ivirt.Id) !void {
    try vmx.enableOnCore();
    try storage[id].start();
}

// ── running ─────────────────────────────────────────────────────────────────

/// Spawn a guest's virtual processor as an ordinary task. The scheduler places
/// it on whichever core is free (VIRT-021, KRN-009); it binds itself there once
/// it starts.
fn spawnVcpu(id: ivirt.Id) !void {
    const t = try sched.spawn("vcpu", vcpuEntry);
    // The guest id rides ON the task (exit_ctx), not through a shared one-slot
    // mailbox: two boots racing a single cell could hand both vCPUs one guest
    // and orphan the other with its slot held forever.
    t.exit_ctx = id;
    sched.dispatch(t);
}

/// A guest's vCPU task: run its guest to completion, then release everything it
/// holds. Returns when the guest has stopped, its memory is freed and its slot is
/// back in the pool — at which point the task exits and the scheduler reaps it.
fn vcpuEntry() void {
    const id: ivirt.Id = @intCast(sched.currentTask().?.exit_ctx);
    // Bind to this core BEFORE touching the VMCS. A VMCS is current on one
    // logical processor at a time (Intel SDM), so from the load onward this task
    // may not be moved — but WHICH core it runs on was the scheduler's free
    // choice a moment ago, which is what VIRT-021 asks for.
    const core = sched.pinHere();
    {
        const reg_if = regLock();
        defer regUnlock(reg_if);
        registry.setCore(id, core);
    }
    const vm = &storage[id];

    if (startHere(id)) {
        // Pump until the guest finishes: budget-sized slices so a stop request is
        // observed promptly, and a proper core halt whenever the guest is idle
        // (KRN-007) rather than a spin through HLT exits.
        while (true) switch (vm.pump(SMP_SLICE_US)) {
            .yielded => {},
            .idle => schedsleep.sleepUntilTsc(vm.nextWakeTsc()),
            .finished => break,
        };
        traceHalted(vm, id);
        vm.deinit();
        ivirt.setState(id, .halted);
    } else |err| {
        // Name the error: "failed to start" alone cannot distinguish a CPU that
        // refuses VMX operation from a VMCS the CPU rejected, and those want
        // completely different fixes.
        klog.puts("virt: guest failed to start on its core: ");
        klog.puts(@errorName(err));
        klog.puts("\n");
        vm.deinit();
        ivirt.setState(id, .failed);
    }
    vmx.disableOnCore();
    // The slot is reusable once its window has also closed. Nothing else has to
    // be given back: this task IS the guest's hold on a processor, and it is
    // about to return and be reaped.
    {
        const reg_if = regLock();
        defer regUnlock(reg_if);
        registry.vcpuDone(id);
    }
}

/// Single-core build: advance every live guest by one slice. Called once per pass
/// of the system loop on core 0, AFTER that pass's input, tick and render work,
/// so a guest can never delay a frame (PERF-003) — it runs in what is left. The
/// slice is SHARED between guests, so two guests cost the desktop no more of the
/// loop than one does; they simply each advance at half the rate. A guest that
/// finishes is torn down here, on the core that ran it.
///
/// No-op on the SMP build, where each guest has its own vCPU task bound to the
/// core that loaded its VMCS — calling it there would touch a VMCS from the
/// wrong core.
pub fn pumpAll() void {
    if (buildinfo.smp) return;
    const live = runningCount();
    if (live == 0) return;
    const slice = LOOP_SLICE_US / live;
    var all_idle = true;
    var wake: u64 = ~@as(u64, 0);
    var id: ivirt.Id = 0;
    while (id < ivirt.MAX_VMS) : (id += 1) {
        if (!registry.isRunning(id)) continue;
        const vm = &storage[id];
        if (comptime buildinfo.test_hooks) traceProgress(vm, id);
        switch (vm.pump(slice)) {
            // The guest used its whole slice: it has work, so this core does.
            .yielded => all_idle = false,
            // Parked in HLT. It becomes runnable again only at its own next
            // wake time, so remember the earliest of those.
            .idle => wake = @min(wake, vm.nextWakeTsc()),
            .finished => {
                traceHalted(vm, id);
                vm.deinit();
                ivirt.setState(id, .halted);
                vmx.disableOnCore();
                {
                    const reg_if = regLock();
                    defer regUnlock(reg_if);
                    registry.vcpuDone(id);
                }
            },
        }
    }
    idle_wake_tsc = if (all_idle and wake != ~@as(u64, 0)) wake else null;
}

/// When the earliest parked guest must be looked at again, or null when some
/// guest is runnable now. Written by `pumpAll`, read by `mayHaltCore`.
var idle_wake_tsc: ?u64 = null;

/// How many guests are live and need pumping.
fn runningCount() u64 {
    var n: u64 = 0;
    var id: ivirt.Id = 0;
    while (id < ivirt.MAX_VMS) : (id += 1) {
        if (registry.isRunning(id)) n += 1;
    }
    return n;
}

/// Whether any guest is live.
pub fn anyRunning() bool {
    return runningCount() != 0;
}

/// Whether core 0 may sleep until the next interrupt: no guest is live, or
/// every live guest is parked in HLT and none is due to wake yet.
///
/// A guest sitting in HLT is not work. Re-entering it produces another HLT exit
/// and nothing else, so treating "a guest exists" as "this core has work" is
/// what turns one idle guest into a core pinned at 100% — the system loop spun
/// something like a hundred and fifty thousand times a second to collect a
/// hundred and fifty thousand HLT exits, and the desktop shared what was left.
/// A parked guest is woken by the same timer interrupt this core sleeps on.
pub fn mayHaltCore() bool {
    if (!anyRunning()) return true;
    const wake = idle_wake_tsc orelse return false;
    return tsc.rdtsc() < wake;
}

// ── stopping ────────────────────────────────────────────────────────────────

/// Whether slot `id` names a guest that is running and can be asked to stop —
/// the console's guard before it acts on a user-supplied id.
pub fn stoppable(id: ivirt.Id) bool {
    if (id >= ivirt.MAX_VMS) return false;
    return registry.isRunning(id);
}

/// Ask the guest in slot `id` to stop. It halts at its next VM exit boundary and
/// its own core reclaims its memory; this call never blocks and never frees
/// anything itself. Safe on a slot whose guest has already halted.
pub fn requestStop(id: ivirt.Id) void {
    ivirt.requestStop(id);
}

/// Core 0: the console window onto slot `id` has closed. Requests the stop (a
/// hidden guest has no surface and would pin a core) and drops the window's hold
/// on the slot. It frees nothing and never blocks: the guest's own core does the
/// teardown, drops the other hold, and hands the core back. Safe to call at any
/// point in a guest's life — before it has started, while it runs, or long after
/// it halted by itself.
pub fn windowClosed(id: ivirt.Id) void {
    // Closing the window of a slot whose image is still DOWNLOADING cancels the
    // netboot: without this, the slot goes free while the fetch is in flight,
    // a fresh `vm boot` can reclaim it, and the stale fetch's completion would
    // then build a second machine over the live guest's storage. All netboot
    // state and this call run on the system task, so a flag is enough; the
    // fetch callbacks check `active` before touching anything.
    if (netboot.active and netboot.id == id) {
        if (netboot.kernel) |k| heap.allocator().free(k);
        netboot.kernel = null;
        netboot.active = false;
        klog.puts("virt: image boot cancelled (window closed mid-fetch)\n");
    }
    requestStop(id);
    {
        const reg_if = regLock();
        defer regUnlock(reg_if);
        registry.windowClosed(id);
    }
}

/// A once-a-second line saying whether a guest is making progress: its exit
/// count, the reason for its last exit, and where it is. `-Dtest-hooks` only.
///
/// A guest with no console output is otherwise indistinguishable from a guest
/// that never ran — this is what tells the two apart on a machine whose only
/// readback is the trace bus.
/// How often the progress line is emitted. Often enough to see a guest stop,
/// rare enough that it never crowds the guest's own console off the wire.
const TRACE_EVERY_MS: u64 = 5000;

var trace_last_ms: [ivirt.MAX_VMS]u64 = [_]u64{0} ** ivirt.MAX_VMS;

/// One line whenever a guest stops, on every build. A guest can end for reasons
/// that already announced themselves loudly (a triple fault, an unemulated
/// device) and for reasons that are simply the end of its life (its own HLT with
/// interrupts off, a requested stop), and the two are told apart by the numbers
/// here: how many exits it managed, and what the last one was. Without it a guest
/// that vanishes leaves nothing at all behind.
fn traceHalted(vm: *machine.Vm, id: ivirt.Id) void {
    klog.puts("virt: vm");
    klog.putHex(id);
    klog.puts(" halted after exits=");
    klog.putHex(vm.vcpu.exits);
    klog.puts(" last reason=");
    klog.putHex(vm.vcpu.last_exit_reason);
    klog.puts(" rip=");
    klog.putHex(vm.vcpu.last_exit_rip);
    klog.puts(" vmx_faults=");
    klog.putHex(vm.vcpu.vmx_faults);
    klog.puts(" vmcs_reloads=");
    klog.putHex(vm.vcpu.vmcs_reloads);
    klog.puts("\n");
}

fn traceProgress(vm: *machine.Vm, id: ivirt.Id) void {
    const now = timer.millis();
    if (now -% trace_last_ms[id] < TRACE_EVERY_MS) return;
    trace_last_ms[id] = now;
    klog.puts("virt: vm sw=");
    klog.putHex(vm.serial_writes);
    klog.puts(" e=");
    klog.putHex(vm.vcpu.exits);
    klog.puts(" l=");
    klog.putHex(vm.vcpu.last_exit_reason);
    klog.puts(" rip=");
    klog.putHex(vm.vcpu.last_exit_rip);
    klog.puts("\n");
    klog.puts("virt: vm rsp=");
    klog.putHex(vm.vcpu.last_exit_rsp);
    klog.puts("\n");
    // delay_tsc()'s live state: %r9 is the cycle target it waits for and %rdi
    // the base TSC it started from, so these two numbers say whether a guest
    // "hung" in a delay loop is actually waiting an absurd number of cycles
    // (a TSC-frequency lie) or waiting on a TSC that stopped advancing.
    klog.puts("virt: vm r9=");
    klog.putHex(vm.vcpu.regs.r9);
    klog.puts(" rdi=");
    klog.putHex(vm.vcpu.regs.rdi);
    klog.puts(" tsc_hz=");
    klog.putHex(tsc.hz());
    klog.puts("\n");
    // The per-reason ranking: one LINE per nonzero bucket (a single line
    // overflows the trace record cap and truncates exactly the counts that
    // matter), plus the last IO port — which device a polling guest bangs on.
    for (vm.vcpu.exit_counts, 0..) |n, r| {
        if (n == 0) continue;
        klog.puts("virt: vm exit r=");
        klog.putHex(r);
        klog.puts(" n=");
        klog.putHex(n);
        klog.puts("\n");
    }
    klog.puts("virt: vm last io port=");
    klog.putHex(vm.io_last_port);
    klog.puts(" ram hpa=");
    klog.putHex(vm.mem.ram_hpa);
    klog.puts("\n");
    for (vm.wrmsr_log[0..vm.wrmsr_seen], 0..) |m, i| {
        klog.puts("virt: vm wrmsr[");
        klog.putHex(i);
        klog.puts("]=");
        klog.putHex(m);
        klog.puts("\n");
    }
}
