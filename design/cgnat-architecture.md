# CGNAT architecture

This note describes the CGNAT split between the osvbng control
plane (`internal/cgnat/`) and the dataplane plugin
(`osvbng-vpp/plugins/osvbng_cgnat/`), and where to read further.
The dataplane's own documentation is authoritative for the
datapath: the plugin's SUMMARY.md covers nodes, state ownership,
binapi and error counters, and its AUDIT.md records the findings
and reversals that shaped it. This note covers the control-plane
side and the seam. The allocation model itself is ADR 0006.

File references are against osvbng and osvbng-vpp as of 2026-08.

## Split of responsibility

The plugin owns translation: session tables, port blocks within a
subscriber's mapping, expiry, counters. The control plane owns
policy and lifecycle: which subscriber gets which pool, when a
mapping is created and torn down, persistence, and HA. The
contract between them is the binapi in `osvbng_cgnat.api`, chiefly
`add_del_subscriber_mapping` carrying (inside_ip, fib) to
(outside_ip, port_block_start, port_block_end). Per rule 10 the
plugin knows nothing about osvbng; any control plane that speaks
the .api gets the same behavior.

What ships today is a single shared session pool that any worker
translates against. A per-worker pool with frame-queue handoff was
tried and reverted (plugin AUDIT.md, Finding #8), but that
experiment handed off every packet and was measured at about one
packet per second on QEMU, where the cost it found was KVM waking
a descheduled vCPU. It did not price the pattern the plugin rules
actually prescribe, and it says little about bare metal at high
core count. Treat the shared pool as the current implementation,
not as a settled architecture: the question and what would close
it are in design/cgnat-worker-model.md.

## Control-plane component

`internal/cgnat/` is event-driven off the session lifecycle: it
subscribes to session lifecycle, programmed and restored topics
and never sits on the packet path. On activate,
`classifySession` picks one of three treatments from the service
group's CGNAT policy (`Policy` names a pool, `Bypass` skips NAT):

- Bypass: the subscriber's inside address is installed as a
  bypass prefix so traffic routes around translation. Static-IP
  subscribers use this.
- PBA: a port-block mapping is allocated from the named pool
  (`PoolManager` in pool.go), programmed south, and committed.
- Deterministic: mapping is computed, not allocated; the
  dataplane can derive it from config alone.

Supporting managers: `BypassManager`, `BlacklistManager`
(per-pool exclusion of outside addresses), and a `ReverseIndex`
for outside-to-subscriber lookups. Config-apply validates overlap
(outside pools vs subscriber space, local addresses) and refuses
bad pools at startup rather than at first session.

## Persistence, restart, HA

Mappings persist in OpDB under the `cgnat_mappings` namespace, so
a subscriber keeps its outside address and port block across
daemon restarts (deterministic log-once compliance depends on
this; see ADR 0006). On restart, `RecoverDataplane` plus
reconcile.go re-derive intended state and reconcile it against
what the plugin actually holds, rather than blindly re-adding.

During restore, incoming lifecycle events are queued rather than
raced: the queue is bounded (4096) and overflow marks the
component degraded instead of silently dropping events. HA-synced
mappings from a peer are restored through the same activation
path (`tryRestoreSyncedMapping`), so a promoted standby reuses
the peer's allocation instead of minting a new one.

## Where to read further

- Dataplane detail: `osvbng-vpp/plugins/osvbng_cgnat/SUMMARY.md`
  (datapath, node table, state ownership, binapi, counters) and
  AUDIT.md (decision history, including the lessons-learned list:
  reass metadata clobbering, next-node dedup, checksum polarity,
  ICMP inner-rewrite).
- Allocation model and modes: decisions/0006-cgnat-port-block-allocation.md.
- RFC grounding: RFC 6888 (CGN requirements), RFC 6598 (shared
  address space), RFC 6056 (port reuse cooldown), RFC 7422
  (deterministic logging), all in references/.
