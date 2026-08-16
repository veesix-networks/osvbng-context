# ADR 0010 - Gateway ARP and ND answered in the dataplane, SRG state convergent

- Status: Accepted
- Date: 2026-08-16
- Deciders: Brandon

## Context

Gateway address resolution is split across three uncoordinated
answerers today, and only one of them is HA-aware:

- ARP punts from enabled access sub-interfaces to the Go arp
  component, which answers for any address it knows in the right
  FIB (the gateway loopback and every other subscriber's assigned
  /32, proxy answering for peers), gated on SRG active state in
  Go, replying with the SRG virtual MAC or the parent's physical
  MAC.
- IPv6 NS never punts at all. The punt plugin registers only
  Router Solicitation; VPP's native ip6-nd answers NS for the
  unnumbered sub-interface with the sub-interface's own physical
  MAC, with no SRG gating. A standby HA node answers NS today,
  with a MAC that is not the virtual MAC subscribers were told.
  The Go NS handler exists but is unreachable. VPP's native RA
  timer also runs unsuppressed on those sub-interfaces, so an
  ungated physical-MAC RA is emitted beside Go's SRG-gated
  per-session RA.
- The PPPoE in-band NS and RS responder falls back to the
  physical parent MAC when the SRG is standby (GetVirtualMAC
  returns nil) and answers anyway.

The punt path is also a storm surface (every CPE ARP refresh
transits shared memory, a bounded channel and a goroutine) and a
restart gap: while osvbngd is down nothing answers ARP, and
subscribers age out their gateway entry.

Go's ownership view (pkg/ifmgr) is a cache of VPP state, already
acknowledged in code as able to go stale after interface reloads.
The FIB itself holds everything the answer needs: gateway
addresses are local receive routes on the loopback the access
sub-interface is unnumbered to, and every subscriber address is
an attached-host route the session plugins install under their
own FIB source in the session's table.

SRG dataplane state (osvbng_srg holds per-SRG is_active and the
virtual MAC) is programmed edge-triggered with no read-back, no
retry and no reconciliation. The enumerated divergence windows: a
VPP restart loses every SRG until the daemon restarts (recovery
never re-registers them); a daemon restart electing STANDBY never
asserts standby (the edge trigger sees no transition), leaving
the previous active vMAC installed; a crash skips the graceful
DelSRG; a failed set_state RPC is logged and forgotten, flipping
only Go's view; interfaces created after HA start are never
added. There is also a granularity mismatch: Go resolves SRG per
subscriber group, the plugin per registered parent interface, so
two groups on one parent cannot belong to different SRGs.

The CUPS design study's conclusions, carried by substance in the
queue, address exactly this: the dataplane is the only responder
for ARP and ND, gated on group state held in the dataplane, drop
not punt (TR-459 6.2.2 permits punt-or-drop and drop is chosen);
the session is the neighbor entry, received ARP, NS and NA never
create or update bindings; a standby answers nothing, which is
what makes it invisible with no extra machinery; and programmed
dataplane state is desired state the control plane converges,
not commands it fires and forgets.

## Decision

**ARP and IPv6 ND stop punting. The dataplane is the only
responder, answering from its own FIB and session state, gated on
SRG state held in the dataplane; and the Go daemon treats
dataplane SRG state as desired state it converges (asserted
absolutely, read back, retried, re-asserted on every dataplane
epoch), never as edge-triggered commands.**

- Ownership test, in-node: answer when the target is a local
  receive route in the RX sub-interface's FIB (the gateway), or
  an attached-host /32 or /128 installed by a session plugin's
  FIB source in that FIB (preserving today's proxy answering for
  peer subscribers), excluding the requesting session's own
  address (DAD, RFC 5227 probes stay unanswered). NS additionally
  answers the gateway link-local derived EUI-64 from the
  answering MAC (RFC 4861). Everything else drops with a counter;
  nothing punts. Received ARP, NS and NA never create bindings.
- Source identity, in-node: the SRG virtual MAC when the
  sub-interface's SRG is active; the port MAC when no SRG covers
  it; when an SRG covers it and is not active, drop, never fall
  back to the physical MAC. The PPPoE in-band responder in Go
  adopts the same never-fall-back rule.
- SRG membership moves to sub-interface granularity, the same
  granularity punt gating already uses, closing the two-groups
  one-parent gap and matching Go's group-keyed resolution.
- Native VPP behaviors that contradict the single-responder rule
  are disabled on access sub-interfaces: the native RA timer is
  suppressed, and NS dispatch is owned by the responder node with
  passthrough for non-access interfaces.
- RS keeps punting and RA generation stays in Go: RA is
  policy-rich (per-group templates, lifetimes, cessation) and
  already SRG-gated there. Offloading RA is a separate future
  decision if punt headroom demands it.
- Convergence: the SRG .api gains a dump so state can be read
  back. Go asserts the full desired SRG set (add, membership,
  state, all idempotent in the plugin) at HA start, on every VPP
  recovery, and on a periodic audit that diffs the dump against
  desired state; failed programming retries until convergent. A
  VPP restart is an epoch: everything the daemon believes is
  programmed is invalid until re-asserted, and recovery re-runs
  the assertion before anything announces. One mechanism covers
  daemon restart, dataplane restart and silent drift.

## Consequences

- Standby invisibility becomes a dataplane-local property that
  holds across daemon restarts and control-plane unreachability.
  The two live gating bugs (ungated native NS answering, ungated
  native RA) are fixed by construction, not by patching Go.
- The ARP and ND punt storm surface disappears, and gateway
  resolution keeps working while osvbngd is down or restarting.
- The FIB is the responder's only truth: no second table to sync,
  because the session plugins' FIB entries are already the
  programmed session state. The FIB source becomes contract.
- New .api surface (SRG dump, sub-interface membership, responder
  enable) is staged behind the plugin capability query; Go keeps
  the punt-and-answer path as fallback when the plugin predates
  the capability, and the ARP and ND punt protocols are retired
  once the responder is the only path.
- Proxy answering for peer subscribers is preserved deliberately;
  narrowing to gateway-only would change subscriber-visible
  behavior and needs its own decision.
- The audit tick and the reconcile assertions are new control
  plane work, bounded (SRG count, not session count) and off the
  hot path.

## Alternatives considered

- Fix SRG gating in Go and keep punting: leaves the restart gap
  and the storm surface, and leaves the native NS and RA
  answerers ungated; rejected.
- Punt NS to Go like ARP: doubles the v6 storm surface to fix a
  gating bug the dataplane can fix locally; rejected.
- A dedicated gateway-address table programmed into the plugin:
  a second copy of state that can drift; the FIB already encodes
  ownership; rejected.
- Retry-only programming without dump and audit: closes the RPC
  failure window but cannot detect the VPP-restart and
  crash-stale windows, which need read-back; rejected.
