# QoS aggregates

This note describes hierarchical aggregate shaping in the QoS
scheduler plugin: per-subscriber CAKE instances gated by an optional
S-VLAN aggregate, gated in turn by a per-port aggregate, and the
control plane that manages the aggregates. Read it before touching
the plugin's aggregate path or the qos-aggregates configuration.
Per-subscriber scheduling itself is covered in the QoS architecture
note.

## Scheduler and aggregate levels

Subscriber level (cake_sched_t). Real queues: tins feed DRR flows
with COBALT AQM and a virtual-time shaper. Owner-thread model:
enqueue claims the instance or hands off to the owning worker via
the handoff nodes. Per-subscriber overhead compensation produces the
adjusted length that all shaping math uses. cake-dequeue is an input
node, disabled by default and enabled per worker while instances
exist, so gate-closed packets retry on the next dispatch without
wake machinery.

Aggregate levels (cake_aggregate_t). An aggregate is a lockless
shaper with no queues of its own, existing at two levels: port
(keyed by physical or bond sw_if_index) and S-VLAN (a child of a
port aggregate, matching a set of outer VLAN IDs). Aggregates have
no thread pinning; correctness comes from atomics:

- The dequeue gate is a CAS loop on the aggregate's virtual shaper
  time, with an idle-credit clamp bounding burst after quiet
  periods. If the shaper time is ahead of now the gate is closed
  and the packet retries on a later dispatch.
- Buffer admission charges an atomic usage counter at enqueue,
  verify-after-add with unwind; a packet that would exceed the
  limit is dropped and counted as backpressure. Discharge happens
  on dequeue and every drop path.
- The shared atomics live on separate cache lines (shaper time,
  buffer usage, child DRR state), with stats in per-thread slots,
  so workers do not bounce a line between them.

S-VLAN aggregates are resolved per port through a 4096-entry map
hung off the port aggregate (about 16 KB per port, O(1) lookup).

## Auto-attach

There is no per-session bind API. When a subscriber scheduler is
enabled, the plugin walks sup_sw_if_index up the interface hierarchy
to the physical parent, remembering the outermost single-tag VLAN ID
seen on the way. The port aggregate is found by the parent
sw_if_index; the S-VLAN map then resolves the child aggregate, and
the scheduler caches the index of its immediate parent. A miss
attaches to the port aggregate alone. The control plane never issues
per-session topology calls; it only manages aggregates, and config
stays order-independent from the session's point of view.

## The two-gate dequeue and the refund problem

The gate charges by advancing virtual time inside a CAS, so a charge
is a side effect. With a child and a parent gate in series, passing
the first and failing the second would leave a phantom charge. The
dequeue path therefore runs: own gate, then a DRR reservation
against the parent, then the parent's gate; on a DRR block or a
closed parent gate it unwinds, refunding the charged time with an
atomic subtract, reversing the shaped counters, and returning the
DRR reservation. A per-thread parent_blocked counter records how
often the parent was the constraint. The refund is safe under the
virtual-time scheme: a concurrent worker that observed the inflated
time waits marginally longer for one packet, a bounded,
self-correcting error.

Both levels are charged the subscriber's overhead-adjusted length;
aggregates have no overhead fields of their own.

## Fairness

Children share a parent through weighted DRR: each child (a
subscriber scheduler under an S-VLAN aggregate, or an S-VLAN
aggregate under its port) draws parent credit via the shared DRR
state with its configured weight, so a heavy child cannot capture
the parent rate. Congestion at an aggregate backs traffic into the
per-subscriber CAKE queues, where tins and COBALT protect priority
classes.

## API and compatibility

The aggregate API is versioned rather than mutated: the original
port-only create/delete messages remain for older control planes,
and the v2 messages (create, delete, update, dump) carry the level,
parent, S-VLAN set, and weight. A capabilities message reports
whether the S-VLAN tier and weighted DRR are present; the control
plane probes it once and falls back to the v1 messages against an
older plugin (see the QoS architecture note).

## Control plane

Configuration is a qos-aggregates map: name to rate, weight, and
optional svlans (values or ranges; absence means a port-level
aggregate on the named interface). Validation covers VLAN range
parsing and aggregate consistency; the sum of child rates may exceed
the parent, which is deliberate oversubscription. The southbound
exposes ApplyAggregate, UpdateAggregate, RemoveAggregate, and
DumpAggregates (pkg/southbound/vpp/), wired through the conf
handlers, and the aggregate level is derived from the presence of
the svlans list.
