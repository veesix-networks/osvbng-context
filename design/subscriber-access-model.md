# Subscriber access model

This note describes how osvbng maps access-network handover shapes to
subscribers, how tunnel-terminated access works, why every subscriber
gets its own virtual interface in the dataplane, and how IPv4 and
IPv6 bindings attach to that interface. Read it before working on
session identification, the PPPoE or IPoE VPP plugins, tunnel or
pseudowire configuration, or IPv6 address assignment.

## Access handover shapes

The access network hands subscriber traffic to the BNG in one of a
small set of Ethernet shapes, arriving either on a physical port or
inside a VXLAN tunnel. The shape determines which fields identify a
subscriber.

| Shape               | Prevalence  | IPoE subscriber identifier   |
|---------------------|-------------|------------------------------|
| 802.1Q single tag   | Common      | Source MAC + VLAN ID         |
| 802.1Q/802.1ad QinQ | Very common | Source MAC + S-VLAN + C-VLAN |
| VXLAN handover      | Common      | Same logic as the inner shape|

Untagged access is not supported: VLAN 0 is rejected at config
parse, in the IPoE DHCP path, and in l2gw triggers. Triple tagging
is not supported. Some deployments carry TPID 0x8100 on both the
outer and inner tag instead of 0x88a8 on the outer.

PPPoE subscribers are identified by PPPoE session_id plus source MAC
in every shape; the VLAN tags are part of the session's L2 rewrite
rather than the lookup key.

## Tunnel-terminated access

VXLAN is the only tunnel encapsulation today. A tunnel is an
interface with a vxlan block: source (address or interface), VNI,
and either a static destination or signaling: evpn, in which case
the remote VTEP is learned from EVPN RT-3 routes (see the FRR EVPN
capability audit note) and the tunnel is programmed with a
placeholder destination until the VTEP is discovered, so all
dependent programming can exist from boot. Terminating the handover
on a tunnel allows the same S-VLAN namespace to arrive from
multiple points in the access network, one VNI per NNI, and lets
failover be driven in the overlay by routing.

There are two ways access rides a tunnel:

- Direct, for l2gw: a VXLAN tunnel interface serves as an A-NNI
  parent-interface or a handoff-group interface with no extra
  config. The osvbng_tunnel plugin's decap node re-enters the
  device-input feature arc after decapsulation, so l2gw, punt, and
  classification features armed on a tunnel behave exactly as on a
  physical port.
- Pseudowire headend (PWHE), for IPoE, PPPoE, and LAC: these access
  types never parent directly on a tunnel. A pseudowire interface
  (a loopback headend with an optional pinned MAC) names a vxlan
  interface as its transport; the plugin's pw-input node rewrites
  received frames to the headend, and a per-headend output node
  sends everything the headend and its sub-interfaces transmit back
  through the transport tunnel. The headend then behaves as a
  normal parent interface: subscriber groups parent on it and
  S-VLAN sub-interfaces are auto-created on it by name.

In osvbng, "pseudowire" means this VXLAN-backed headend. MPLS
pseudowires, EVPN-VPWS, and SRv6 transports do not exist; the
transport field is where such encapsulations would slot in if a
requirement ever pays for them, and FRR itself has no EVPN-VPWS
(RFC 8214) to signal them with.

For HA, tunnel-terminated access pairs with an anycast VTEP: both
nodes carry identical tunnel and headend config, the VTEP loopback
/32 is advertised through SRG networks by the active node only, and
the headend MAC is pinned to the SRG virtual MAC so the gateway MAC
survives switchover (see the HA architecture note).

## Subscriber group matching

Subscriber groups match sessions by S-VLAN and C-VLAN ranges only;
there is no interface dimension in the match index. The
parent-interface of a group's VLAN range may be a physical port, a
VXLAN tunnel (l2gw), or a pseudowire headend, but selection is by
VLAN. Non-l2gw access types (ipoe, pppoe, lac) must collapse to a
single access interface per configuration; l2gw ranges are exempt,
so each wholesale access operator lands on its own NNI.

## Per-subscriber virtual interfaces

Each subscriber gets one virtual interface in VPP, for both PPPoE and
IPoE. The interface provides:

- native VPP per-subscriber packet and byte counters
- an attachment point for per-subscriber QoS policers and shapers
- an attachment point for per-subscriber ACLs
- a FIB target, so routes point directly at the subscriber
- a clean abstraction for subscriber lifecycle state

This mirrors established BNG practice, for comparison only: Juniper
uses per-subscriber demux interfaces, Cisco creates a virtual
interface per IP subscriber, and Nokia attaches multiple IP bindings
to a single subscriber session. In osvbng the equivalents are the
pppoe_session and ipoe_session interface types.

PPPoE and IPoE are implemented as separate VPP plugins that follow
the same pattern. Each creates the per-subscriber interface and
returns its sw_if_index; the Go control plane treats both uniformly,
with sw_if_index as the common currency for accounting and QoS. A
single generic plugin was rejected because the two protocols differ
too much to share one code path, and a design without a virtual
interface was rejected because it loses native interface counters and
makes per-subscriber QoS harder.

### The session interface is the subscriber object in VPP

The plugins virtualize the subscriber by wiring the session
interface into VPP's own forwarding machinery rather than keeping
sessions in side tables that features would have to know about.
Toward the subscriber, the session's routes (/32, /128, delegated
prefix) are FIB entries installed under the plugin's own FIB source
at high priority, whose paths resolve via the session interface:
for PPPoE that is a midchain adjacency carrying the pre-built
session rewrite, stacked on the encap interface's TX DPO; for IPoE
the session interface's output path is the plugin's tunnel-output
node, which applies the MAC and VLAN rewrite. From the subscriber,
classification rewrites the buffer's RX interface to the session
interface (decap lookup for PPPoE, the input node of ADR 0004 for
IPoE). Either way, by the time a packet is in the IP feature arcs
it belongs to an interface that means exactly one subscriber.

