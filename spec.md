# Kudos System Specification

The cardinal specification for the Kudos system.

Kudos is a real-time operating system — its slogan: **"microseconds matter"**.
It aims to minimise latency and jitter throughout, and holds a smooth user
experience as the standard every performance requirement below is written
against. What a given build actually achieves is what the performance tests
report, never what this page asserts.

This specification is the baseline: it lists the core features and performance
Kudos must have. The implementation may provide more than the spec requires;
anything beyond the spec is never a deviation — only an unmet requirement is.

Each requirement carries a stable identifier of the form `PREFIX-NNN`, where
the prefix names its section (AGT, NET, DSK, ...) and the number runs from 001
within that section — so a section numbers independently and a new requirement
appends to its section without renumbering any other. A requirement moved to
another section or withdrawn retires its identifier; an identifier is never
reused. Each requirement is stated in the form "The Kudos system shall ...",
and is binding. A requirement states what the system does, or the performance
it achieves — never how it is implemented. Naming an external standard, format,
or conformance suite is part of the what.

Requirements are grouped into functional requirements (what the system does)
and non-functional requirements (the architecture, platform, and performance
envelope it does it within). Sections run bottom-up: platform bring-up and
kernel first, then devices, storage, and networking, then rendering and the
desktop, then the applications and agent built on top.

# Functional requirements

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

## Storage

**STO-001.** The Kudos system shall maintain a ramdisk providing in-memory file
storage.

**STO-002.** The Kudos system shall unify access to all mounted stores behind a
single virtual file system, independent of the backing device.

**STO-003.** The Kudos system shall support the FAT32 file system.

**STO-004.** The Kudos system shall locate FAT32 volumes (STO-003) via the MBR
partition table.

**STO-005.** The Kudos system shall read VFAT long file names (STO-003).

**STO-006.** The Kudos system shall keep every FAT32 volume it writes (STO-003) valid,
such that the volume mounts on a stock Linux kernel.

**STO-007.** The Kudos system shall flush all pending file-system writes before
any reboot or power-off, so that every volume remains valid (STO-006).

**STO-008.** The Kudos system shall create, overwrite and delete ramdisk
(STO-001) files through the virtual file system (STO-002).

**STO-009.** The Kudos system shall present ramdisk (STO-001) files in a
hierarchy of directories, which it shall create and delete.

**STO-010.** The Kudos system shall refuse a write to a read-only store
(STO-002), stating that the store is read-only.

## Networking

**NET-001.** The Kudos system shall obtain its network configuration via DHCP.

**NET-002.** The Kudos system shall support UDP communication over its network
stack.

**NET-003.** The Kudos system shall support TCP communication over its network
stack.

**NET-004.** The Kudos system shall answer ARP requests for its own address.

**NET-005.** The Kudos system shall resolve next-hop link-layer addresses via
ARP.

**NET-006.** The Kudos system shall reply to ICMP echo requests.

**NET-007.** The Kudos system shall originate ICMP echo requests, reporting
round-trip time.

**NET-008.** The Kudos system shall resolve host names via DNS (NET-002).

**NET-009.** The Kudos system shall provide an HTTP client fetching resources by
URL (NET-003).

**NET-010.** The Kudos system shall establish TLS 1.3 encrypted connections.

**NET-011.** The Kudos system shall verify the certificate chain of every HTTPS
connection against a trusted certificate-authority set.

**NET-013.** The Kudos system shall support the HTTP POST method with a request
body and caller-supplied headers.

**NET-014.** The Kudos system shall receive server-sent-event streams.

**NET-015.** The Kudos system shall fail an HTTPS connection loudly when its clock
cannot establish certificate validity (NET-011), never bypassing verification.

**NET-016.** The Kudos system shall deliver received stream bytes to a reader as
soon as any are available, never waiting for the reader's buffer to fill.

**NET-017.** The Kudos system shall report the cause of a failed encrypted
connection (NET-010), distinguishing a cryptographic failure from a transport
failure.

**NET-018.** The Kudos system shall use its network stack correctly when
requests originate from more than one task.

