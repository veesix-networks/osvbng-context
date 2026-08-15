# Routing, the FRR bridge

This note describes how osvbng talks to FRR: the wrapper layer that
executes vtysh, the typed models the JSON output lands in, the show
registry that serves operators, and the telemetry SDK hookup with its
cost rules. Read it before adding or changing any routing show
command, and before touching `internal/routing/` or
`pkg/handlers/show/protocols/`.

File references are against the osvbng repo as of 2026-08.

## Shape of the bridge

The `routing` component (`internal/routing/`) is the only place that
executes `vtysh`. It has two faces:

- Configuration: `ConfigureBGP` style calls plus
  `Advertise/WithdrawBGPNetwork` and `Advertise/WithdrawSRGNetworks`
  run `vtysh -c "configure terminal" -c ...`
  (`internal/routing/component.go`).
- Operational reads: `(c *Component) GetX(...)` wrappers run
  `c.execVtysh("-c", "show ... json")` and unmarshal into typed
  models. BGP and VRF getters live in `component.go`; OSPFv2 and
  OSPFv3 share `ospf.go`; ISIS, LDP and zebra have their own files.

Two protocol families do not go through vtysh at all: the MPLS and
FIB show handlers (`pkg/handlers/show/protocols/{mpls,fib}/`) read
VPP state through the southbound (binapi). They still use the same
registry and telemetry pattern below, only the source differs.

## The per-show-command pattern

Every routing show command is four small pieces:

1. `internal/routing/<proto>.go`: the wrapper. Builds the exact FRR
   command, executes it, parses.
2. `pkg/models/protocols/<proto>/<name>.go`: the model struct.
   Instrumentable fields carry `metric:"..."` tags; CLI-only fields
   stay untagged.
3. `pkg/handlers/show/protocols/<proto>/<name>.go`: a `ShowHandler`
   whose `init()` calls `show.RegisterFactory` and, only when the
   cost rule below allows it, `telemetry.RegisterMetric[T]`.
4. `pkg/handlers/show/paths/paths.go`: a new `ProtocolsXxx` path
   constant.

Commands whose output is an unbounded inventory (LSDB dumps, full
route tables, per-prefix lookups) skip the typed model and return
`json.RawMessage` straight through, for example `GetOSPFDatabase`
and the zebra route getters. A typed model earns its place only when
fields feed metrics or need per-field handling.

## VRF conventions

Most FRR show commands carry a `[vrf <NAME|all>]` modifier. The
rules, applied uniformly:

- The operator path defaults to no `vrf` keyword, which is the
  default routing table only. A single name becomes `vrf <name>`,
  the literal `all` becomes `vrf all`. Handlers read
  `req.Options["vrf"]` and pass it to the wrapper.
- User input is never spliced into a vtysh command unvalidated. The
  wrapper validates against `^(all|[A-Za-z0-9_-]+)$`
  (`ospfVRFNameRE` in `internal/routing/ospf.go`) before building
  the command.
- Never run `vrf all` and filter the response down to one VRF on
  the client side. That over-fetches every VRF's state when the
  operator wanted the default table, and pollutes single-VRF
  metrics with a forced `vrf` label.
- Multi-VRF telemetry is a separate path, suffixed `.all`
  (`protocols.ospf.all`, `protocols.ospf.interfaces.all`). Its
  handler always runs `vrf all` and returns a map keyed by VRF
  name; the model wrapper emits the VRF as a label via
  `metric:"label=vrf,map_key"`. CLI calls land on the un-suffixed
  path and pay default-VRF cost only.

## Faithful command translation

Modifiers documented in the FRR command reference belong on the
wrapper's argument list or in `req.Options`, not encoded into new
path constants. `show ip ospf interface <IFACE>` is
`req.Options["interface"]`; `show ip ospf route detail` is
`req.Options["detail"]`; a per-neighbor query is a wildcard segment
in the path plus options. The path space stays one constant per FRR
command, not one per modifier combination.

## Telemetry registration is a cost decision

`telemetry.RegisterMetric[T](path)` queues the path at init; at
startup `StartShowPollers` (called once from `cmd/osvbngd/main.go`)
spawns one goroutine per registered path, polling on a fixed 10s
cadence (`showPollInterval` in `pkg/telemetry/show.go`). The
cadence is deliberately not an operator knob. For a vtysh-backed
handler, every registered path is one vtysh fork and exec every 10s
on the shared control-plane core.

So registration is reserved for bounded-cardinality state:
instances, interfaces, neighbors, GR helper counts, route summary
counters. Inventory commands (LSDB dumps, route tables, border
routers, summary-address, per-prefix lookups) implement `Collect`
for CLI and API use and omit the `RegisterMetric` line. As of
2026-08 the FIB family registers only its summary handlers, which
is the pattern to copy.

Label cardinality is enforced separately:
`pkg/telemetry/cardinality.go` rejects registration of labels that
are unbounded in a BNG (session and subscriber identifiers, MACs,
addresses, circuit IDs) unless the metric is marked streaming-only,
and caps series per metric.

## Coverage snapshot (2026-08)

Broad show coverage exists for OSPFv2, OSPFv3, BGP including the
L3VPN AFIs, LDP, zebra routes and interfaces, VPP FIB, and MPLS.
ISIS has neighbors only. EVPN and BFD have none (for EVPN see
design/frr-evpn-capability-audit.md). Counts drift; trust the
handler directories under `pkg/handlers/show/protocols/` over any
list written here.

## References

- Telemetry SDK: `osvbng/pkg/telemetry/` (`show.go`,
  `struct_register.go`, `registry.go`, `cardinality.go`)
- Upstream FRR command reference: https://docs.frrouting.org/
