# Wholesale L2 aggregation

This note describes l2gw, the layer 2 wholesale gateway: osvbng as an
L2 aggregator that sits between wholesale access networks and retail
ISPs, cross-connecting subscriber circuits with VLAN rewrite instead
of terminating them at L3. Read it before working on the l2gw VPP
plugin, the l2gw control-plane component, or wholesale handoff
configuration.

## Deployment model

A wholesaler buys access circuits from one or more access network
providers and resells them to retail ISPs. osvbng sits in the middle:

- A-NNI (access NNI): ingress interfaces from access networks.
  Frames arrive with the access network's VLAN tags, single 802.1q
  or Q-in-Q 802.1ad.
- E-NNI (handoff NNI): egress interfaces toward retail ISPs. Frames
  leave re-tagged with the ISP's VLAN assignment.

The retail ISP's BNG terminates DHCP, L3, and subscriber policy.
osvbng owns circuit steering, wholesale accounting, and the
access/handoff abstraction, the IPoE analogue of LAC and LNS. This
replaces terminating each virtual ISP as a VRF with L3 DHCP pools.

l2gw is a first-class access type alongside ipoe, pppoe, lac, and
lns, and its sessions carry the l2gw access type in session tables
and accounting. No IP allocation, DHCP relay, PPP negotiation, or
route injection is involved. The BNG is invisible at L3.

## Two operating modes, one mechanism

1. Static mode: a config-only wildcard entry maps an entire S-VLAN
   on an access port to one ISP's handoff, key (port, svlan, any).
   No RADIUS, no per-subscriber control-plane work, no trigger
   storms. Fits the model where the wholesaler architects orders so
   a given access network always lands a given ISP on a known
   S-VLAN.
2. Dynamic mode: a DHCPv4 DISCOVER or DHCPv6 SOLICIT from an
   unknown circuit punts to the control plane, auth runs via the
   pkg/auth provider abstraction, and the response attributes
   select a handoff group plus optional VLAN rewrites. The control
   plane installs an exact-match entry pair and replays the trigger
   packet. Exact match takes precedence over a static wildcard, so
   dynamic entries can override one.

The default dynamic-mode identity is the line, not the client: the
auth username is built as group.svlan.cvlan, so a CPE swap does not
change the subscriber. DHCP Option 82 circuit-id and remote-id (and
the DHCPv6 Interface-ID and Remote-ID equivalents) are extracted and
passed to AAA as attributes, and an AAA policy format string can
build the username from them instead, falling back to the VLAN
identity when the referenced options are absent.

Triggers are DHCPv4 DISCOVER and DHCPv6 SOLICIT only. PPPoE never
triggers an l2gw circuit; PPPoE wholesale is the LAC/LNS feature's
job. Once a circuit is installed, everything is switched
transparently with no per-protocol code: ARP, ND, DHCP renewals,
IGMP/MLD, and PPPoE, which covers access models that carry PPPoE
over a wholesale L2 handoff.

## Dataplane: the l2gw VPP plugin

A dedicated plugin (osvbng_l2gw) rather than native VPP
sub-interface cross-connects. Per-subscriber sub-interface pairs
cost two interfaces per subscriber (about 40k at 20k subscribers),
bloat the stats segment with per-thread counter vectors, and cost
two interface-create API round-trips per session on the shared
core. The plugin instead keeps circuits in a bihash: 20k circuits
are 40k table entries plus counter pairs.

Node placement: l2gw-input registers on the device-input feature
arc, running after bond-input (LAG support) and before
ethernet-input, armed per port on both access and handoff ports.
Ethertype registration is not usable here: it allows one handler
per ethertype, the ipoe plugin already owns IP4/IP6 and the punt
plugin owns ARP/PPPoE, and l2gw must switch every ethertype. The
feature arc sees every frame on armed ports and costs nothing on
unarmed ports. The node parses up to two VLAN tags itself, since
the buffer is still at the Ethernet header.

Circuit table: a 16-byte-key bihash, 64k buckets, 8 MB, capacity
target at least 100k entries (50k circuits). Key is
(rx sw_if_index, svlan, cvlan), where cvlan may be a wildcard.
Lookup is hierarchical: exact (port, svlan, cvlan), then wildcard
(port, svlan, any), then vnet_feature_next into the normal path.
On a miss the node also snoops for trigger packets and punts them
through the punt plugin's shm path, with a small dampener table so
a trigger storm does not flood the control plane. The entry (one
cache line) carries the egress port, target S/C tags and outer
TPID, flags, the reverse-direction twin index, a stable circuit id
shared by both directions, and reserved fields for future QoS and
ACL indices.