**NET-019.** The Kudos system shall continue rendering the desktop (DSK-001) at
its stated frame rate (PERF-003) while a network request is outstanding.

**NET-020.** The Kudos system shall end an encrypted connection (NET-010) that
exceeds a stated total duration, however much progress it makes.

## Images

**IMG-001.** The Kudos system shall decode PNG images into its native pixel
format.

**IMG-002.** The Kudos system shall encode images from its native pixel format
into PNG.

## Rendering

**RND-001.** The Kudos system shall render its desktop through OpenGL ES 1.1 with extensions.

**RND-002.** The Kudos system shall drive the display at its native resolution.

**RND-003.** The Kudos system shall provide kgl, a 2D drawing library presenting a
small vocabulary of shapes, images, and text.

**RND-004.** The Kudos system shall render geometry indexed with 32-bit vertex
indices via the OES_element_index_uint extension to its OpenGL ES 1.1 pipeline
(RND-001), so a model may exceed the 65,536 vertices a 16-bit index reaches.

**RND-005.** The Kudos system shall attach glTF material maps —
metallic-roughness, normal, occlusion, and emissive — to a lit draw via the
GL_KUDOS_material_maps extension to its OpenGL ES 1.1 pipeline (RND-001), so
models render their physically-based materials (APP-011).

**RND-006.** The Kudos system shall provide the OpenGL ES 1.1
profile-mandatory extensions — OES_read_format,
OES_compressed_paletted_texture, OES_point_size_array, and OES_point_sprite —
in its pipeline (RND-001).

**RND-007.** The Kudos system shall advertise every extension its OpenGL
ES 1.1 pipeline (RND-001) provides in the GL_EXTENSIONS string, each captured
as a requirement in this specification.

**RND-008.** The Kudos system shall accept blue-first 32-bit pixel data via
the EXT_texture_format_BGRA8888 extension to its OpenGL ES 1.1 pipeline
(RND-001), so its image decoders' native output uploads without a per-texel
channel swap.

**RND-009.** The Kudos system shall draw text at any pixel size a caller
requests, from the outlines of the typeface it ships.

**RND-010.** The Kudos system shall antialias the glyph coverage of the text it
draws (RND-009).

**RND-011.** The Kudos system shall report the horizontal advance and vertical
metrics of text drawn at a given size (RND-009), so a caller may lay text out
before drawing it.

**RND-012.** The Kudos system shall render the desktop through a software
implementation of its OpenGL ES 1.1 pipeline (RND-001) on a machine where the
GPU required by PLAT-001 is absent.

**RND-013.** The Kudos system shall show the software-rendered desktop
(RND-012) on the framebuffer the firmware provides.

## Desktop

**DSK-001.** The Kudos system shall present a PNG image as the desktop background.

**DSK-002.** The Kudos system shall use the image at assets/media/background.png
as the default desktop background (DSK-001).

**DSK-003.** The Kudos system shall allow the user to change the desktop background
(DSK-001) by selecting a PNG from a USB mass-storage drive (PER-003).

**DSK-004.** The Kudos system shall decorate every window with chrome: a rounded
window body, a title bar, and window controls.

**DSK-005.** The Kudos system shall provide close, minimise, and zoom controls in
every window's chrome (DSK-004).

**DSK-006.** The Kudos system shall render the window controls (DSK-005) as
macOS-style traffic lights: red, amber, and green discs at the left of the
title bar.

**DSK-007.** The Kudos system shall centre each window's title in its title bar.

**DSK-008.** The Kudos system shall give each window body a frosted, translucent
appearance.

**DSK-009.** The Kudos system shall render window chrome anti-aliased.

**DSK-010.** The Kudos system shall decorate all application windows with
identical window chrome (DSK-004), regardless of the application.

**DSK-011.** The Kudos system shall let the user move a window by dragging its
title bar.

**DSK-012.** The Kudos system shall let the user resize a window by dragging its
edges or corner grip.

