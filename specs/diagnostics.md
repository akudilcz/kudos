# Diagnostics

Diagnostics and testing of the Kudos system: health counters, the netdebug
facility for remote observation and control, and the on-target test suite.

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

**DIAG-023.** The Kudos system shall retain transmitted trace lines (DIAG-004)
and serve them again on request, identified by sequence number.

**DIAG-024.** The Kudos system shall keep a trace line (DIAG-004) queued until
the network interface has accepted the datagram carrying it.

**DIAG-025.** The Kudos system shall accept a file over netdebug (DIAG-004) in
sequenced pieces, applying each piece exactly once.

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
