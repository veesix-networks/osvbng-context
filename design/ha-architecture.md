# HA architecture

This note describes osvbng's high-availability design: TR-459-style
subscriber redundancy groups across a two-node active/standby pair,
the state that must survive failover, and the services that detect
failure and recover from it. Read it before working on pkg/ha/, the
SRG VPP plugin, session sync, opdb, the watchdog, or the event bus.

## Design intent

The redundancy unit is the Subscriber Redundancy Group (SRG), a
concept taken from TR-459. An SRG maps to one or more subscriber
groups (the TR-459 SGRP model); subscriber groups define S-VLAN
ranges in their config. Each SRG elects its own active node, so one
node can be active for some SRGs and standby for others.

The target deployment shapes the access-side design. osvbng targets
ISPs that buy access from wholesale networks over an E-NNI with QinQ
handover, arriving on physical Ethernet or inside VXLAN tunnels
(directly for l2gw, via a pseudowire headend for IPoE/PPPoE/LAC; see
the subscriber access model note). In both cases what needs to move
on failover is Ethernet-level identity, so failover is a
control-plane-managed virtual MAC move, similar in spirit to VRRP
but driven by the BNG control plane rather than the VPP VRRP plugin,
matching the customizable control-plane VRRP flavours vendors run.
Tunnel-terminated access adds a routing layer to the same story: the
VTEP address is an anycast loopback, and which node terminates the
tunnels follows which node advertises it.

Core design choices:

- Active/standby with hot standby: sessions are pre-programmed into
  the standby's VPP so failover does not require re-creating them.
- A virtual MAC per SRG is the subscriber-facing BNG MAC for data
  and for control-plane responses (ARP, DHCP, ICMPv6).
- Peers heartbeat and sync state over a unicast gRPC channel.
- Split-brain must be safe: both nodes may believe they are active
  during a partition, and that window must not corrupt IP
  allocation or subscriber state.
- Operators can force a switchover, and interface trackers can
  drive automatic failover.
- On the core side, active/standby only requires advertising the
  subscriber pool prefixes into BGP from the active node, not
  per-session /32s and /128s. SRG networks carry these prefixes,
  and for tunnel-terminated access the anycast VTEP /32 as well.

## HA manager and SRG state machine

pkg/ha/ holds the HA manager, a component that implements the
SRGProvider interface consumed by the session components. Peers run
a standalone gRPC service with a bidirectional Heartbeat stream,
NotifySRGState, and RequestSwitchover, optionally over mTLS (TLS
1.3, mutual cert auth) with an insecure fallback when unconfigured.
Heartbeats carry priority and yield RTT and clock-skew measurements;
the client reconnects with exponential backoff, and the manager
starts before other components.

Each SRG runs a state machine: INIT, WAITING, READY, then ACTIVE,
STANDBY, ACTIVE_SOLO (peer lost while active), or STANDBY_ALONE.
Election: higher priority wins, node_id lexicographic tiebreak, and
preempt: true re-runs the election when the peer recovers. A standby
that loses its peer does not auto-promote (STANDBY_ALONE), which
limits split-brain to explicit force-promote.

SRGProvider is keyed by SRG name: GetVirtualMAC(srgName),
IsActive(srgName), GetSRGForGroup(subscriberGroup). Components
(ipoe, pppoe, arp, subscriber) resolve S-VLAN to subscriber group to
SRG name via their config manager, caching it on the session's
SRGName field; the HA manager has no config dependency. An empty or
unknown SRG name yields safe defaults: IsActive true, GetVirtualMAC
nil.

Trackers adjust an SRG's effective priority. A VPP interface watcher
in pkg/southbound/vpp/ subscribes to interface event notifications
(event-driven, no polling) through a mutable watch set that filters
out subscriber-interface churn. When a tracked access interface goes
down, the SRG's effective priority drops by a configured decrement
per down interface. Heartbeats advertise the reduced priority, so a
preempt-enabled peer now holding the higher priority takes over;
link restore brings the priority and, with preempt, the original
active back. Interface state is the only tracker input today.

## Virtual MAC and the SRG dataplane plugin

The virtual MAC mechanism applies where osvbng is the subscriber's
L3 gateway on access Ethernet: IPoE and PPPoE sessions, including
the access leg of PPPoE sessions a LAC tunnels onward. It does not
apply to l2gw circuits, which are L2-transparent and never rewrite
MACs; their failover under the same SRG election is the circuit
enabled flag, synced disabled to the standby and batch-enabled on
promotion (see the wholesale L2 note). Core-facing L2TP tunnels are
reached over routed addresses, so a MAC move plays no part there
either; SRG election and routing advertisement decide which node
serves them.

For the session types it covers, both active and standby create
every session with local_mac set to the SRG's virtual MAC. Standby silence comes from the vMAC not being
present on the standby's hardware interface: the NIC drops frames to
it, and control-plane packets are dropped before being answered. On
failover the vMAC is added to the hardware interface and the
pre-programmed sessions forward immediately; no session re-creation
or MAC rewrite.

A dedicated VPP plugin (osvbng_srg, in the osvbng-vpp repo) owns the
dataplane consequences of SRG state:

- vMAC add/remove on the hardware interface via VPP's own hardware
  MAC management, the mechanism the VPP VRRP plugin uses, with
  reference counting so sub-interfaces sharing a hardware interface
  and SRG program the MAC once.