**DSK-013.** The Kudos system shall zoom a window to full screen via its zoom
control (DSK-005), restoring the prior geometry on the next zoom.

**DSK-014.** The Kudos system shall hide a window via its minimise control (DSK-005).

**DSK-015.** The Kudos system shall raise and focus a window when the user clicks
it.

**DSK-016.** The Kudos system shall provide a dock: a floating bar of tiles at the
bottom of the desktop that launches applications.

**DSK-017.** The Kudos system shall mark, on its dock tile (DSK-016), each application
that is running.

**DSK-019.** The Kudos system shall accelerate pointer motion adaptively with
speed.

**DSK-020.** The Kudos system shall open a new terminal (APP-001) via a global
keyboard shortcut, regardless of window focus.

**DSK-021.** The Kudos system shall redraw a window whose content varies with
time in whole, never in part, in any frame that redraws any of it.

## Heads-up display

**HUD-001.** The Kudos system shall provide a heads-up display presenting the
state of the machine's processors, memory, graphics, storage, network and
diagnostic counters together on one screen.

**HUD-002.** The Kudos system shall show and hide the heads-up display (HUD-001)
via a global keyboard shortcut, regardless of window focus.

**HUD-003.** The Kudos system shall draw the heads-up display (HUD-001) above the
desktop and its windows, leaving the state of those windows unchanged.

**HUD-004.** The Kudos system shall present the processor's make in the heads-up
display (HUD-001).

**HUD-005.** The Kudos system shall present the number of processor cores online
in the heads-up display (HUD-001).

**HUD-006.** The Kudos system shall present each core's occupancy over the last
sampling interval in the heads-up display (HUD-001).

**HUD-007.** The Kudos system shall present the task scheduled on each core in the
heads-up display (HUD-001).

**HUD-008.** The Kudos system shall present the number of tasks waiting to run on
each core in the heads-up display (HUD-001).

**HUD-009.** The Kudos system shall present total, used and free physical memory
in the heads-up display (HUD-001).

**HUD-010.** The Kudos system shall present physical memory divided by the purpose
each region is held for, in the heads-up display (HUD-001).

**HUD-011.** The Kudos system shall present the kernel heap's size, used and free
bytes in the heads-up display (HUD-001).

**HUD-012.** The Kudos system shall present the largest allocation the kernel heap
could still satisfy, in the heads-up display (HUD-001).

**HUD-015.** The Kudos system shall present the display's present rate and the
number of frames dropped, in the heads-up display (HUD-001).

**HUD-016.** The Kudos system shall present each mounted volume and the bytes it
holds in the heads-up display (HUD-001).

**HUD-017.** The Kudos system shall present the network link state and address
lease in the heads-up display (HUD-001).

**HUD-018.** The Kudos system shall present the guest virtual machine's state and
exit rate while a guest is running (VIRT-001), in the heads-up display (HUD-001).

**HUD-019.** The Kudos system shall present the value of every diagnostic counter
(DIAG-009) in the heads-up display (HUD-001).

**HUD-020.** The Kudos system shall present each diagnostic counter's rate of
change over the last sampling interval, in the heads-up display (HUD-001).

**HUD-021.** The Kudos system shall present the time of day in the heads-up
display (HUD-001).

**HUD-022.** The Kudos system shall present the time elapsed since boot in the
heads-up display (HUD-001).

**HUD-024.** The Kudos system shall present a rolling history of frame time over a
fixed window in the heads-up display (HUD-001).

**HUD-025.** The Kudos system shall present a rolling history of processor
occupancy over a fixed window in the heads-up display (HUD-001).

**HUD-026.** The Kudos system shall present a rolling history of free kernel heap
over a fixed window in the heads-up display (HUD-001).

**HUD-027.** The Kudos system shall present a rolling history of received network
traffic over a fixed window in the heads-up display (HUD-001).

**HUD-028.** The Kudos system shall raise a visible alarm in the heads-up display
(HUD-001) when a diagnostic counter that records a fault increments.

**HUD-029.** The Kudos system shall hold an alarm (HUD-028) visible until it is
acknowledged.

