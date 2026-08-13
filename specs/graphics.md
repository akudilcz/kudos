# Graphics

Rendering and the desktop of the Kudos system: image codecs, the OpenGL ES 1.1
pipeline and the kgl drawing library, window chrome and desktop interaction,
the heads-up display, and the performance envelope they are held to.

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

**DSK-021.** The Kudos system shall show, on the dock (DSK-016), one slot per open
window, visually separated from the launcher tiles; activating a slot shall focus its
window, restoring it if minimised.

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
