# Todo

Working queue between sessions. Keep entries short, delete when done.

NEXT UP (in order):

1. Wire osvbng releases to osvbng-vpp artifacts: binapi generation in
   the pipeline (ADR 0002), osvbng consumes version-stamped bindings
   and debs from one build. The test rig consumes the same
   artifacts: the hand-committed plugin binaries in
   osvbng/test-infra/vpp-plugins/ go away, because they let the rig
   silently verify against a stale dataplane
   (design/verification.md). Same artifacts unblock running the
   integration suites in CI at all: the workflows exist but were
   never used because the runner built the dataplane from scratch
   every time; with prebuilt debs a runner just assembles the image.
2. Plugin imports: DONE. Nine plugins in osvbng-vpp with history
   (punt, pppoe, ipoe, l2gw, srg, tunnel, cgnat, qos_sched, l2tpv2);
   all compile and load together with zero node-resolution errors.
   The template repo is the skeleton/coding guide, not a build target
   (its content fed osvbng-vpp/CLAUDE.md); fib-control not imported
   (dead code). Remaining human actions: archive the ten original
   plugin repos on GitHub, and wire osvbng-vpp + osvbng-context as
   submodules of the main osvbng repo.
3. ARP and IPv6 ND move from Go into the dataplane: plugin-local
   responders (gateway replies gated on SRG active state), drop
   instead of punt for the rest. Removes the punt-storm surface and
   keeps answering across daemon restarts.
4. gNMI operational-state read path on the daemon.
5. Plugin suite rework toward generic UP building blocks. The old
   cgnat plan here (per-worker pools plus handoff) is dead: it was
   tried and reverted because handoff cost dominates at BNG packet
   rates (osvbng-vpp cgnat AUDIT.md Finding #8). cgnat stays on the
   shared session pool unless hot-worker benchmarks reopen it.
6. Multi-instance management design ADR: instances stay autonomous;
   a central controller as desired-state store and redundancy
   arbiter; identity crosses machines as role names only; bus and
   cache interfaces (pkg/events, pkg/cache) get external backends
   (redis) behind the existing surfaces first.
7. RFC-audit the DHCP/PPPoE/L2TP handlers against the corpus in
   references/: every behavioral branch cites its section; fix where
   the text disagrees.
8. Audit FRR's gRPC northbound on the pinned release: how much of
   the vtysh surface in design/routing-frr-bridge.md (BGP config,
   oper-state reads) plus YANG notifications for neighbor state
   changes is reachable. One channel for config, state and events,
   no per-protocol side channels (no BMP, no log following).
   Decides by ADR whether the northbound replaces vtysh; gaps are
   upstream-first contributions to FRR.
9. LCP echo offload into the osvbng_pppoe plugin: answer peer
   Echo-Requests and generate ours in-node, magic numbers
   programmed at session setup, every non-echo LCP frame still
   punts, an event fires only when the miss threshold trips.
   Punt-path headroom at scale, and sessions survive daemon
   restarts, same direction as the ARP and ND move into the
   dataplane. Does not apply at the LAC. RFC 1661 section 5.8
   open while writing.
10. Mine the legacy context repo's DECISIONS files lazily: when a
    session touches an area, it checks the legacy decisions for
    that area and promotes anything still binding into an ADR
    here. Six became ADRs 0003 to 0008 in the initial migration
    and the telemetry registry became ADR 0009; about 50 remain
    (RADIUS and CoA, subscriber runtime mutation, DHCP relay and
    LDRA, API pagination, egress batching, others). The legacy
    repo stays available until mined.
11. Hot-path debt recorded in design/performance-and-logging.md:
    - event bus delivery without a goroutine per event per
      subscriber (pkg/events/local), bounded per-subscriber
      worker delivery instead
    - DHCPv6 packet pipeline parses each packet three times
      through gopacket; single-parse rework, latency not
      contention
12. NUMA-aware CPU placement on multi-socket hosts: resolution is
    topology-blind today, NUMA layouts are operator-expressed
    through explicit core sets (dataplane.cp-cores, workers). An
    intent-level answer (workers near their NICs, control-plane
    cores spread or pinned per socket) follows ADR 0007's
    resolve-locally principle and needs its own design pass.
13. Directions distilled from the CUPS design study, carried here
    by substance:
    - reconciled desired state at the southbound seam: HA
      restore, interface-deletion cleanup and cross-peer ifindex
      bugs were all call-ordering symptoms; move toward the
      control plane computing declarative per-session dataplane
      state that the southbound reconciles, rather than
      imperative call sequences
    - services attach to circuits, not sessions: CGNAT and l2gw
      keyed on attachment circuits and prefixes so standalone
      deployments carry no BNG session machinery
    - admission serialized per subscriber key, so one
      misbehaving subscriber's churn cannot reorder or starve
      another's session setup
    - punt-storm dampening per subscriber key ahead of the
      protocol components, complementing the in-node punt
      policer's aggregate cap
    - capability negotiation grows teeth: the plugin
      capability/version query (rule on plugins) becomes
      something the control plane enforces, refusing or
      degrading config the dataplane cannot place
14. PPPoE IA_NA is allocated but never delivered: the control
    plane takes an address from the IANA pool at session open and
    shows it in the API, but the DHCPv6 provider serves only
    IA_PD and DNS on PPPoE, so the client never receives the
    address and no /128 is programmed toward the session. Decide
    the model with RFC 8415 open (serve IA_NA from the pool in
    the in-band exchange, or drop the administrative allocation
    and commit to SLAAC), then make the API stop reporting an
    address the subscriber does not hold. Found while verifying
    the dual-stack dataplane bindings; suite 04's FIB assertion
    deliberately covers the delegated /56 only until this is
    decided.
