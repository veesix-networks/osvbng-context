# ADR 0011 - LCP echo answered and generated in the osvbng_pppoe plugin

- Status: Accepted
- Date: 2026-08-16
- Deciders: Brandon

## Context

Every LCP frame, echo included, reaches Go through one branch in
osvbng-pppoe-input (non-IP PPP punts; only IPv4 and IPv6 decap
in-node). Go answers peer Echo-Requests per session and generates
ours from a shared 60-bucket time wheel. Per echo that costs two
serialize or parse passes, an event-bus hop, both shared-memory
rings, and a goroutine per punted reply; at 128k sessions on a
30 second interval that is roughly 8,600 frames per second
crossing the seam in steady state, before any storm. During a
daemon restart nothing answers the CPE's echoes, so a restart
longer than the CPE's patience (commonly 30 to 60 seconds) tears
sessions down from the subscriber side, defeating the point of
sessions surviving restarts.

The plugin's session entry already carries everything a reply or
a generated request needs (both MACs, both VLANs, TPID, session
id, encap interface); what it lacks is echo state: magic, an
enable bit, interval, identifier, miss counter, last-seen. RFC
1661 section 5.8 fixes the protocol contract: an Echo-Request in
LCP Opened state MUST be answered, echo packets outside Opened
are silently discarded, the reply copies the request's
Identifier, and the magic in the reply is the responder's own.

Two adjacent facts constrain the work. First, a source-of-truth
defect found while scoping: the Go bindings and callers use PPPoE
IPv6 binding messages (set_session_ipv6, set_delegated_prefix)
that exist only on a branch of the archived pre-monorepo plugin
repo, are absent from osvbng-vpp and from the shipped plugin, and
fail silently on every dual-stack PPPoE session; the suites
assert only the API view and stay green. That work must be
imported before the .api grows again. Second, the plugin has no
capability query, which the plugin rules require and which the
staged rollout below depends on.

## Decision

**LCP Echo-Request answering and generation move into
osvbng_pppoe, enabled per session by the control plane once LCP
reaches Opened; only the miss-threshold event punts, as a
synthetic punt frame; every other LCP frame keeps punting; none
of it applies to LAC sessions, whose PPP rides through to the
LNS untouched.**

- Responder: in osvbng-pppoe-input, after the LAC bridge check
  and before the non-IP punt. An Echo-Request for an
  echo-enabled session is converted in place (MACs swapped, code
  set to Echo-Reply, our magic written, Identifier preserved)
  and transmitted out the encap interface. The Opened-state rule
  is enforced by the enable bit itself: Go enables echo after
  LCP opens and disables it on terminate, so pre-Opened echo
  frames keep punting and post-teardown ones drop.
- Generation: a bucketed sweep bounded per tick (the shared-core
  rules govern; no walk of 128k sessions in one dispatch), frames
  built the way the LAC TX path already builds PPPoE frames.
  Identifier and miss accounting live in the session entry;
  reply arrival is recorded by the worker the reply lands on,
  read by the sweep.
- SRG rule from ADR 0010 applies: generation is suppressed and
  the responder drops while the covering SRG is not active.
- Miss threshold: one synthetic punt frame (its own punt
  protocol id) carrying the session identity; Go runs exactly
  the dead-peer teardown it runs today. The plugin never tears a
  session down itself.
- .api: a set_session_echo message (enable, magic, interval,
  miss threshold) keyed by sw_if_index, idempotent like
  set_lac_tunnel, and a capability query on the plugin. Go uses
  the time wheel unchanged when the capability is absent, so old
  dataplanes keep working.
- Import first: the archived pppoe-ipv6-binding work lands in
  osvbng-vpp before the .api is extended, restoring source truth
  for messages the control plane already sends.

## Consequences

- Two frames per session per interval leave the punt and egress
  rings, the bounded channels and the per-packet goroutines;
  keepalives keep flowing across daemon restarts, which is the
  stated goal.
- The plugin gains its first periodic machinery; its budget per
  tick is stated in the code and measured in the perf rig, and
  the plugin PR carries before and after Clocks/Packet numbers.
- Magic numbers become programmed dataplane state; restore
  reprograms them, and the Go-side EchoSeq checkpoint becomes
  fallback-only.
- The .api version bumps behind the capability query; Go carries
  both paths until fleets update, then the wheel path is
  removed.
- Dual-stack PPPoE dataplane bindings start actually working
  once the import lands; a suite must assert the dataplane view
  (traffic or FIB), not only the API view, to keep it that way.

## Alternatives considered

- Keep the Go wheel and optimize it: cannot answer while the
  daemon is down, which is the requirement that matters;
  rejected.
- Per-session VPP timers instead of a bucketed sweep: 128k
  timers of scheduler pressure for a 30 second cadence;
  rejected.
- Answering echo before LCP Opened without the enable bit:
  violates RFC 1661 section 5.8's silently-discard rule and
  answers for half-negotiated sessions; rejected.
- Plugin-initiated teardown on miss: puts session lifecycle
  policy in the dataplane, against the plugin rules; the event
  punts and Go decides; rejected.
