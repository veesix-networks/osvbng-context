# ADR 0003 - One session setup primitive with opdb as authoritative inventory

- Status: Accepted
- Date: 2026-08-14
- Deciders: Brandon

## Context

VPP and the osvbng daemon fail independently. Across a daemon
restart, VPP keeps session interfaces, FIB entries, adjacencies, and
punt registrations, while the daemon loses its in-memory session
maps, indexes, and interface cache. When VPP restarts under a live
daemon, the reverse holds. Per-session programming spans many
objects: the plugin session entry and rewrite, the /32 FIB entry,
the unnumbered binding, MTU and MSS clamp, IP bindings,
service-group policy (QoS, ACL, uRPF, rate limits), CGNAT mappings,
per-session punts, and accounting baselines. Separate bring-up,
restore, and failover code paths each replayed a subset, so adding a
per-session feature meant registering it in every path, and recovery
silently dropped whatever a path forgot.

## Decision

**Each subscriber component (internal/ipoe/, internal/pppoe/)
exposes one primitive, setupSession(state, mode), that owns all
per-session VPP programming for fresh bring-up and restore, and
opdb is the authoritative inventory of which sessions should
exist.** Recovery from daemon restart, VPP restart, and cold boot is
one loop: for each session in opdb, run setupSession in restore
mode. VPP plugin pools and the Go-side interface manager are derived
caches, reconcilable from opdb at any time; recovery replays opdb
into VPP, it never discovers sessions from VPP.

Supporting contracts:

- opdb checkpoints persist what cannot be derived: lookup keys,
  addresses and lease times, PPP phase and negotiated options,
  LAC tunnel binding, LCP echo sequence, and accounting baselines.
  FSMs, dispatchers, and index maps are in-memory only and rebuilt
  at restore time.
- VPP plugin add APIs are idempotency-aware. The l2gw, cgnat, and
  pppoe plugins use a three-state contract: no key match creates
  fresh; a key match with identical inputs returns success; a key
  match with drifted inputs returns ENTRY_NEEDS_REFRESH and the Go
  side deletes and recreates. The ipoe session add rejects
  duplicates outright, and its per-family binding setters are
  idempotent (no-op when identical, replace when drifted). Every
  setupSession step checks its own precondition and noops when
  state already matches.
- setupSession is transactional: a critical-step failure rolls back
  the steps already completed. On restore failure the opdb entry
  stays intact and the next restart retries; a session is never
  left partially programmed.
- Components gate the punt path on readiness (NotReady, Restoring,
  Ready, Draining). New PADI and DHCPDISCOVER packets are dropped
  while Restoring; protocol retransmits cover the window. The
  watchdog flags a component stuck in Restoring.
- Restored sessions publish a dedicated restored-session event, not
  the normal lifecycle and programmed events, so AAA never emits a
  duplicate RADIUS Accounting-Start (RFC 2866) and HA does not
  re-replicate sessions the standby already has. Counter baselines
  are rebaselined so Acct-Interim totals stay monotonic across VPP
  counter resets.

## Consequences

Every per-session feature participates in recovery automatically by
being a setupSession step; there is no second place to register it.
Restore runs asynchronously with bounded concurrency (worker pool,
default 8). A session whose restore fails is absent from the
dataplane and re-establishes via its normal handshake, which is
accepted degraded behaviour; forwarding without policy is not.

Two gaps remain deliberate but open. Teardown is not yet a single
mirrored primitive; it lives across the session termination paths.
HA failover restore (restoreFromHASync) is a separate inline path
that duplicates programming logic instead of calling setupSession;
folding it in is pending work, and until then per-session features
must still be added there by hand.

## Alternatives considered

- Rediscover sessions from VPP state at startup: rejected, VPP holds
  no control-plane state (session IDs, leases, accounting identity),
  so opdb must be the source of truth.
- Fix each recovery path individually: leaves N paths to maintain
  and the same silent-subset failure class.
- Publishing normal lifecycle events on restore: causes duplicate
  RADIUS Accounting-Start and HA re-replication; a dedicated
  restored event avoids both.
