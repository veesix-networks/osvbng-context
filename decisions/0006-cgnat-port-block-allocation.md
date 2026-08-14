# ADR 0006 - CGNAT port-block allocation architecture

- Status: Accepted
- Date: 2026-08-14
- Deciders: Brandon

## Context

CGNAT is a custom VPP plugin (`osvbng_cgnat`) driven by a Go
component (`internal/cgnat/`). Inside traffic hits `cgnat-in2out` on
the `ip4-unicast` feature arc of per-session interfaces; return
traffic arrives on outside interfaces. Multiple inside VRFs can
share one outside pool, so an inside IP alone does not identify a
subscriber. Port-block allocation (PBA) rather than per-session NAT
keeps logging volume and state churn bounded.

## Decision

**Allocator identity is `(inside_vrf_id, inside_ip)`.** Port block
uniqueness is enforced globally across VRFs sharing a pool, paired
address pooling operates per identity, and every lookup key carries
the VRF. One VPP mapping per `(inside_ip, inside_fib)` is the
invariant; `max-blocks-per-subscriber` governs Go-side allocation.

**out2in uses FIB/DPO steering, not a feature arc on outside
interfaces.** A custom DPO type and FIB source (`cgnat-outside`, at
high priority) route outside addresses to `cgnat-out2in`. Outside
prefixes are stored per pool for deferred FIB install, ICMP error
inner headers are translated (the RFC 5508 behaviour, verified for
both directions), and pool deletion removes FIB entries, drains
sessions, and waits for DPO refcount zero before freeing.

**Bypass uses FIB entries, not a per-IP bihash.** A `cgnat-bypass`
FIB source on VPP's native ip4 FIB gives O(1) LPM for any prefix
length; the dataplane check short-circuits when no bypass entries
exist. Go stores the prefixes; bypass is config-derived, so no HA
sync.

**Logging is at port-block granularity.** Block allocation and
deallocation are the logged events, not per-session translations,
and deterministic port-block derivation (RFC 7422) removes even that
logging need for pools configured in deterministic mode.

**Reconciliation follows a fixed authority chain.** The Go allocator
drives opdb and VPP in normal operation. On restart opdb is
authoritative; Go restores, then dumps and diffs VPP to fix orphans.
On async binapi failure Go rolls back; on opdb write failure Go is
authoritative in memory, opdb retries, and HA marks degraded.

## Consequences

- Subscribers with the same inside IP in different VRFs coexist on
  shared pools with disjoint port blocks.
- Disable withdraws the DPO and bypass FIB entries before freeing
  tables.
- Session table sizes are currently compiled into the plugin rather
  than configured; sizing them from a deployment scale profile is
  future work, not shipped.

## Alternatives considered

- out2in on the `ip4-unicast` feature arc of outside interfaces:
  rejected, the disabled path cannot use `vnet_feature_next`.
- Bypass via a custom bihash: a /24 needs 256 entries; rejected for
  prefix support and memory.
- Per-session logging: rejected, per-subscriber block events are
  orders of magnitude fewer and satisfy the same attribution need.
