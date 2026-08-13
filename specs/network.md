# Network

The Kudos network stack: DHCP configuration, ARP, ICMP, UDP, TCP, DNS, and the
HTTP and TLS client layers built on them.

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
