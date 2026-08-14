# ADR 0007 - CPU partitioning config expresses intent, not core IDs

- Status: Accepted
- Date: 2026-08-14
- Deciders: Brandon

## Context

One host runs three competing workloads: VPP dataplane workers and
the VPP main thread, FRR routing daemons, and the osvbngd Go control
plane. Without partitioning, VPP core allocation was resolved from
runtime.NumCPU() and ignored the configured worker cores, so VPP
claimed the core intended for the control plane. Control plane
starvation under dataplane load is the failure mode to prevent.

Core allocation lived partly in shell (container entrypoint) and
partly in Go config generation, and the two could disagree. HA adds
a further constraint: peers may run on different hardware, so a
config that names resolved core IDs cannot be shared between them.

## Decision

**The dataplane config expresses intent (`main-core`, `workers`,
resolvable as auto), and each host resolves actual core IDs locally
at startup from its own topology (pkg/config/, ResolveCPULayout).**
Explicit core lists remain as an override for operators who need
precise control.

- Resolution detects the cores actually available to the process by
  reading the cgroup v2 cpuset and cpu.max limits (with v1
  fallbacks), so container CPU limits are respected rather than
  assumed.
- The resolved layout is exported once (env file consumed by the
  entrypoint) so shell and Go can never disagree; VPP startup config
  is generated from the same resolved values.
- Enforcement is per workload: the control plane pins itself via
  GOMAXPROCS sized to its resolved core set, and the container
  entrypoint applies taskset to the control-plane processes. VPP
  pins its own threads from the generated startup config.
- The auto layout always reserves a dedicated control-plane core:
  main thread on core 0, workers from core 1, control plane on core
  2. For a BNG workload, control plane starvation is worse than one
  lost worker.

## Consequences

- The same config file is valid on HA peers with different core
  counts and topologies; each host resolves its own layout.
- Container CPU limits are honoured; a pod with a 4-core cpuset
  resolves within those 4 cores instead of the host's total.
- The auto layout is conservative (one worker core); throughput
  deployments state worker cores explicitly.
- NUMA placement is not resolved in-process; host provisioning (the
  QEMU deploy scripting) is where NUMA alignment happens today.

## Alternatives considered

- Resolved core IDs in config (for example workers: "22-23") as the
  only mode: rejected, HA peers with different hardware cannot share
  the file; kept only as an override.
- taskset wrappers as the sole mechanism: rejected, the wrapper and
  Go config generation could disagree; resolution now happens once
  in Go and is exported to the entrypoint.
- Kernel boot parameter isolation (isolcpus): not required for the
  target deployments; cpuset limits plus per-process pinning achieve
  the separation without host boot configuration.
