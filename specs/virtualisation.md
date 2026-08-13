# Virtualisation

Hardware virtualisation in the Kudos system: guest virtual machines, their boot
and devices, the VM console window, and bridged guest networking.

## Virtualization

**VIRT-001.** The Kudos system shall run a guest operating system in a hardware
virtual machine using the CPU's virtualization extensions, when the hardware
provides them.

**VIRT-002.** The Kudos system shall isolate guest memory from host memory using
second-level (nested) address translation.

**VIRT-003.** The Kudos system shall boot an unmodified Linux kernel image through
the Linux/x86 64-bit boot protocol.

**VIRT-004.** The Kudos system shall provide the guest its entire root filesystem
from an initial RAM filesystem resident in guest memory.

**VIRT-005.** The Kudos system shall provide the guest a 16550-compatible serial
port as its console.

**VIRT-007.** The Kudos system shall handle guest exits without allocating memory.

**VIRT-008.** The Kudos system shall provide the guest time-stamp-counter
timekeeping consistent with the host counter.

**VIRT-009.** The Kudos system shall report a general-protection fault to the guest
for an access to a model-specific register it does not emulate.

**VIRT-010.** The Kudos system shall present the guest's serial console and lifecycle
state in a desktop application window (APP-001).

**VIRT-011.** The Kudos system shall deliver keystrokes from the VM console window
(VIRT-010) to the guest serial port (VIRT-005).

**VIRT-012.** The Kudos system shall reject a guest-supplied virtqueue descriptor
that references memory outside the guest region.

**VIRT-013.** The Kudos system shall provide the guest a 2D virtio-gpu scanout.

**VIRT-014.** The Kudos system shall reclaim all guest memory when the guest is
stopped.

**VIRT-015.** The Kudos system shall surface a guest panic or reboot as a reported
guest exit, never as a Kudos fault.

**VIRT-016.** The Kudos system shall display the guest's scanout (VIRT-013) inside
the VM console window (VIRT-010).

**VIRT-017.** The Kudos system shall start and stop guests through shell
commands (APP-002) in a terminal session (APP-001).

**VIRT-019.** The Kudos system shall load a guest's kernel and initial RAM
filesystem over the network by HTTP into guest memory, exposing no storage
device to the guest (VIRT-004).

**VIRT-020.** The Kudos system shall list the bootable guest images as a
numbered catalog from the shell (VIRT-017), each bootable by its number.

**VIRT-021.** The Kudos system shall run each guest virtual processor as a
schedulable task, eligible for any online core (KRN-009).

**VIRT-022.** The Kudos system shall present the guest a keyboard input device.

**VIRT-023.** The Kudos system shall deliver both the press and the release of a
key from the VM console window (VIRT-010) to the guest keyboard (VIRT-022).

**VIRT-024.** The Kudos system shall present the guest an absolute pointing
device.

**VIRT-025.** The Kudos system shall deliver the pointer's position within the
VM console window (VIRT-010) to the guest pointing device (VIRT-024).

**VIRT-026.** The Kudos system shall deliver pointer button presses and releases
from the VM console window (VIRT-010) to the guest pointing device (VIRT-024).

**VIRT-027.** The Kudos system shall provide the guest a network device with a
link-layer address unique among the host and its guests.

**VIRT-028.** The Kudos system shall forward frames the guest transmits
(VIRT-027) to the physical network.

**VIRT-029.** The Kudos system shall deliver to the guest the physical
network's frames addressed to the guest's link-layer address (VIRT-027), and
its broadcast and multicast frames.

**VIRT-030.** The Kudos system shall count bridged frames it discards
(VIRT-028, VIRT-029), in each direction, per guest.

**VIRT-031.** The Kudos system shall deliver frames a guest transmits (VIRT-027)
that are addressed to the host or to another guest without their reaching the
physical network.

**VIRT-032.** The Kudos system shall forward a frame a guest transmits
(VIRT-027) to every destination except the guest that transmitted it.

**VIRT-033.** The Kudos system shall discard frames a guest transmits whose
source is not that guest's link-layer address (VIRT-027).

**VIRT-034.** The Kudos system shall present each guest the floating-point and
vector register values it last held, on every resumption of that guest.

**VIRT-035.** The Kudos system shall repaint the VM console window (VIRT-010) on
every frame the guest draws into its scanout (VIRT-013).

**VIRT-036.** The Kudos system shall deliver keystrokes to the guest serial port
(VIRT-011) in the order they were typed.

**VIRT-037.** The Kudos system shall present each guest a block device, backed
by system memory, that the guest can read and write by sector.

**VIRT-038.** The Kudos system shall refuse, in whole, a guest block-device
(VIRT-037) request addressing any sector outside that device.
