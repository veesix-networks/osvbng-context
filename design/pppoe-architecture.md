# PPPoE architecture

This note describes how osvbng terminates PPPoE subscribers: the
package layout of the PPP machinery in Go, the session bring-up
path from PADI to a programmed dataplane session, keepalives at
scale, and the seam to the VPP plugins. Session identification and
the per-subscriber interface model are in
design/subscriber-access-model.md; address and attribute
provisioning is in design/aaa-provisioning-model.md; the wholesale
LAC handoff is in design/l2tp-architecture.md. Read those first,
this note does not repeat them.

File references are against osvbng and osvbng-vpp as of 2026-08.

## Split of responsibility

- `osvbng_punt` plugin: registers ethertypes 0x8863 (discovery)
  and 0x8864 (session) and punts control frames to the daemon over
  the unified punt transport with per-packet metadata
  (sw_if_index, protocol, timestamp). Per-interface gating decides
  which ports punt at all.
- `osvbng_pppoe` plugin: session dataplane only. Its binapi
  (`osvbng_pppoe.api`) is `add_del_session`, `set_lac_tunnel` and
  `session_dump`; its nodes decapsulate session traffic onto the
  per-session interface and, for LAC mode, bridge PPP frames to
  the l2tpv2 plugin (`osvbng_pppoe_lac_tx.c`). No FSMs, no tags,
  no AAA.
- The Go control plane owns every state machine, split so protocol
  code is reusable and the component is wiring:
  - `pkg/pppoe/`: RFC 2516 discovery codec. Tag parse and build
    (including the RFC 4638 PPP-Max-Payload tag) and the AC-Cookie
    (HMAC-SHA256 over MAC and VLAN pair with a TTL), so discovery
    holds no per-peer state until a valid PADR arrives.
  - `pkg/ppp/`: RFC 1661 machinery, shared with the L2TP LNS
    role. The option-negotiation FSM, LCP, PAP and CHAP, IPCP,
    IPv6CP, phase tracking, and the echo timewheel.
  - `internal/ppp/`: the dispatcher routing inbound PPP frames by
    protocol number to the owning handler.
  - `internal/pppoe/`: the component. Discovery handlers, session
    lifecycle, dataplane programming (setup.go), echo driving
    (echo.go), IPv6 (ra.go, dhcpv6.go), LAC handoff (lac.go).

## Session bring-up

Discovery: PADI is accepted only when the arriving interface and
VLANs match a subscriber group; everything else is dropped without
state. PADO carries the AC-Cookie; PADR is validated against it
(HMAC plus TTL) before any session state is allocated, then PADS
assigns the PPPoE session id. This keeps the discovery phase
stateless under PADI floods.

PPP: LCP negotiates (MRU, magic, auth protocol), authentication
runs through the AAA providers (CHAP or PAP, attributes per the
provisioning model), then the NCPs. IPCP assigns the IPv4 address
from AAA attributes or pool allocation. IPv6CP negotiates the
interface identifier only; actual IPv6 addressing then follows the
same path as IPoE, router advertisements (ra.go, internal/ra) and
DHCPv6 IA_NA and prefix delegation (dhcpv6.go, pkg/dhcp6).

Programming: setup.go creates the per-session interface,
unnumbered to the service group loopback, installs the subscriber
routes, and programs the plugin session (`add_del_session`) keyed
by PPPoE session id plus MAC. From there the packet path never
touches Go. Lifecycle events on the bus drive accounting, CGNAT,
QoS and HA the same way IPoE sessions do.

If AAA returns Tunnel-* attributes instead of local addressing,
bring-up stops after authenticate and hands off to the L2TP
component as a LAC (design/l2tp-architecture.md).

## Echo keepalives at scale

LCP Echo-Request generation cannot walk every session per
interval at BNG scale. `pkg/ppp/timewheel.go` buckets sessions
across the echo interval and expires one bucket per tick, so load
spreads evenly and each tick touches only its bucket. The
`EchoState` entry carries everything needed to build the echo
frame (MACs, VLAN pair, magic), so the generator writes frames
without locking session state. Replies reset the miss count on
the wheel; `maxMisses` consecutive silent intervals terminate the
session through the normal teardown path.

## Restart and HA

Established sessions survive daemon restarts and failovers by
replay, not renegotiation: the PPP FSM has a `Restore` transition
that moves a checkpointed session directly to Opened without
running LCP or the NCPs and without firing layer-up callbacks, so
restoring a session is silent on the wire. Session state
checkpoints through opdb and the HA sync path shared with IPoE
(design/ha-architecture.md).

## Where to read further

- Punt transport and per-protocol gating:
  `osvbng-vpp/plugins/osvbng_punt/README.md`.
- Plugin session contract: `osvbng-vpp/plugins/osvbng_pppoe/`
  (osvbng_pppoe.api, decap and lac_tx nodes).
- Protocol texts in references/: RFC 2516 (PPPoE), RFC 1661 (PPP),
  RFC 1994 (CHAP), RFC 1334 (PAP), RFC 1332 (IPCP), RFC 5072
  (IPv6 over PPP), RFC 4638 (PPPoE MTU), RFC 1570 and RFC 1877
  (LCP extensions, IPCP name server options).
