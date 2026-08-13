# Agent

Loadable binary modules and the AI agent of the Kudos system: the capability
interface modules bind at runtime, and the agent that converses, generates
applications, and drives the system through a tool interface.

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

**MOD-007.** The Kudos system shall publish a set of system capabilities that a
loaded binary module (MOD-005) binds at runtime by identifier and version.

**MOD-008.** The Kudos system shall refuse a capability request (MOD-007) that
names an identifier it does not publish to the requesting module.

**MOD-009.** The Kudos system shall refuse a capability request (MOD-007) for a
version of that capability it does not publish.

**MOD-010.** The Kudos system shall grant a loaded feature module (MOD-003) every
capability (MOD-007) it grants a loaded application module (MOD-001).

**MOD-011.** The Kudos system shall report the capabilities it publishes (MOD-007),
identifying which are available on the running machine.

**MOD-012.** The Kudos system shall host desktop windows whose content a loaded
application module (MOD-001) renders, several at once.

**MOD-013.** The Kudos system shall route keyboard input to a loaded application
module (MOD-012) while its window has focus, and to no module otherwise.

**MOD-014.** The Kudos system shall end a loaded application module's run
(MOD-012) when its window is closed.

**MOD-015.** The Kudos system shall render three-dimensional content a loaded
application module records (MOD-012) into that module's window on the graphics
processor (ARCH-015).

**MOD-016.** The Kudos system shall validate a recorded frame (MOD-015) before
rendering it, refusing the whole frame on any invalid command.

**MOD-017.** The Kudos system shall report to a loaded binary module (MOD-005)
what the machine is running.

**MOD-018.** The Kudos system shall let a loaded feature module (MOD-003) start
another application module (MOD-001) and stop one it started.

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