**HUD-030.** The Kudos system shall stop sampling the heads-up display (HUD-001)
on request, so a transient can be read, and resume on request.

**HUD-031.** The Kudos system shall present the time at which the values shown in
the heads-up display (HUD-001) were sampled.

**HUD-032.** The Kudos system shall refresh the heads-up display (HUD-001) at
least twice per second while it is shown.

## Applications

**APP-001.** The Kudos system shall provide a terminal application, each open
terminal window hosting one terminal session.

**APP-002.** The Kudos system shall host a command shell in each terminal session
(APP-001).

**APP-003.** The Kudos system shall provide shell commands (APP-002) to navigate and
read the virtual file system (STO-002).

**APP-004.** The Kudos system shall provide shell commands (APP-002) for network
diagnostics: showing the network configuration (NET-001), resolving names (NET-008),
pinging hosts (NET-007), and fetching URLs (NET-009).

**APP-005.** The Kudos system shall provide shell commands (APP-002) exposing the
diagnostics (DIAG-001): running tasks with per-core CPU usage, memory usage, PCI
devices, and event counters.

**APP-006.** The Kudos system shall recall the previously entered shell command
line (APP-002) for editing and reuse.

**APP-007.** The Kudos system shall load 3D models in the binary glTF (.glb)
format from the virtual file system (STO-002).

**APP-008.** The Kudos system shall display each loaded 3D model (APP-007) in its own
window, rendered through the OpenGL ES 1.1 pipeline (RND-001).

**APP-009.** The Kudos system shall apply a 3D model's embedded textures when
rendering it (APP-008).

**APP-010.** The Kudos system shall render translucent 3D model materials with
alpha blending (APP-008).

**APP-011.** The Kudos system shall render glTF 2.0 physically-based
metallic-roughness materials on 3D models (APP-008): base-colour,
metallic-roughness, normal, occlusion, and emissive maps.

**APP-015.** The Kudos system shall provide a scientific graphing calculator
application in the style of the TI-82: expression evaluation and function
plotting.

**APP-016.** The Kudos system shall provide scientific functions and mathematical
constants in the calculator's expression language (APP-015).

**APP-017.** The Kudos system shall keep a visible history of evaluated
expressions and their results in the calculator (APP-015).

**APP-018.** The Kudos system shall let the user zoom the calculator's function
plot (APP-015).

**APP-019.** The Kudos system shall provide a basic analog clock application.

**APP-020.** The Kudos system shall provide a system monitor application
displaying CPU, memory, storage, and uptime.

**APP-022.** The Kudos system shall complete a partially typed file system
(STO-002) path in a shell command line (APP-002) on a Tab keystroke, matching it
against the entries of the directory that path names.

**APP-023.** The Kudos system shall complete a path (APP-022) to the whole entry
name when exactly one entry matches it.

**APP-024.** The Kudos system shall extend a path (APP-022) to the longest text
every matching entry shares when more than one entry matches it.

**APP-025.** The Kudos system shall complete a partially typed command name
(APP-002) on a Tab keystroke when it is the first word of the line.

**APP-026.** The Kudos system shall show the matching entries when a Tab
keystroke (APP-022, APP-025) cannot add any further text to the word.

**APP-027.** The Kudos system shall match a Tab keystroke's word (APP-022,
APP-025) without regard to letter case when no entry matches it exactly.

## Loadable modules

**MOD-001.** The Kudos system shall load and execute a compiled binary application
module (ARCH-012) at runtime.

**MOD-002.** The Kudos system shall run a loaded application module (MOD-001) from a
shell command (APP-002) in a terminal session (APP-001).

**MOD-003.** The Kudos system shall load a compiled binary feature module (ARCH-012)
that extends the running system, without a reboot.

**MOD-004.** The Kudos system shall let a loaded feature module (MOD-003) register
new shell commands (APP-002).

**MOD-005.** The Kudos system shall run every loaded binary module (MOD-001, MOD-003)
through a single application binary interface (ARCH-013), regardless of the tool
that produced it.

