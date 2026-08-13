# Kernel

The platform bring-up and kernel core of the Kudos system: network boot,
symmetric multiprocessing and scheduling, timekeeping, virtual memory and
address-space isolation, and USB peripherals.

## Boot

**BOOT-001.** The Kudos system shall support booting its kernel over the
network.

**BOOT-002.** The Kudos system shall boot, when booted over the network
(BOOT-001), the kernel image most recently staged to its boot server.

## Kernel

**KRN-001.** The Kudos system shall support symmetric multiprocessing (SMP),
scheduling work across all available CPU cores.

**KRN-004.** The Kudos system shall maintain wall-clock time, initialised from the
platform's real-time clock at boot.

**KRN-005.** The Kudos system shall account the exact CPU time consumed by each
task.

**KRN-006.** The Kudos system shall contain any application failure to its own
terminal session (APP-001), never disrupting the desktop or other sessions.

**KRN-007.** The Kudos system shall halt an idle core in a low-power state until
work arrives for it.

**KRN-008.** The Kudos system shall provide periodic task sleeps against
absolute deadlines, so that a periodic task accumulates no drift.

**KRN-009.** The Kudos system shall make every online core eligible to run every
runnable task, reserving no core for a particular task or role.

**KRN-010.** The Kudos system shall dispatch a task that becomes runnable to an
idle core whenever one is idle, so that no core stays idle while a task waits to
run.

**KRN-011.** The Kudos system shall run one and the same task on any core over its
lifetime, confining its execution to no single core.

**KRN-012.** The Kudos system shall deliver a device's interrupts to any online
core, confining no device's interrupts to one core.

## Memory

**MEM-001.** The Kudos system shall provide multiple virtual address spaces, each
mapping virtual addresses to physical memory independently of the others.

**MEM-002.** The Kudos system shall give each terminal session (APP-001) its own
virtual address space (MEM-001).

**MEM-003.** The Kudos system shall make the memory private to one virtual address
space (MEM-001) unreachable from every other address space.

**MEM-004.** The Kudos system shall hold each terminal session's memory private to
that session's address space (MEM-002, MEM-003).

**MEM-005.** The Kudos system shall report an access to memory not mapped in the
executing address space (MEM-001) as a fault, counted in its diagnostics (DIAG-002).

**MEM-006.** The Kudos system shall contain a memory-access fault (MEM-005) to the
terminal session whose address space faulted, never disrupting the desktop or other
sessions (KRN-006).

**MEM-007.** The Kudos system shall reclaim every physical page an address space
holds when that address space ends (MEM-002).

**MEM-008.** The Kudos system shall account the physical memory each address space
(MEM-001) holds.

**MEM-009.** The Kudos system shall switch between address spaces (MEM-001) without
allocating memory.

**MEM-010.** The Kudos system shall detect a task's stack overflow as a fault
(MEM-005), never letting it overwrite memory outside that stack.

**MEM-011.** The Kudos system shall report a task that has overflowed its stack,
naming the task.

## Peripherals

**PER-001.** The Kudos system shall support a USB mouse.

**PER-002.** The Kudos system shall support a USB keyboard.

**PER-003.** The Kudos system shall support a USB mass-storage drive.

**PER-004.** The Kudos system shall support USB devices attached through external
USB hubs.

**PER-005.** The Kudos system shall support a USB tablet reporting absolute
pointer position.
