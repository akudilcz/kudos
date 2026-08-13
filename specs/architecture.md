# Architecture

The non-functional requirements of the Kudos system: the layered module
architecture, interface contracts, the offline shader pipeline, the module
toolchain, and the target platform.

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
