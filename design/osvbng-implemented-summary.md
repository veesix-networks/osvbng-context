# osvbng implemented state, orientation summary

Written 2026-08-10 as the re-contexting baseline for the new context
repo. The code is authoritative; this exists so a session knows where
to look, not instead of reading it. Corrections welcome, keep it
current when subsystems change materially.

## What osvbng is

A GPL BNG on VPP: a Go control daemon colocated with a VPP dataplane,
driving it over the binary API and a shared-memory punt/egress
channel. Declarative config tree, component-based runtime, robot plus
containerlab test suites, bngblaster as the traffic oracle.

## Control daemon (Go)

- **Runtime**: components with a managed lifecycle
  (pkg/component: Component, ReadyNotifier, orchestrator with ordered
  start and readiness gating; recovery states NotReady, Restoring,
  Ready, Draining so restore replay never races fresh subscriber
  events). Event bus (pkg/events: namespaced topics, in-process
  transport) and a cache interface (pkg/cache, redis-shaped surface,
  memory implementation).
- **Access protocols**: IPoE (DHCPv4 and DHCPv6 through
  pkg/dhcp4/dhcp6 protocol libraries with provider registries,
  IA_NA/IA_PD, access-line/option-82 handling), PPPoE with the full
  PPP FSM (LCP, PAP/CHAP, IPCP/IP6CP), L2TPv2 LAC and LNS (T-bit
  dispatch splits control to the daemon, data to the dataplane).
- **AAA**: RADIUS auth and accounting, CoA/Disconnect, local
  providers.
- **Services**: CGNAT (deterministic and port-block allocation
  modes), L2 gateway (including trigger punts), IPv6 RA/ND, ARP
  handling (currently in Go, both gateway replies and punts),
  gateway/SRG redundancy with virtual MACs, opdb checkpoint restore
  and journal-shipping HA (pkg/ha), FRR-based routing integration,
  watchdog and monitoring.
- **Southbound**: pkg/southbound interfaces over VPP binapi bindings;
  the shared-memory punt/egress rings (single ring pair, eventfd
  wakeups) feed the dataplane component.

## VPP plugins (now consolidated in osvbng-vpp)

osvbng_punt (unified control-frame punt/egress over shm),
osvbng_ipoe, osvbng_pppoe (session datapath, LAC bridge),
osvbng_l2tp, osvbng_cgnat, osvbng_l2gw, osvbng_qos (incl. scheduler),
osvbng_srg, osvbng_tunnel, plus the retired template and the dead
fib-control (never called from Go; drop candidate).

## Test suites

Numbered containerlab topologies with robot suites, bngblaster
subscribers, FRR cores: smoke, HA smoke, IPoE and PPPoE local and
RADIUS variants, DHCP relay/proxy, CGNAT IPoE/PPPoE in both
allocation modes, and onward. These are the behavioral yardstick for
any rework.

## Known debts (see todo.md for the queue)

The punt plugin predates multi-worker discipline (shared ring,
counters, policer; per-interface gating not enforced in-node; egress
trace and interrupt re-arm defects; no broadcast receive-route
handling; unversioned shm header). ARP/ND terminate in Go rather than
the dataplane. Binapi bindings historically generated from a local
VPP tree rather than the release pipeline.