**MOD-006.** The Kudos system shall run a loaded binary module (MOD-001) in the
virtual address space of the terminal session that ran it (MEM-002).

## Virtualization

**VIRT-001.** The Kudos system shall run a guest operating system in a hardware
virtual machine using the CPU's virtualization extensions, when the hardware
provides them.

**VIRT-002.** The Kudos system shall isolate guest memory from host memory using
second-level (nested) address translation.

**VIRT-003.** The Kudos system shall boot an unmodified Linux kernel image through
the Linux/x86 64-bit boot protocol.

**VIRT-004.** The Kudos system shall provide the guest its entire root filesystem
from an initial RAM filesystem resident in guest memory, exposing no storage device
to the guest.

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

## Agent

**AGT-001.** The Kudos system shall provide an AI agent, available on demand,
that retains one conversation across invocations while the system is running.

**AGT-002.** The Kudos system shall let the user converse with the agent (AGT-001) from
a terminal session (APP-001) and from a dedicated agent window.

**AGT-003.** The Kudos system shall connect the agent (AGT-001) to a large-language-model
service over HTTPS (NET-010), such as OpenRouter.

**AGT-004.** The Kudos system shall read the agent's service credentials (AGT-003) from
a file on the USB mass-storage drive (PER-003).

**AGT-005.** The Kudos system shall stream the agent's responses (AGT-001) to the
display as they are produced.

**AGT-006.** The Kudos system shall give the agent (AGT-001) access to system
capabilities through a defined tool interface: files, applications, system
state, screen capture, input injection, and build-and-run.

**AGT-007.** The Kudos system shall let the agent (AGT-001) generate a new application
from a natural-language request.

**AGT-008.** The Kudos system shall run an agent-generated application (AGT-007) as a
loaded binary module (MOD-001) in a terminal session (APP-001).

**AGT-009.** The Kudos system shall contain an agent-generated application's failure
(AGT-008) to its own terminal session, never disrupting the desktop or other
sessions (KRN-006).

**AGT-010.** The Kudos system shall let the agent (AGT-001) extend the running system
with new features generated on demand.

**AGT-011.** The Kudos system shall expose the agent's tool interface (AGT-006) to a
remote client over netdebug (DIAG-004).

**AGT-012.** The Kudos system shall bound the agent's autonomous actions (AGT-001)
within a stated budget.

**AGT-013.** The Kudos system shall act as a Model Context Protocol (MCP) server,
exposing its tool interface (AGT-006) to external MCP clients.

**AGT-014.** The Kudos system shall act as an MCP client (AGT-013), binding to external
MCP servers.

**AGT-015.** The Kudos system shall make the tools of bound MCP servers (AGT-014)
available to the agent (AGT-001) alongside its own (AGT-006).

**AGT-016.** The Kudos system shall serve its own tools (AGT-013) and consume
external tools (AGT-014) at the same time.

**AGT-017.** The Kudos system shall hold the agent's service credentials
(AGT-003) encrypted, decrypting them with a passphrase at the point of use.

**AGT-018.** The Kudos system shall open an interactive agent session (AGT-002)
when the agent is invoked without a prompt.

**AGT-019.** The Kudos system shall accept session commands within an agent
session (AGT-018), distinguished from conversation turns by a leading solidus.

**AGT-020.** The Kudos system shall list its agent session commands (AGT-019) on
request.

**AGT-021.** The Kudos system shall ask for the passphrase (AGT-017) when it is
requested to decrypt the credentials without one.

**AGT-022.** The Kudos system shall refuse a conversation turn (AGT-001) while
the service credentials (AGT-017) are still encrypted, stating how to decrypt
them.

**AGT-023.** The Kudos system shall let the agent (AGT-001) focus, maximise,
minimise, restore and close any desktop window (DSK-001).

**AGT-024.** The Kudos system shall report the desktop's open windows (DSK-001)
to the agent (AGT-001), identifying which one has keyboard focus.

**AGT-025.** The Kudos system shall report the heads-up display's sample
(HUD-001) to the agent (AGT-001).

