# L2TP architecture

This note describes how osvbng does L2TPv2 (RFC 2661), both roles:
LAC, tunneling a PPPoE subscriber to a remote LNS, and LNS,
terminating PPP arriving from an external LAC. It covers the
control-plane layout in Go and the seam to the dataplane. The
dataplane's own documentation is authoritative for the datapath:
`osvbng-vpp/plugins/l2tpv2/README.md` covers the tunnel and session
model, decap modes, graph nodes and the bridge contract.

File references are against osvbng and osvbng-vpp as of 2026-08.

## Split of responsibility

Three parties, each deliberately ignorant of the others' internals:

- `l2tpv2` plugin (osvbng-vpp): dataplane only. Session and tunnel
  bihash tables, L2TPv2 header parse, decap and encap, FIB-resolved
  egress. No control channel, no AVPs, no PPP, no AAA. It is a
  rule 10 exemplar: any control plane that speaks its binapi and
  any PPP-bearing plugin that follows its bridge contract composes
  with it.
- `osvbng_punt` plugin: owns UDP/1701 registration and demuxes on
  the T-bit. Control frames (T=1) punt to userspace; data frames
  (T=0) go to `l2tpv2-input` via a graph arc. The l2tpv2 plugin
  never registers the port itself.
- osvbng control plane: everything with a state machine. Protocol
  machinery in `pkg/l2tp/` (AVPs and catalog, header codec,
  reliable control channel with Ns/Nr and ZLB, tunnel and session
  FSMs, challenge auth, result codes, v3 detection and rejection).
  Orchestration in `internal/l2tp/` (per-peer tunnel pool keyed by
  (peer_ip, local_tunnel_id), per-tunnel session pool, dispatch,
  Hello, ID allocation, peer denylist, AAA and HA and opdb wiring,
  UDP sender). PPP itself lives in `pkg/ppp/` (LCP, auth, IPCP,
  IPv6CP), shared with the PPPoE component rather than duplicated.

## LAC path (wholesale handoff)

A PPPoE subscriber is brought up to the authenticate phase, then
AAA decides it is wholesale: the Access-Accept carries Tunnel-*
attributes instead of local addressing, looked up by
agent-remote-id with authenticate=false at the LAC (the LNS owns
credential validation). The PPPoE component builds a
`LACBringUpRequest` (internal/l2tp/lac.go) carrying the parsed
tunnel specs, the PPPoE session identity for the dataplane
binding, and proxy-LCP plus proxy-auth AVPs so the LNS can adopt
the already-negotiated LCP state instead of renegotiating.

Control brings the tunnel up (SCCRQ, SCCRP, SCCCN, with
Challenge-AVP auth when configured) and the session inside it
(ICRQ, ICRP, ICCN). The dataplane bridge then uses the plugin's
`DECAP_RAW` mode: no per-session interface, PPP frames pass
intact. Upstream, the PPPoE plugin enqueues subscriber PPP frames
to `l2tpv2-encap-raw` with the session index in the shared buffer
opaque; downstream, `l2tpv2-input` forwards decapped frames to the
PPPoE plugin's `osvbng-pppoe-lac-tx` node named at session-add.
Neither plugin knows the other exists beyond that contract.

## LNS path (local termination)

Inbound from an external LAC, the roles flip: osvbng answers the
control messages, and each session terminates PPP locally through
`pkg/ppp/` with optional proxy-LCP adoption from the LAC's AVPs.
Addressing follows the same provisioning model as PPPoE
subscribers: IPv4, IPv6 IANA and PD allocation from local pools or
AAA attributes (design/aaa-provisioning-model.md).

The dataplane uses `DECAP_IP` mode: a per-session vnet interface,
unnumbered to the service group, with FIB-bound subscriber routes.
Ingress strips L2TP and the PPP protocol field and dispatches to
ip4-input or ip6-input; egress is a midchain adjacency whose
rewrite stacks on the FIB-resolved path to the peer, so an LNS
peer reachable via a loopback route works without special casing.
Whether the peer sends a full HDLC PPP header or a bare protocol
field is an operator knob (`ppp-framing`, per profile, peer-policy
or LNS server) resolved at session setup into a fixed header-skip,
keeping the per-packet path branch-free.

## Where to read further

- Dataplane model and bridge contract:
  `osvbng-vpp/plugins/l2tpv2/README.md`; punt demux in
  `osvbng-vpp/plugins/osvbng_punt/`; the LAC bridge consumer in
  `osvbng-vpp/plugins/osvbng_pppoe/`.
- Operator-facing config and examples: `osvbng/docs/configuration/
  l2tp.md`, `osvbng/docs/examples/l2tp-{lac,lns}.md`.
- Protocol text: RFC 2661 in references/, with the L2TPv2 corpus
  (RFC 3437 PPP LCP extensions, RFC 4951 failover) alongside it.
- Test suites: `osvbng/tests/30-l2tp-lns` and `31-l2tp-lac`.
