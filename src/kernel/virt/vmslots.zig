//! The VM registry: which mailbox slot each live guest owns, which core it runs
//! on, and when a retired slot may be handed to a new guest. Pure atomic logic
//! with NO kernel imports, so the retirement handshake is host-testable
//! (test/kernel/virt/vmslots_test.zig); the kernel wiring — guest memory, the vCPU task, the
//! console window — lives in virt.zig, the single consumer.
//!
//! The handshake this encodes (the "slot retirement" protocol):
//! a slot is held by TWO owners that begin and finish at different times and on
//! different cores — the console WINDOW (core 0, which reads the slot's lifecycle
//! state and console stream for as long as it is open) and the VCPU (an
//! application core, which writes them until it has torn its guest down). A slot
//! becomes reusable only once BOTH have let go:
//!
//!   claim        core 0   window_open  = true    (the slot is reserved)
//!   vcpuStarted  core 0   vcpu_running = true    (a machine now exists to run)
//!   windowClosed core 0   window_open  = false   (the window was torn down)
//!   vcpuDone     vCPU     vcpu_running = false   (memory freed, VMXOFF done)
//!   free    ⇔ !window_open and !vcpu_running
//!
//! Releasing on either event alone is the bug this prevents: retire on vCPU exit
//! and a still-open window onto a halted guest would start showing a NEW guest's
//! console the moment one starts; retire on window close and the outgoing vCPU
//! would write its final bytes into a mailbox the next guest already owns.
//!
//! The two holds are taken separately, and that is the point. A slot is reserved
//! long before its guest can run: a network boot claims one the instant its
//! download starts and only builds a machine two fetch callbacks later. So
//! `vcpu_running` means "a built machine occupies this slot", never merely "this
//! slot is taken" — it is the predicate a run driver uses to decide whether the
//! slot may be executed, and a slot reserved for a guest that does not exist yet
//! must read false or the driver runs a VMCS that was never written.
//!
//! `claim` and `vcpuStarted` are called only from core 0, so picking a free slot
//! needs no CAS — the acquire load of `vcpu_running` is what orders the previous
//! guest's teardown before its slot is reused.

/// A registry over `max_vms` slots. `max_vms` comes from the mailbox that the
/// slots index (iface/ivirt.zig `MAX_VMS`) — the one home for how many guests
/// can exist at once.
/// A slot whose guest has not yet bound itself to a processor. Distinct from
/// core 0, which is an ordinary core like any other (ARCH-016) and therefore
/// cannot double as "no core".
pub const NO_CORE: u32 = 0xFFFF_FFFF;

pub fn Registry(comptime max_vms: usize) type {
    return struct {
        const Self = @This();

        /// The console window onto this slot's guest is still open. Set the
        /// moment the slot is reserved, so a slot whose guest is still
        /// downloading is held against reuse even though nothing runs in it.
        window_open: [max_vms]bool,
        /// A built machine occupies this slot and its vCPU has not yet finished
        /// tearing it down. False for a slot that is merely reserved.
        vcpu_running: [max_vms]bool,
        /// The core the slot's guest bound itself to, or NO_CORE until its vCPU
        /// has started. Written once by that vCPU (`setCore`); read for display,
        /// and by status listings.
        core: [max_vms]u32,

        /// Fresh registry: every slot free, no cores assigned.
        pub const init: Self = .{
            .window_open = [_]bool{false} ** max_vms,
            .vcpu_running = [_]bool{false} ** max_vms,
            .core = [_]u32{NO_CORE} ** max_vms,
        };

        /// Whether slot `id` is free — neither owner holds it. Acquire on
        /// `vcpu_running` pairs with `vcpuDone`'s release, so a free result
        /// implies the previous guest's teardown is fully visible.
        pub fn isFree(self: *Self, id: usize) bool {
            return !self.window_open[id] and
                !@atomicLoad(bool, &self.vcpu_running[id], .acquire);
        }

        /// Whether slot `id` holds a built machine whose vCPU has not finished —
        /// the predicate a status listing and the stop path use to tell a live
        /// guest from one that has already halted, and the predicate a run
        /// driver uses to decide the slot is safe to execute. False for a slot
        /// reserved for a guest that is still being fetched or built.
        pub fn isRunning(self: *Self, id: usize) bool {
            return @atomicLoad(bool, &self.vcpu_running[id], .acquire);
        }

        /// Whether slot `id` is in use by either owner (live guest, or a halted
        /// guest whose window is still open).
        pub fn inUse(self: *Self, id: usize) bool {
            return !self.isFree(id);
        }

        /// Reserve the lowest free slot, or null when every slot is in use. Only
        /// the WINDOW hold is taken; the slot reads as reserved but not running,
        /// because no machine exists in it yet. The caller must hand the id to a
        /// window and later call `vcpuStarted`, or give the slot straight back
        /// with `abandon`.
        ///
        /// No core is chosen here. Which processor a guest ends up on is the
        /// scheduler's decision when it places the vCPU task, and the vCPU
        /// records it with `setCore` once it has bound itself (VIRT-021).
        pub fn claim(self: *Self) ?usize {
            var id: usize = 0;
            while (id < max_vms) : (id += 1) {
                if (!self.isFree(id)) continue;
                self.core[id] = NO_CORE;
                self.window_open[id] = true;
                return id;
            }
            return null;
        }

        /// The vCPU: record the core it bound itself to, for the status line and
        /// the window title. Written once, before the guest starts running.
        pub fn setCore(self: *Self, id: usize, core: u32) void {
            @atomicStore(u32, &self.core[id], core, .release);
        }

        /// Core 0: slot `id` now holds a built machine, so its vCPU may run.
        /// Release: the machine's construction and the core assignment above
        /// must both be visible to the vCPU — which finds itself by core — before
        /// the slot reads as running.
        pub fn vcpuStarted(self: *Self, id: usize) void {
            @atomicStore(bool, &self.vcpu_running[id], true, .release);
        }

        /// Core 0: the console window onto slot `id` has been torn down. The slot
        /// becomes reusable once its vCPU also finishes.
        pub fn windowClosed(self: *Self, id: usize) void {
            self.window_open[id] = false;
        }

        /// The vCPU (on its own core): this guest is fully torn down — memory
        /// freed, VMX left. Release so that teardown is visible before core 0 can
        /// observe the slot free and reuse it.
        pub fn vcpuDone(self: *Self, id: usize) void {
            @atomicStore(bool, &self.vcpu_running[id], false, .release);
        }

        /// Core 0: give back a slot claimed for a guest that never started (VM
        /// creation failed), releasing both holds at once. Sound only before any
        /// vCPU has been started for the slot — otherwise the vCPU is the one
        /// owner that must release its own hold.
        pub fn abandon(self: *Self, id: usize) void {
            self.window_open[id] = false;
            @atomicStore(bool, &self.vcpu_running[id], false, .release);
        }

        /// The core slot `id`'s guest is bound to, or null when the slot is free
        /// or its vCPU has not started yet.
        pub fn coreOf(self: *Self, id: usize) ?u32 {
            if (self.isFree(id)) return null;
            const c = @atomicLoad(u32, &self.core[id], .acquire);
            return if (c == NO_CORE) null else c;
        }

        /// How many slots are in use (live guests plus halted guests whose window
        /// is still open) — the `vm` status line's total.
        pub fn inUseCount(self: *Self) usize {
            var n: usize = 0;
            var id: usize = 0;
            while (id < max_vms) : (id += 1) {
                if (self.inUse(id)) n += 1;
            }
            return n;
        }
    };
}