**AGT-026.** The Kudos system shall let the agent (AGT-001) place the pointer at
a screen position and press a pointer button.

## Diagnostics

**DIAG-001.** The Kudos system shall provide diagnostics reporting the health and
state of the system.

**DIAG-002.** The Kudos system shall count, in its diagnostics (DIAG-001), every event
that a discarding or error path drops — no failure shall be silent.

**DIAG-003.** The Kudos system shall count, in its diagnostics (DIAG-001), every frame
that misses its 60 Hz deadline (PERF-003).

**DIAG-004.** The Kudos system shall provide netdebug, a facility that streams
diagnostics, traces, and debug commands over the network to a remote host.

**DIAG-005.** The Kudos system shall emit its build identity — build number and
source commit — as the first line of every netdebug trace (DIAG-004).

**DIAG-006.** The Kudos system shall answer a remote version query over netdebug
(DIAG-004) with its build number, source commit, and build time.

**DIAG-007.** The Kudos system shall emit a periodic heartbeat over netdebug (DIAG-004)
reporting liveness and timer-tick health.

**DIAG-008.** The Kudos system shall accept keyboard events injected remotely over
netdebug (DIAG-004), delivering them as if typed locally.

**DIAG-009.** The Kudos system shall accept mouse events injected remotely over
netdebug (DIAG-004), both relative motion and absolute placement.

**DIAG-010.** The Kudos system shall let a remote host list, read, and write
ramdisk (STO-001) files over netdebug (DIAG-004).

**DIAG-011.** The Kudos system shall retain its most recent trace history in
memory and replay it on command over netdebug (DIAG-004).

**DIAG-012.** The Kudos system shall detect a core unresponsive beyond a stated
budget and report its stuck execution point over netdebug (DIAG-004).

**DIAG-013.** The Kudos system shall stream a call backtrace over netdebug (DIAG-004)
on any panic or CPU fault.

**DIAG-014.** The Kudos system shall mirror its boot trace to a file on the USB
mass-storage drive (PER-003) when one is present.

**DIAG-015.** The Kudos system shall capture a screenshot of the desktop on command
over netdebug (DIAG-004).

**DIAG-016.** The Kudos system shall store captured screenshots (DIAG-015) in a
standard image format such as PNG, encoded natively (IMG-002).

**DIAG-017.** The Kudos system shall also store captured screenshots (DIAG-015) on the
USB mass-storage drive (PER-003) when one is present.

**DIAG-018.** The Kudos system shall accept reboot and shutdown commands remotely
over netdebug (DIAG-004).

**DIAG-019.** The Kudos system shall refuse, rather than acknowledge, a remotely
injected keystroke (DIAG-008) it has no room to accept.

**DIAG-020.** The Kudos system shall accept a whole string of keystrokes in one
netdebug (DIAG-004) request, reporting how many of them it accepted.

**DIAG-021.** The Kudos system shall focus the window named by a substring of its
title on command over netdebug (DIAG-004).

**DIAG-022.** The Kudos system shall report the focused window's title over
netdebug (DIAG-004).

## Testing

**TEST-001.** The Kudos system shall maintain an on-target test suite exercising
the real-time functional and performance requirements of this specification.

**TEST-002.** The Kudos system shall drive and observe the on-target test suite
through netdebug (DIAG-004).

**TEST-003.** The Kudos system shall verify every implementation of an interface
contract (ARCH-002), real or fake, against a single conformance suite per
contract.

**TEST-004.** The Kudos system shall maintain a glTF conformance suite built on the
Khronos glTF-Sample-Assets reference models, exercised through the on-target
test suite (TEST-001).

**TEST-005.** The Kudos system shall load and display (APP-007, APP-008) every
geometry-and-texture-tier reference model of that suite (TEST-004):
TriangleWithoutIndices, Triangle, Box, BoxInterleaved, BoxTextured, and
SimpleMeshes.

**TEST-006.** The Kudos system shall render the feature-validation reference models
matching its implemented features (TEST-004) — AlphaBlendModeTest (APP-010),
VertexColorTest, TextureCoordinateTest and OrientationTest — consistent with
their published reference renderings.