That is the point of the design: everything VPP can attach to an
interface applies per subscriber with no session-aware code in the
feature. Counters, ip4/ip6-unicast feature arc members (CGNAT,
ACLs), policers, and the CAKE scheduler all bind by sw_if_index,
and the scheduler's aggregate auto-attach walks the interface
hierarchy from it.

This is a contract, not just a convenience: when a plugin
introduces a new kind of per-subscriber resource, it attaches to
the session interface by sw_if_index, never to a session id, MAC,
IP, or a privately keyed table. Resources that attach anywhere
else cannot be seen by show handlers keyed on the session
interface, do not follow the session through restore (where the
sw_if_index may change but is re-checkpointed), and break the
uniform IPoE/PPPoE handling in the control plane.

### PPPoE

PPPoE has a natural session encapsulation, so pppoe_session is a
tunnel endpoint. RX punts control traffic (LCP, IPCP) to userspace
and decapsulates IP traffic after a lookup on MAC plus session_id.
TX resolves the FIB to the pppoe_session sw_if_index, applies a
midchain adjacency with a pre-built L2 rewrite (MACs, S-VLAN, C-VLAN,
PPPoE and PPP headers), fills in the PPPoE length field, and forwards
out the encap interface.

### IPoE

IPoE has no session encapsulation: subscribers share a sub-interface,
there are no headers to strip, and the session is DHCP lease state
plus NDP. The ipoe_session interface is therefore pass-through, used
for counting and policy only, with no decap on RX and a MAC plus
VLAN rewrite applied by its tunnel-output path on TX. The interface
is parented on its encap sub-interface (sup_sw_if_index) and bound
into the session VRF; it carries no address of its own (ADR 0004).

Dataplane classification keys on the tuple {sw_if_index, inner_vlan,
mac}, which covers all deployment models:

| Model                    | sw_if_index | inner_vlan | mac              |
|--------------------------|-------------|------------|------------------|
| 1:1, S-VLAN per sub      | unique      | 0          | can repeat       |
| QinQ 1:1, S+C per sub    | shared      | unique     | can repeat       |
| N:1, shared S-VLAN       | shared      | 0          | unique in domain |
| N:1 QinQ, shared S+C     | shared      | shared     | unique in domain |

The control plane enforces session exclusivity on the parallel key
(S-VLAN, C-VLAN, MAC) in pkg/session/, which is the same identity
expressed in VLAN terms rather than interface terms.

To avoid creating thousands of VPP sub-interfaces, only S-VLANs are
VPP sub-interfaces (a reasonable number per service or OLT). The
C-VLAN is not a sub-interface: the IPoE input node parses it from the
packet header and performs the session lookup, then sets the buffer's
sw_if_index to the ipoe_session interface so counters increment
before ip4-input or ip6-input. Each subscriber costs exactly one
virtual interface.

## IPv6 subscriber model

A single subscriber session carries up to three IP bindings with
independent lifecycles:

- IPv4 address, from DHCPv4 (IPoE) or IPCP (PPPoE)
- IPv6 WAN address, from DHCPv6 IA_NA
- delegated prefix, from DHCPv6 IA_PD

An IPv4 lease can expire without affecting IPv6, and sessions can be
IPv4-only, IPv6-only, or dual-stack per configuration. All bindings
share the subscriber's virtual interface, so QoS, ACLs, and counters
apply once per subscriber. The IPoE plugin exposes separate APIs to
set the IPv4 binding (/32 FIB path), the IA_NA binding (/128), and
the delegated prefix, each with its own bound flag and lifecycle.

For NDP, a router solicitation from the subscriber triggers a router
advertisement with the M and O flags set (configurable per group),
steering the client to DHCPv6, and a bucketed periodic RA emitter
refreshes advertisements for established sessions until teardown
ceases them. PPPoE reaches dual stack through IPCP and IPv6CP on the
same session.

### Address and prefix resolution

The allocator context in pkg/allocator/ bridges AAA attributes into
DHCP and PPP resolution. It carries the IPv4 and IPv6 profile names,
any static IPv6 address or delegated prefix from AAA, IANA and PD
pool name overrides, and IPv6 DNS servers.

IPv6 profile names come from subscriber group configuration, looked
up by S-VLAN, not from AAA. AAA cannot override the profile name but
can override individual pool names. Pool selection resolves in this
order: AAA pool attributes first, then service group pool names, then
profile defaults.

DHCPv6 resolution handles both allocation and reservation. If no
IPv6 address is present in the context it allocates an IA_NA address
from the profile's pool, otherwise it reserves the AAA-provided
address; the delegated prefix follows the same allocate-or-reserve
pattern. If both IA_NA and PD fail, the session gets no IPv6.

The two access types differ in timing. IPoE (internal/ipoe/) builds
the allocator context while processing the AAA response, before
forwarding the pended DHCPv6 Solicit or Request onward. PPPoE
(internal/pppoe/) allocates during NCP startup, after authentication
and before opening IPv6CP, writing the allocated IA_NA back into the
context so DHCPv6 over PPP rebinds the same address, and releases
the allocation on terminate. For PPPoE the delegated prefix is
reservation-only; there is no dynamic PD allocation.