- Batched GARP and IPv6 Neighbor Advertisement announcements on
  failover. The control plane supplies batches of (sw_if_index,
  VLANs, TPID, ip) entries; the plugin builds the frames with the
  vMAC as source and enqueues them to interface-output, so each
  announcement leaves with its session's own 802.1Q or QinQ encap.
  Thousands of announcements go out in one graph walk. Announcing
  is optional and rate-controlled (batch delay, repeat interval):
  with a shared vMAC it only speeds L2 switch convergence, and
  under QinQ one ARP per subscriber is real dataplane load.
- Per-SRG counters (GARP and NA sent, MAC adds and removes) exposed
  via a dump API.

The control plane drives the plugin API through pkg/southbound/vpp/
wrappers. The HA manager talks to an SRGDataplane interface with a
no-op fallback; plugin presence is probed at startup, and without it
the full state machine still runs, minus hardware vMAC programming
and announcements.

On unplanned failover the standby detects peer loss via heartbeat
timeout, transitions to ACTIVE, programs the vMAC, optionally sends
the announcement batch, advertises the pool prefixes into BGP, and
starts answering punted control-plane packets. Route advertise and
withdraw on role change execute vtysh directly
(internal/routing/); the config-template and frr-reload path takes
seconds, too slow for failover.

## Session sync and split-brain safety

Session state replicates from active to standby over the peer gRPC
channel: incremental sync on session events plus a bulk sync for
catch-up. The standby checkpoints received sessions into dedicated
opdb namespaces and restores them into VPP on promotion
(restoreFromHASync in the session components). CGNAT mappings sync
alongside sessions.

Two mechanisms keep IP allocation safe:

- Allocator sync: the standby reserves the IPs of synced sessions
  in its local pool allocator and releases them on session delete,
  so a promoted node's allocator matches reality.
- Directional allocation: each node allocates from its own end of
  the pool (ascending or descending, chosen when the node wins or
  loses the election), so new sessions created during a
  split-brain window cannot collide. pkg/allocator/ enforces the
  direction in both the pool and prefix allocators.

Operators trigger planned role changes with the ha.switchover oper
command, which carries a graceful flag through RequestSwitchover;
the promoting node programs the vMAC, advertises routes, and
restores synced sessions, and the demoting node withdraws.

For tunnel-terminated access, failover is route-driven with an
anycast VTEP. Both nodes hold identical tunnel and headend config;
the standby's EVPN discovery programs its own tunnels
independently, so promotion is dataplane-ready. The anycast VTEP
loopback /32 enters BGP only through SRG networks, advertised by
the active node and withdrawn on demotion, and the pseudowire
headend MAC is pinned to the SRG virtual MAC so the subscriber
gateway MAC survives switchover. The loopback must never be
redistributed outside the SRG mechanism, or both nodes attract
tunnel traffic regardless of role.

## opdb checkpoint store

pkg/opdb/ is the local checkpoint store for runtime state that must
survive a process restart. All runtime reads hit in-memory
structures; writes go write-through to a SQLite file (WAL mode). On
startup, providers reload their namespace and rebuild in-memory
indexes before packet processing starts.

Only state osvbng created and cannot recover externally is
checkpointed: subscriber sessions and CGNAT port blocks (and the
standby's synced-session namespaces). BGP routes are re-learned,
config is on disk, counters may reset. The schema is one generic
table keyed by (namespace, key) with a JSON value, plus a metadata
table for schema versioning. Components integrate through a
Provider interface (Namespace, Restore) mirroring the metric
collector pattern.

## Watchdog

internal/watchdog/ monitors external dependencies through a Target
interface: per-target health-check loop, failure threshold, and a
state machine covering reconnecting and recovering states. The
action on failure is per-target config: recover (reconnect and
restore state, for multi-container deployments that cannot restart
the peer process), restart (run a restart command, for bare metal),
warn, or fail (exit so a container orchestrator restarts the pod).
The shipped targets are VPP and FRR, checked over their control
sockets. /healthz and /readyz serve Kubernetes-style probes through
the northbound API, with per-target metrics.

## VPP recovery

VPP and osvbng are separate processes. A VPP crash leaves the
shared-memory rings stale, the govpp API socket dead, and the FIB
empty, while osvbng still holds session state in memory and opdb.
Detection is the watchdog's API health check backed by the async
worker's circuit breaker (opens after 3 consecutive failures).

On VPP-down, packet processing pauses. On recovery the daemon
reconnects govpp, and if the interface cache shows dataplane state
was actually lost it re-bootstraps: reconnect the shared-memory
rings, re-register punts, reload interfaces, and re-run session
recovery for IPoE, PPPoE, and CGNAT, reprogramming each active
session (session entry with the vMAC, address bindings, routes,
QoS) and checkpointing the new sw_if_index, which may change across
restarts. Partial failures do not abort recovery: remaining
sessions recover, failures are logged and counted.

## Event bus

pkg/events/ provides an in-process publish/subscribe bus that the
tracker architecture and general component decoupling depend on. The
envelope is generic (ID, Type stamped from the topic, Timestamp,
Source component, Data); domain fields live in typed payloads
(session lifecycle, AAA request and response, egress, interface
state), so in-process delivery has no marshal cost. Topics are
colon-separated (osvbng:events:domain:subject); plugins get a
private prefix. Delivery is fan-out broadcast, one goroutine per
handler per event, publish order per topic but no cross-handler
ordering, and a bounded buffer that drops with a warning when full.
The HA manager consumes interface state events for priority
tracking and announces SRG transitions as HA state change events.

## Observability

HA state is visible through show handlers (ha.status, ha.srg,
ha.peer), the ha.switchover oper command, and Prometheus gauges for
SRG state and peer connectivity. Heartbeats compare peer config
hashes to warn on drift; a conf.d drop-in config model lets peers
share GitOps-managed base config with node-specific overrides.
