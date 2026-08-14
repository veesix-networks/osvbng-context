# The control/dataplane seam

This note explains how work is divided between VPP and the Go
control plane, and how the two sides talk. Read it before deciding
where a new feature's logic belongs, or before touching punt
handling, session programming, or control-packet egress.

## The principle

VPP owns the hotpath: everything that happens to every packet of
every subscriber, millions of times per second. That work is
mechanical by design: classify the packet to a session, encap or
decap, look up the FIB, apply policers or scheduling, count, and
forward. VPP plugins hold only the state those operations need
(lookup tables, rewrites, counters) and make no protocol decisions.

The control plane owns everything that requires inspecting a packet
and reasoning about it: parsing DHCP options and synthesizing
replies, running PPP negotiation state machines, authenticating
against AAA, allocating addresses, deciding what a session is and
whether it may exist. This work is per-event, not per-packet: a
subscriber generates a handful of control packets at setup and
keepalives after, while the dataplane carries everything else.

The test for where logic belongs: if it runs per packet, it must be
mechanical and it lives in a VPP plugin; if it needs protocol
understanding or external state (AAA, pools, config), it is an
event and it lives in Go. A control-plane component must never sit
on the per-packet path, and a VPP plugin must never grow protocol
intelligence (see also the plugin rules in the vpp repo: plugins
expose mechanism, policy stays above).

## How the split falls per protocol

- DHCP (IPoE): VPP classifies subscriber IP traffic onto session
  interfaces and punts DHCP. All DHCP parsing, lease logic, option
  synthesis, and relay behaviour is Go; VPP never inspects a DHCP
  payload. The reply is injected back through egress.
- PPPoE: VPP does encap and decap for IPv4/IPv6 session traffic
  (lookup by MAC plus session id, midchain adjacency with a
  pre-built L2 rewrite) and punts every other PPP protocol.
  Discovery, LCP, authentication, IPCP/IPv6CP, and keepalive
  tracking are Go. A LAC-tunneled session is the exception that
  proves the rule: VPP bridges all its PPP frames straight into
  L2TPv2 encap, still without understanding them.
- ARP and ND: punted and answered by the control plane (with the
  SRG virtual MAC where HA is configured); VPP forwards, it does
  not answer.
- CGNAT: translation, session creation on the fast path, and ICMP
  error handling are entirely in-plugin; the Go side allocates
  port blocks, owns reconciliation, and never sees a translated
  packet.
- L2 wholesale (l2gw): circuit switching and VLAN rewrite are
  in-plugin; the control plane only installs circuits when a
  trigger punt arrives and auth succeeds.

## The three channels across the seam

Control traffic and programming cross the seam through three
channels, each chosen for its job:

1. Punt, VPP to Go: the osvbng_punt plugin copies designated
   control packets (ARP, DHCPv4/v6, ND, PPPoE, L2TP) into a
   shared-memory segment, one single-producer ring per VPP thread
   so workers never contend. The daemon reader drains the rings
   round-robin, blocks on an eventfd when idle, parses, and routes
   each packet to the owning component's channel. Punt enablement
   is per protocol and interface, and a punt policer can cap the
   rate so a misbehaving access network cannot melt the control
   plane.
2. Programming, Go to VPP: session create and delete, address
   bindings, policy attachment, and dumps go over the VPP binary
   API through the async transport (ADR 0008). API calls never
   carry packets and packets never program state.
3. Egress, Go to VPP: control-plane replies and keepalives are
   written to a single egress ring (the daemon is its only
   producer) with its own eventfd. The VPP egress node wakes,
   sets the TX interface, and enqueues directly to that
   interface's output node, bypassing the interface-output feature
   arc so replies still leave through interfaces the arc would
   drop.

A subscriber session's life in these terms: trigger packets punt
up; the component runs its protocol exchange and AAA; the session
is programmed down over the API and returns a session sw_if_index;
from then on the dataplane forwards, counts, and polices without
the control plane in the path, until teardown reverses the
programming.

## Protecting each side from the other

The seam is also where overload is contained, in both directions:

- A slow control-plane consumer cannot stall VPP: punt ring writes
  are lossy by design, component channel sends are non-blocking,
  and a full channel drops the packet with a warning. Protocol
  retransmits recover lost control packets.
- A burst of control-plane transmissions cannot block packet
  generation or grow memory without bound: the egress writer puts
  a bounded channel in front of the ring, drained by one goroutine
  in batches; when it fills, sends fail fast and the drop is
  counted. Dropped keepalives delay dead-peer detection rather
  than tearing down established sessions.
- Programming pressure is bounded by the async transport's stream
  pool, which applies backpressure toward VPP, and its circuit
  breaker, which fails fast when VPP is gone (ADR 0008).

## Control-plane work at dataplane-adjacent scale

Some control-plane work scales with session count and needs
hotpath-style discipline even though it is not per-packet. LCP
keepalives are the canonical case: at 128K sessions and a 10 to
60 second echo interval, generation runs from a hashed time wheel
(pkg/ppp/, 60 buckets) with a per-tick generation cap, not from
per-session timers, and echo transmit goes through the same bounded
egress path as everything else. The pattern generalizes: periodic
RA, accounting interim buckets, and GARP batches on HA failover all
spread their load the same way instead of firing per-session work
simultaneously.
