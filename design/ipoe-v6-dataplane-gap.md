# IPoE v6 suite failures, root cause and false trails

Closed 2026-08-17. Suites 32, 42 and 47 failed intermittently on
subscriber-initiated IPv6 while IPv4 and PPPoE twins passed. The
root cause was test infrastructure, not the product, and two
plausible product suspects were cleared along the way. This note
records both, because the false trails cost hours and the next
session should not rewalk them.

## Root cause

The containerlab management network was dual-stack (the old CI
created it with an IPv6 subnet, and containerlab's default mgmt
network enables IPv6 too). Every node, including subscriber
containers, therefore held an eth0 v6 default route from the mgmt
network that raced the test RA's default route on the access
interface; which route won flipped with RA lifetime timing, so
subscriber-originated v6 sometimes left via mgmt and died with
"Destination unreachable: No route" from the mgmt gateway. The
proving observation: during a failing ping, packet capture on the
BNG access interface showed v4 echoes arriving and no v6 frames at
all, and running the ping without suppressing stderr printed the
mgmt gateway's unreachable error directly.

Fix: the mgmt network is IPv4-only, enforced by shape in the CI
host reset (a dual-stack network is recreated, not tolerated), and
nothing in the rig needs mgmt IPv6. Suites with static management
addressing already use per-suite v4-only networks.

## False trails, cleared

- `ipoe-input ip6 pass-through` in a packet trace looked like a
  session classification miss. It was a multicast NS: the
  classifier deliberately passes v6 multicast through, and its
  lookup is MAC-keyed, shared with v4. The trace filter had caught
  a multicast packet, not the failing unicast, which never reached
  VPP at all.
- `osvbng-punt-ipv6-nd not-enabled` looked like an enablement
  granularity bug. The RS in that trace arrived on a core-facing
  interface, where passthrough to VPP's native handler is correct;
  autoconfig emits ipv6nd punt for access sub-interfaces whenever
  it emits dhcpv6 punt, and dhcpv6 demonstrably worked.

Method lesson recorded on purpose: both false trails came from
reading a filtered trace as if it showed the failing packet, and
from suppressing ping stderr, which had contained the literal
answer. Capture the actual failing packet and read the full error
before theorizing.

## Related changes that stand on their own

- osvbng-vpp PR 18: NS punt registration with per-type
  passthrough, so the daemon's NS responder is reachable where ND
  punt is enabled.
- osvbng PR 451: unsolicited NA after session restore per
  RFC 4861 7.2.6, the recovery gap suite 32's 2b case documents.