**TEST-007.** The Kudos system shall validate every glTF asset it ships with the
Khronos glTF Validator at build time.

**TEST-008.** The Kudos system shall measure the reference models whose features
it does not implement (TEST-006) against the error a conforming render would
reach, and report each as unmet until it does.

# Non-functional requirements

## Architecture

**ARCH-001.** The Kudos system shall organise its software as a stack of layered
modules in which each module calls only the public API of the layer directly
below it.

**ARCH-002.** The Kudos system shall connect subsystems that must remain mutually
unaware through interface modules that hold contracts only, never logic.

**ARCH-003.** The Kudos system shall keep every interface module compilable by
both the kernel build and the host test build.

**ARCH-004.** The Kudos system shall introduce a runtime abstraction (a
substitutable implementation behind a contract) only at a real seam: hardware,
IO, time, network, or randomness.

**ARCH-005.** The Kudos system shall route all window-manager rendering through
kgl (RND-003).

**ARCH-006.** The Kudos system shall route all kgl (RND-003) rendering through gles,
its OpenGL ES 1.1 implementation (RND-001).

**ARCH-007.** The Kudos system shall route all gles rendering through one
draw-device contract, implemented by the driver for the GPU required by
PLAT-001 and by the software rasteriser of RND-012.

**ARCH-008.** The Kudos system shall compile all GPU shader programs offline at
build time, embedding the compiled programs in the kernel image.

**ARCH-009.** The Kudos system shall carry no shader compiler on target.

**ARCH-010.** The Kudos system shall resolve every drawable GL state to one of the
shader programs compiled by ARCH-008, never requiring a program that was not
built.

**ARCH-012.** The Kudos system shall compile agent-generated code (AGT-007) off-target
into loadable binary modules, carrying no compiler on target.

**ARCH-013.** The Kudos system shall define every loadable binary module (ARCH-012)
through a single versioned application binary interface.

**ARCH-014.** The Kudos system shall verify a binary module's format and interface
version (ARCH-013) before executing it.

**ARCH-015.** The Kudos system shall never rasterise the desktop on the CPU
when the GPU required by PLAT-001 is present.

**ARCH-016.** The Kudos system shall assign no core a role that another online
core could not equally take.

## Platform

**PLAT-001.** The Kudos system shall target the NVIDIA RTX 4090 as its GPU.

## Performance

**PERF-001.** The Kudos system shall define "the desktop is shown" as the first
GPU present; on a machine rendering in software (RND-012), as the first desktop
frame shown on the firmware framebuffer.

**PERF-002.** The Kudos system shall show the desktop (PERF-001) within 9 seconds of
the firmware transferring control to the kernel.

**PERF-003.** The Kudos system shall hold the desktop at a smooth 60 Hz from the
moment the desktop is shown (PERF-001) onward, without ever dropping a frame.

**PERF-004.** The Kudos system shall present exactly one new frame per display
refresh (PERF-003).

**PERF-005.** The Kudos system shall present frames tear-free: the display never
scans out a partially composed frame.

**PERF-007.** The Kudos system shall ensure no device or IO work degrades the
smooth 60 Hz rendering required by PERF-003.

**PERF-008.** The Kudos system shall reflect every mouse and keyboard input on
screen within one frame — 16.7 ms — of receipt (PERF-003).

**PERF-012.** The Kudos system shall complete a screenshot capture (DIAG-015) in under
1 second.

**PERF-013.** The Kudos system shall transfer captured screenshots (DIAG-015) to the
remote host utilising the full available network bandwidth.

**PERF-014.** The Kudos system shall bring up networking off the boot critical
path, never delaying the desktop being shown (PERF-001).

**PERF-016.** The Kudos system shall draw text (RND-009) without rasterising a
glyph outline during a frame.

**PERF-017.** The Kudos system shall hold its 60 Hz present cadence (PERF-003)
while a guest virtual machine is running (VIRT-001).
