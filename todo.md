# Todo

Working queue between sessions. Keep entries short, delete when done.

NEXT UP (in order):

1. osvbng_punt correctness and multi-worker fixes, as patches in
   osvbng-vpp (each is independently reviewable):
   - per-worker punt rings, buckets and counters (the shared SPSC
     ring is a publish race under multi-worker, not just cache-line
     contention); aggregation off the datapath
   - per-interface punt gating enforced in-node (port registration is
     global; today every frame on UDP 67/68 punts regardless)
   - egress node: TRACE_SUPPORTED flag plus vlib_trace_buffer (trace
     currently records nothing)
   - egress interrupt re-arm when the ring is non-empty after a
     capped batch (frames strand until the next inject otherwise)
   - UDP port registration moved inside the worker barrier (unsafe
     from the CLI path today)
   - DHCPv4 punt installs the all-ones receive route per FIB,
     refcounted, under an allocated FIB source (punt implies
     receivability)
   - versioned shm header plus a capability/version query in the .api
2. Wire osvbng releases to osvbng-vpp artifacts: binapi generation in
   the pipeline (ADR 0002), osvbng consumes version-stamped bindings
   and debs from one build.
3. Plugin imports: DONE. Nine plugins in osvbng-vpp with history
   (punt, pppoe, ipoe, l2gw, srg, tunnel, cgnat, qos_sched, l2tpv2);
   all compile and load together with zero node-resolution errors.
   The template repo is the skeleton/coding guide, not a build target
   (its content fed osvbng-vpp/CLAUDE.md); fib-control not imported
   (dead code). Remaining human actions: archive the ten original
   plugin repos on GitHub, and wire osvbng-vpp + osvbng-context as
   submodules of the main osvbng repo.
4. ARP and IPv6 ND move from Go into the dataplane: plugin-local
   responders (gateway replies gated on SRG active state), drop
   instead of punt for the rest. Removes the punt-storm surface and
   keeps answering across daemon restarts.
5. gNMI operational-state read path on the daemon.
6. Plugin suite rework toward generic UP building blocks. The old
   cgnat plan here (per-worker pools plus handoff) is dead: it was
   tried and reverted because handoff cost dominates at BNG packet
   rates (osvbng-vpp cgnat AUDIT.md Finding #8). cgnat stays on the
   shared session pool unless hot-worker benchmarks reopen it.
7. Multi-instance management design ADR: instances stay autonomous;
   a central controller as desired-state store and redundancy
   arbiter; identity crosses machines as role names only; bus and
   cache interfaces (pkg/events, pkg/cache) get external backends
   (redis) behind the existing surfaces first.
8. RFC-audit the DHCP/PPPoE/L2TP handlers against the corpus in
   references/: every behavioral branch cites its section; fix where
   the text disagrees.
9. Audit FRR's gRPC northbound on the pinned release: how much of
   the vtysh surface in design/routing-frr-bridge.md (BGP config,
   oper-state reads) plus YANG notifications for neighbor state
   changes is reachable. One channel for config, state and events,
   no per-protocol side channels (no BMP, no log following).
   Decides by ADR whether the northbound replaces vtysh; gaps are
   upstream-first contributions to FRR.