Paired install: one control-plane call installs both directions,
prepared together with cross-linked twin indices and added back to
back under the API barrier, so the window for one-way forwarding is
the barrier itself. The API handler computes the inverse rewrite;
the node never does. Delete removes both. Idempotency follows the
three-state contract: identical re-add returns the existing circuit
id, drifted re-add returns ENTRY_NEEDS_REFRESH and the control
plane deletes and recreates.

Rewrite: a single generic rebuild of the tag stack, no VTR op enum.
The node parses the received tags, builds the target stack from the
entry, moves the 12-byte DA/SA block only when the tag count
changes (headroom is guaranteed on device-input), and writes TPIDs
and tags in place. PCP/DEI bits from the received outer tag are
preserved. One code path covers transparent pass-through, S and/or
C translation, and every push/pop combination between 0, 1, and 2
tags. Wildcard circuits translate only the S-tag and pass C-tags
untouched; transparent circuits skip rewrite entirely. MAC
addresses are never rewritten; frames keep the subscriber's and
ISP's real MACs.

TX: the buffer's TX interface is set to the entry's egress port and
enqueued directly to that interface's output node, batched per
output across the vector (the punt-egress pattern). Deliberate
consequence: l2gw traffic bypasses the interface-output feature arc
on the egress port, so L3 features and the accounting plugin never
see it. Wholesale accounting comes from l2gw's own counters.

Counters: a combined packets/bytes counter per direction, exported
on the stats segment at /osvbng/l2gw, incremented on hit,
per-thread and lock-free, read via the existing govpp stats client
in pkg/southbound/vpp/. No API call on the packet or scrape path.

Enabled flag: each entry carries an enabled bit, settable in bulk.
A disabled entry behaves exactly like a miss, which is what an HA
standby needs (synced but inert circuits). The packet path is 1 to
2 bihash lookups plus an in-place rewrite, no allocation, no locks;
table mutation happens in API handlers under the barrier. Nothing
runs on the shared core after install.

## Control plane: internal/l2gw

- New access type l2gw in pkg/config/subscriber alongside ipoe,
  pppoe, lac, lns. Reuses the IPoE trigger and pending-replay
  pattern from internal/ipoe and subscriber-group VLAN matching.
- Handoff groups are a named egress abstraction in config: label to
  egress interface, plus TPID and S/C-VLAN allocation ranges.
  RADIUS and OSS only ever speak the label, never a VPP interface
  name. The l2gw.* AAA attribute namespace selects the group
  (l2gw.handoff-group) and optionally pins explicit rewrite values
  (l2gw.svlan, l2gw.cvlan).
- Egress VLANs are auto-allocated from the handoff group's range by
  default; AAA attributes override for BSS-integrated wholesalers.
  The chosen allocation is reported in Accounting-Start.
- After install, the held DISCOVER or SOLICIT is re-injected out
  the handoff via the existing shm egress TX path, with tags
  rewritten control-plane-side before injection. Subsequent DHCP
  flows through the dataplane; the BNG does not snoop lease state,
  that is the ISP's side.

## Lifecycle

Circuits are semi-static: installed on trigger plus auth, persisted
to opdb using the restore pattern from internal/ipoe, so a mass
restart does not re-trigger tens of thousands of RADIUS auths.
Teardown is RADIUS Disconnect-Message, API or config removal, or an
optional idle timeout on counters. There is no CoA policy push for
l2gw circuits: subscriber policy belongs to the retail ISP's BNG.

## Accounting

Per-circuit counter pairs from the plugin (not interface counters)
feed the existing pkg/auth accounting abstraction, so RADIUS and
HTTP providers work unchanged: Start, Interim, and Stop with byte
and packet counts. This is the wholesale billing feed.

## HA

Active/standby via the existing SRG and session-sync machinery.
Circuits sync to the standby disabled and are batch-enabled on
promotion. EVPN active/active is not used: l2gw circuits are
point-to-point cross-connects with no flooding or MAC learning, so
a single node cannot form a loop; the only loop risk is
dual-active, which SRG election already prevents.

## What this is not

- Not a bridge domain or VPLS: no MAC learning, flooding, or STP.
- Not an L3VPN: no routes injected into VRFs.
- Not a DHCP relay: DHCP is forwarded transparently after rewrite;
  the ISP's relay or server assigns addresses.
- Not IPoE or PPPoE termination: no subscriber IP or default route.
- Not dependent on MPLS or tunnel encapsulation.
