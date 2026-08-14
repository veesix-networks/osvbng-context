# QoS architecture

This note describes per-subscriber QoS: the VPP policer model, where
policer identity lives, how policer and CAKE scheduling coexist, and
how the southbound negotiates plugin capabilities. S-VLAN and port
aggregate shaping are covered in the QoS aggregates note.

## Direction convention

Directions are wire directions on the subscriber's session
interface, and the convention is fixed project-wide: egress is
toward the subscriber, so the egress policy limits download
(network to subscriber); ingress is from the subscriber, so the
ingress policy limits upload (subscriber to network). The legacy
spec material used the opposite labels; the code and configuration
documentation use this one.

## Policer model

Each subscriber session gets per-direction rate limiting from VPP
policers attached to the session interface. Two terms recur:

- A policy is a named, reusable policer configuration template
  (rates, burst sizes, algorithm, actions), defined under
  qos-policies in the configuration and referenced by name from
  service groups.
- A session policer is a VPP policer instance created from a policy
  and attached to one session interface.

AAA can override the policy name per subscriber, or supply raw
upload and download rates that create ad-hoc policers with no named
policy behind them. Policers are created at session activation and
removed at session release.

## Policer identity lives in the southbound adapter

Per-subscriber QoS state is deliberately kept out of the session
model. The VPP southbound (pkg/southbound/vpp/) tracks the policer
names per session interface, one per direction, derived
deterministically from the interface index. Policers are driven
through the name-based v1 binapi (create and delete, input and
output binding); the v2 policer API is deliberately avoided (a
comment at the point of use records the upstream defect that forced
this). Applying QoS to an interface that already has policers is a
no-op; rate changes for an existing session go through remove and
re-apply on the session lifecycle, and policy template changes take
effect for sessions activated after the change.

All policer operations serialize through a single mutex in the
southbound, so concurrent session activation and release cannot
interleave half-programmed policer state.

## CAKE scheduling and coexistence

A CAKE-derived per-subscriber scheduler (a separate VPP plugin with
shaping, DRR flows, COBALT AQM, DiffServ tins, and overhead
compensation) is the alternative to a policer for the download
direction. The rules:

- The resolved egress policy decides per subscriber: a policy with
  a scheduler block applies CAKE for download, with a policer still
  applied for upload; a policy without one applies policers in both
  directions. Both kinds of subscriber coexist on one box.
- CAKE takes a single rate. There is no PIR/CIR split for scheduled
  subscribers; the scheduler absorbs bursts through queue
  management and AQM rather than token buckets.
- The qos.download-rate AAA attribute feeds the CAKE rate, with
  service group configuration providing defaults.

## Capability negotiation

The southbound probes the QoS plugin's capabilities message once
and caches the answer: which API version the scheduler accepts and
whether the S-VLAN aggregate tier and weighted DRR are present. An
absent message is a valid answer meaning the older plugin; the
scheduler apply path falls back from the v2 to the v1 message
accordingly. This is the pattern every plugin follows (per-plugin
capability query, see the vpp repo rules): the control plane
discovers what it is talking to instead of assuming.
