# Kudos System Specification

The cardinal specification for the Kudos system, stated as one file per
package under `specs/`.

Kudos is a real-time operating system — its slogan: **"microseconds matter"**.
It aims to minimise latency and jitter throughout, and holds a smooth user
experience as the standard every performance requirement is written against.
What a given build actually achieves is what the performance tests report,
never what this page asserts.

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
envelope it does it within). The packages run bottom-up: platform bring-up and
kernel first, then devices, storage, and networking, then rendering and the
desktop, then the applications and agent built on top.

| package | prefixes |
| --- | --- |
| [specs/kernel.md](specs/kernel.md) | BOOT, KRN, MEM, PER |
| [specs/files.md](specs/files.md) | STO |
| [specs/network.md](specs/network.md) | NET |
| [specs/graphics.md](specs/graphics.md) | IMG, RND, DSK, HUD, PERF |
| [specs/apps.md](specs/apps.md) | APP |
| [specs/agent.md](specs/agent.md) | MOD, AGT |
| [specs/virtualisation.md](specs/virtualisation.md) | VIRT |
| [specs/diagnostics.md](specs/diagnostics.md) | DIAG, TEST |
| [specs/architecture.md](specs/architecture.md) | ARCH, PLAT |
