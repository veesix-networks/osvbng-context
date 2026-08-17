# IPoE v6 suite failures, root causes and false trails

Reopened and closed again 2026-08-17. Suites 32, 42 and 47 failed
intermittently on subscriber-initiated IPv6 while IPv4 and PPPoE
twins passed. The first investigation stopped at a real test
infrastructure defect and declared the product clear; the failures
continued at lower frequency, and the second investigation found
two product defects underneath. All three are recorded here, with
the false trails, because each partial fix made the remaining
failures rarer and easier to misattribute.

## Root cause 1 of 3: dual-stack management network (test infra)

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

## Root cause 2 of 3: kernel ND poisons VPP's ip6-ll FIB (product)

af-packet leaves the container kernel bound to the claimed netdev
with the same MAC and the same link-local as VPP. The kernel's
IPv6 stack answers ND probes for that address; VPP hears the
kernel's transmitted NA as an inbound frame and learns its own
link-local as a dynamic neighbour on the interface. That entry
replaces the interface's local-receive /128 in the ip6-ll FIB, so
from then on every ND reply addressed to the interface is looked
up in the poisoned table and forwarded back out the wire to its
own MAC instead of received. The core's global address can never
resolve past a glean adjacency, v6 through the box is dead, and
v4 is untouched because the kernel holds no v4 address on claimed
interfaces so ARP stays silent. Every NUD probe cycle from the
peer re-arms the poison, which is why restart suites, whose late
re-verification lands inside a probe window, failed
probabilistically while by-hand checks minutes later passed.

Proving observations, from a frozen failing lab: tcpdump on the
core showed an NA answering every NS on the wire; the VPP trace
showed that NA entering ip6-input, matching the poisoned ip6-ll
entry, and leaving through ip6-rewrite out the same interface
with dst MAC equal to src MAC; show ip6-ll on the broken
interface was missing its own dpo-receive route while a healthy
loopback had one.

Fix: osvbngd writes disable_ipv6=1 on a netdev before claiming it
via af-packet (createVPPHostInterface). The kernel-side routing
stack talks through the linux-cp taps in the dataplane namespace,
never through the claimed netdev, so the kernel has no legitimate
IPv6 role there. Verified with 20 consecutive osvbngd restart
cycles holding all four subscriber ping targets, against a
pre-fix baseline that died within three.

## Root cause 3 of 3: session re-attach was dead code (product)

opdb restore over a live VPP never re-attached an IPoE session.
The ipoe plugin answers a replayed identical add with
ENTRY_ALREADY_EXISTS (-116) and the live session's sw_if_index in
the reply, exactly so the caller can re-attach, but govpp's
ReceiveReply converts every nonzero retval into an error before
the caller can read reply.Retval. AddIPoESession's already-exists
and needs-refresh branches were both unreachable; restore counted
every replayed session as failed and the control plane came up
with zero sessions while the dataplane kept forwarding. Suite 32
masked this for months because its checks (opdb snapshot,
subscriber pings) never consult the control plane's session view;
suites 42 and 47 exposed it because they assert the API count.
The same govpp conversion makes the retval-comparison idiom in
other southbound callers dead code wherever the caller re-adds
blindly; cgnat escapes only because its reconcile diffs live
state and never replays an existing add.

Fix: inspect the ReceiveReply error, treat ENTRY_ALREADY_EXISTS
as re-attach using the sw_if_index the decoded reply carries, and
keep the needs-refresh delete-and-recreate where it can execute.

## Test-side defect found in the same pass

Check osvbng Started greps the container's docker log for the
started line, which survives an osvbngd respawn from the previous
boot, so post-restart health waits passed instantly while restore
was still running. Restart flows now also wait for
/run/osvbng/state to read ready, the signal TrackReadiness
maintains and the only one that means recovery finished.

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

Both merged 2026-08-17:

- osvbng-vpp PR 18: NS punt registration with per-type
  passthrough, so the daemon's NS responder is reachable where ND
  punt is enabled.
- osvbng PR 451: unsolicited NA after session restore per
  RFC 4861 7.2.6, the recovery gap suite 32's 2b case documents.
