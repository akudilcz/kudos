//! Machine power control. Single source of truth for reset.
//! `reboot()` walks a chain of reset mechanisms (8042 pulse → triple fault →
//! halt) and never returns.

const std = @import("std");
const io = @import("../../drivers/io/io.zig");
const ps2 = @import("../../drivers/io/ps2.zig");
const wait = @import("../../drivers/io/wait.zig");
const tsc = @import("../cpu/tsc.zig");
const cpu = @import("../cpu/cpu.zig");

const RESET: u8 = 0xFE; // 8042 "pulse output line" command → CPU reset
const DRAIN_SPINS: u32 = 100_000; // bound for the 8042 input-buffer drain

// PCI reset control register (the "CF9" reset) — the reset method to rely on.
//
// The older 8042 keyboard-controller pulse is tried first for compatibility, but it
// cannot be trusted alone: on a modern board the PS/2 controller is emulated by
// firmware and may not be wired to the reset line at all, so it silently swallows the
// 0xFE and the machine simply keeps running. A reset chain that ENDS at 8042 is a reset
// chain that can fail to reset.
//
// CF9 is a two-step: arm with SYS_RST (bit 1), then commit with RST_CPU|FULL_RST. A
// single write does nothing. (This is the sequence Linux drives in
// native_machine_emergency_restart.)
const CF9: u16 = 0x0CF9;
const CF9_SYS_RST: u8 = 0x02; // request a reset
const CF9_FULL_RST: u8 = 0x0E; // SYS_RST | RST_CPU (0x04) | FULL_RST (0x08) → cold reset

/// Predicate adapter: reports whether the 8042 input buffer has drained, in the
/// `(ctx) -> bool` shape `wait.until` expects (the void context is unused).
fn inputEmpty(_: void) bool {
    return ps2.inputEmpty();
}

/// Set by the `shutdown` terminal command; polled by the GPU session loop and
/// the system loop, which perform an orderly teardown then call poweroff().
pub var shutdown_requested: bool = false;

/// Pre-reset flush, wired by main at init (spec R51): drains the trace and
/// syncs pending storage writes so every FAT volume stays valid across an
/// orderly reboot or power-off. A hook, not an import — power control sits
/// below the storage drivers and must not name them. Runs at most once even
/// if the flush itself ends up back here (a wedged flush must not recurse).
pub var flush_hook: ?*const fn () void = null;
var flushed = false;

fn flushOnce() void {
    if (flushed) return;
    flushed = true;
    if (flush_hook) |hook| hook();
}

/// Power the machine off (QEMU pc: ACPI PM1a_CNT at port 0x604, SLP_TYP=S5 |
/// SLP_EN = 0x2000). Falls through to a permanent halt if the write does not
/// power off (non-QEMU board — poweroff needs full ACPI there).
pub fn poweroff() noreturn {
    flushOnce();
    asm volatile ("cli");
    io.outw(0x604, 0x2000);
    cpu.parkMasked();
}

/// How long a crashed boot core holds its record on screen before the reset.
/// Long enough for the netdebug flush to land and a human at the monitor to
/// read the fault; short enough that an unattended machine returns to its
/// fallback OS (the boot one-shot) on its own.
pub const CRASH_HOLD_MS: u64 = 60_000;

/// Terminal state for an unrecoverable boot-core fault or panic: hold the
/// crash for CRASH_HOLD_MS, then reset. Under the one-shot boot model any
/// reset falls back to the recovery OS, so a crashed remote machine comes
/// back on the network by itself instead of halting until someone walks to
/// the power button. Before TSC calibration there is no trustworthy delay —
/// reset immediately; the crash record is already flushed by the caller.
pub fn crashReboot() noreturn {
    asm volatile ("cli");
    if (tsc.hz() != 0) tsc.udelay(CRASH_HOLD_MS * std.time.us_per_ms);
    reboot();
}

/// Reset the machine and never return. Tries reset mechanisms in descending
/// reliability — 8042 pulse, then a null-IDT triple fault, then a permanent
/// halt — so a board missing any one path still ends up reset or safely stopped.
pub fn reboot() noreturn {
    flushOnce();
    // IRQs are live from boot — mask them so nothing fires mid-reset.
    asm volatile ("cli");

    // 1) 8042 pulse reset. Wait (bounded) for the controller input buffer to
    //    drain so the command write is accepted; on a machine with no 8042 the
    //    wait times out and we fall through to the methods below.
    _ = wait.until({}, inputEmpty, wait.noop, DRAIN_SPINS, "8042 input buffer empty (reboot)");
    io.outb(ps2.COMMAND, RESET);
    io.wait();

    // 2) CF9 PCI reset — the method modern boards actually implement (lemon among
    //    them; see the CF9 constants). Read-modify-write so we don't disturb the
    //    other bits, arm, then commit. io.wait() between the two writes gives the
    //    PCH the settle the two-step needs.
    const cf9 = io.inb(CF9) & ~CF9_FULL_RST;
    io.outb(CF9, cf9 | CF9_SYS_RST);
    io.wait();
    io.outb(CF9, cf9 | CF9_FULL_RST);
    io.wait();

    // 3) Triple fault: a null IDT means the CPU cannot dispatch int3, escalating
    //    to a triple fault that resets the platform.
    const NullIdtr = packed struct { limit: u16, base: u64 };
    const idtr = NullIdtr{ .limit = 0, .base = 0 };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idtr),
        : .{ .memory = true });
    asm volatile ("int3");

    // 4) Last resort: hung-but-safe rather than running on in an undefined state.
    cpu.parkMasked();
}
