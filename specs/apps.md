# Applications

The applications the Kudos desktop ships: the terminal and its command shell,
the 3D model viewer, the calculator, the clock, and the system monitor.

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

**APP-028.** The Kudos system shall write a shell command's output (APP-002) to a
named file in the virtual file system (STO-002) instead of the terminal when the
command line names one.

**APP-029.** The Kudos system shall add a shell command's output (APP-028) to the
end of a named file, keeping what the file already holds.

**APP-030.** The Kudos system shall leave a redirected file (APP-028) unchanged
when the command's output exceeds the capture budget, reporting the budget.
