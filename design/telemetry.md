# Telemetry, how metric state moves

How a number measured anywhere in osvbng reaches an operator's
dashboard. Read this before adding a metric, instrumenting a show
handler, or touching an exporter. The governing decision is ADR
0009; the authoritative SDK mechanics (API, tag grammar, hash and
subscribe internals, benchmarks) live with the code in
`osvbng/docs/architecture/TELEMETRY.md` and this note does not
duplicate them.

File references are against the osvbng repo as of 2026-08.

## Shape

`pkg/telemetry` is a typed in-memory registry of counters, gauges
and histograms. Everything that produces metric state writes into
it, everything that exports metric state reads out of it, and the
two sides never meet directly.

Producers feed it two ways:

- Push: code on the critical path (AAA requests, session
  lifecycle, HA transitions) registers typed metrics and emits
  through pre-resolved handles, one atomic per emit.
  `internal/aaa/stats.go` is the reference caller.
- Pull: show handlers whose return type carries `metric:"..."`
  struct tags call `telemetry.RegisterMetric[T](path)` in their
  `init()`. `StartShowPollers` (wired once in osvbngd main) polls
  every registered path on a fixed 10 second cadence
  (`showPollInterval`, `pkg/telemetry/show.go`) and walks the
  result into series. The cadence is deliberately not an operator
  knob; `docs/configuration/monitoring.md` documents that there is
  nothing to configure.

Consumers read it two ways: snapshot pull (the
`plugins/exporter/prometheus` plugin renders `AppendSnapshot` on
every scrape) and subscription push (the gRPC streaming exporter
and gNMI gateway receive tick-driven updates for changed metrics).
Adding an exporter touches no component.

Lifecycle events are not metrics. Session up, HA failover and
interface transitions travel the event bus (`pkg/events/`); the
registry carries only measurable state. If a consumer needs the
event itself, subscribe to the bus, do not poll a gauge.

## Choosing an emission model

Hot-path push when every occurrence matters and the code already
runs per event: request counters, error counters, latency
histograms. Show-driven pull when a show handler already returns
the state and the metric is a reading of it: VPP interface stats,
protocol neighbor state, pool occupancy. When both would work,
pull keeps the plugin folder self-contained (registration, tags
and handler in one package) and costs one poll per 10 seconds;
push costs a handle per series and runs on your critical path.

## Rules that bind sessions

1. Metrics go through `pkg/telemetry`, full stop. No private
   Prometheus registries, no side caches, no exporter reading a
   component. `pkg/telemetry/migration_audit_test.go` fails the
   build on legacy `state.RegisterMetric` calls; do not add an
   allowlist entry.
2. No unbounded labels. The test: if the label's value set grows
   with subscribers, sessions or attack traffic, it is not a
   label. The reject list in `pkg/telemetry/cardinality.go`
   enforces the known BNG identifiers; do not weaken it, and do
   not launder identity through a label name it does not match.
   `streaming_only` is the sole escape, it hides the metric from
   Prometheus, and the registering component owns
   `UnregisterSeries` cleanup on teardown.
3. Registration is a cost decision. Each registered show path is
   polled every 10 seconds on the shared control-plane core; for
   vtysh-backed handlers that is a fork and exec per path per
   tick. Register bounded summaries, never inventories. The
   routing-specific rules are in design/routing-frr-bridge.md.
4. Resolve label handles on the cold path and cache them. The
   variadic emit is lookup-or-drop and will silently count your
   emissions into a drop metric if the tuple was never resolved.
5. A show handler that feeds `RegisterMetric` returns an
   immutable, handler-owned snapshot. The SDK reads without
   copying, so a handler that mutates a returned map races the
   walker.
6. Series lifecycle stays on the default clear_on_absent unless
   the query semantic is genuinely "show me the last known state
   of a thing that no longer exists"; `retain_stale` is per field
   and the reason belongs in a comment at the tag.
7. Misregistration (duplicate names, label collisions, cyclic
   flatten, nested maps) panics at process start by design. Fix
   the registration, never wrap it in recover.

## Where the rest lives

- `osvbng/docs/architecture/TELEMETRY.md`: SDK internals, the
  full `metric:"..."` tag grammar, registration error catalog,
  benchmarks, HA dimension.
- `osvbng/docs/configuration/monitoring.md`: operator view.
- design/routing-frr-bridge.md: per-command cost rules for FRR
  show paths.
- ADR 0009: the decision record and alternatives.

Known drift, 2026-08: `osvbng/docs/architecture/COLLECTORS.md`
and the collector section of `PLUGINS.md` still describe the
retired JSON-cache pipeline, and the TELEMETRY.md architecture
diagram shows a 30 second expensive-pull tier that does not exist,
the code has a single 10 second cadence. Trust `pkg/telemetry`
over any diagram until those pages are corrected in osvbng.
