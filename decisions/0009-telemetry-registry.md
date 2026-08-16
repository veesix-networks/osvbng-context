# ADR 0009 - Typed telemetry registry as the only metrics path

- Status: Accepted
- Date: 2026-08-16
- Deciders: Brandon

Mined from the legacy context repo's telemetry specs (the SDK
registry, shape-independent RegisterMetric, and legacy caller
migration). Implemented across osvbng#299 and follow-up PRs; this
ADR records the decisions that still bind.

## Context

The original observability pipeline registered a collector per show
path, JSON-marshalled every handler response into an in-memory
cache on a 5 second tick, and had the Prometheus exporter
unmarshal the blob and walk it with reflection on every scrape.
At 48,000 subscribers this measured 117 percent CPU with zero
traffic. There was no cardinality guardrail: one registration that
labelled by session identity produced 192,000 series. The
in-process event bus was evaluated for metric fan-out and rejected,
its goroutine-per-event-per-subscriber dispatch is the wrong
profile for counter updates.

Metric state and operational state are different problems that had
been given one answer. Operational state (show commands, the CLI,
the API) wants a fresh, complete answer per request. Metric state
wants a cheap, always-current value that many exporters read on
their own schedules.

## Decision

**All metric state flows through the typed in-memory registry in
pkg/telemetry. Exporters consume the registry, never components,
and the JSON-cache collector pipeline is retired and banned by
test** (pkg/telemetry/migration_audit_test.go fails the build on
any reference to the legacy registration calls or cache keys).

The registry's contract:

- Counters, gauges and histograms are atomic primitives. The hot
  emit path on a pre-resolved handle is one atomic instruction,
  zero allocations.
- Label tuples resolve to handles once, on the cold path
  (component start, session establishment). The variadic emit
  convenience is lookup-or-drop, never lookup-or-create: an
  unknown tuple bumps a drop counter and returns. Lazy creation on
  a hot path is exactly the failure mode that produced the
  192k-series incident.
- Cardinality is enforced at registration. A default reject list
  refuses labels that are unbounded in a BNG (session, subscriber,
  address, MAC, circuit and username identifiers) unless the
  metric is marked streaming_only, which excludes it from the
  Prometheus-safe snapshot. A per-metric series cap (default
  10,000) returns a singleton tombstone handle when crossed;
  tombstone emits count into a drop metric, so a cardinality
  cliff is observable in the telemetry of the telemetry system.
- Streaming subscribers are served by a single tick goroutine
  reading per-metric dirty flags, so emit cost does not scale with
  subscriber count. Subscriber channels are bounded, overflow
  policy is drop only; a slow subscriber must not stall the tick.
- Two emission models, no third: hot-path push through typed
  handles for events on the critical path, and show-driven pull
  (RegisterMetric on a show path, struct tags naming the metrics)
  for state-shaped data a show handler already returns. Show polls
  run on a fixed 10 second cadence that is deliberately not an
  operator knob.
- Series lifecycle for show-driven metrics defaults to
  clear_on_absent: tuples that vanish from a successful poll are
  unregistered, and poll errors do not trigger unregistration.
  retain_stale is a per-field opt-in for last-known-state query
  semantics. Push-model callers clean up per-session series
  explicitly on teardown.
- Lifecycle events (session up, HA transitions) stay on the event
  bus; the registry carries only metric state.

## Consequences

- Emit costs about 4 ns with zero allocations, measured identical
  with and without streaming subscribers. The 117 percent idle CPU
  cost is gone.
- Exporters read the registry through snapshots or subscriptions,
  so adding an exporter never touches components. As of 2026-08
  the Prometheus exporter is the only consumer built; Subscribe
  and streaming_only exist in the SDK, tested, for streaming
  exporters that have not been written. Until one is, a
  streaming_only metric is visible to no exporter at all.
- Adding a metric means choosing an emission model and passing the
  cardinality rules; a registration that violates them panics at
  process start rather than shipping wrong or unbounded data.
- Show handlers that feed metrics must return immutable snapshots;
  the SDK reads without copying.
- Every show-driven registration buys a poll every 10 seconds on
  the shared core. For vtysh-backed paths that is a fork per
  registered path per tick, so registration is a cost decision,
  bounded summaries only (design/routing-frr-bridge.md).
- Metric-level unregister is unsupported; metric lifetime is
  process lifetime. Only series come and go.

## Alternatives considered

- Optimizing the JSON cache pipeline: rejected, the reflection and
  marshalling cost was structural, not a tuning problem.
- Per-emit subscriber fan-out: rejected, couples hot-path cost to
  subscriber count; the dirty-flag tick keeps emit constant.
- Reusing the event bus for metrics: rejected, its per-event
  goroutine dispatch suits lifecycle events, not counter updates.
- Blocking subscriber channels: rejected, one slow subscriber
  would stall publication to all others.
- A telemetry YAML config block: rejected, tunables are
  programmatic setters wired from osvbngd main; a config namespace
  with no operational meaning invites invented policy.
