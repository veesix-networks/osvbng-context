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
14. PPPoE IPv6 numbering model, maintainer direction fixed
    2026-08: PD-only WAN is the expected shape. IPv6CP gives both
    ends link-locals only (RFC 5072 negotiates an interface
    identifier, never a global address); the subscriber routes via
    the link-local next hop and sources from the delegated prefix,
    which is what bngblaster models (its source hard-gates IA_NA
    to IPoE access) and what suite 04 now asserts end to end.
    Serving IA_NA when a CPE requests one stays correct and
    unit-covered (TestPPPoEDHCPv6BindProgramsDataplane, RFC 8415:
    answer the IAs requested). Remaining work that follows from
    the direction: stop pre-allocating an IANA-pool address per
    PPPoE session at open (allocate lazily on the first IA_NA
    request, ResolveV6 already does this when the context carries
    no address), so PD-only subscribers stop burning pool
    addresses and the API stops showing an address with lease 0
    the client never requested.
15. IPv6 first-class audit, 2026-08-17: gaps that survived the
    session in which the ip6-ll kernel-ND poisoning, the dead
    session re-attach and the punt policer burst division were
    found and fixed. Ranked; each item stands alone.
    - VPP's native RA runs unsuppressed beside Go's SRG-gated
      emitter on every access sub-interface (ungated, physical
      MAC, answers on standby). It currently masks a second bug:
      Go's periodic RA only serves sessions after DHCPv6 binds
      (IPv6Bound), so suppressing native RA without fixing the
      unsolicited-RA path strands clients that wait rather than
      solicit. Fix together. ADR 0010 owns the direction.
    - L2TP LNS has no IPv6 service plane: IA_NA/PD are allocated
      and reported but no RA, ND or DHCPv6 ever reaches the
      subscriber (PPP 0x0057 returned unhandled). IPoE and PPPoE
      both have the full set; LNS has none.
    - PPPoE reactive RS/NS/DHCPv6 responders skip the SRG-active
      gate their IPoE twins and the periodic PPPoE emitter all
      apply, and bngSourceMAC falls back to the physical MAC on
      standby.
    - HA unsolicited-NA flood emits per GetIPv6Address, so
      PD-only subscribers (the expected PPPoE shape, item 14) get
      no v6 announcement on failover.
    - RADIUS accounting never sends Framed-IPv6-Address (168);
      the IA_NA address is invisible in accounting while v4 is
      not.
    - DHCPv6 local mode drops Confirm and Information-Request
      silently; relay mode forwards the latter, an internal
      asymmetry, and the RA advertises Other=1 which invites it.
    - Test coverage: no HA suite verifies v6 forwarding after
      failover, no PWHE/EVPN suite verifies v6 at all, and suite
      33's v6 skips cite osvbng-context#89, which resolves
      nowhere; the stated reason (global-source RAs) was fixed in
      May. Re-enable the deferred checks and add v6 forwarding
      assertions where the matrix is v4-only.
16. CI hardening from the 2026-08-17 bring-up, two items with
    recorded evidence.
    - PR runs and the nightly share the rig concurrency group, and
      twice a PR integration run entering or leaving that queue
      cancelled the RUNNING nightly (runs 32050228092 and
      32062082757), despite cancel-in-progress false. The mutex
      exists because every run builds and consumes the same
      veesixnetworks/osvbng:local image tag on the box. The fix
      that removes the coupling entirely: per-run image tags (the
      topologies take the tag from an env default) so runs stop
      sharing mutable state, then the rig group can go away.
      Interim discipline: no PR creation or merge while a sweep
      runs.
    - Test labs oversubscribe the box: the auto layout gives every
      container total-3 pinned VPP workers, five concurrent labs
      poll about five times more threads than cores, and the most
      timing-sensitive suites flake (52's establishment, sweep
      32056764011). Pinning all labs to the same two cores was
      tried and reverted (#466, #467): identical pins concentrate
      the polling on two host cores and broke four HA/pwhe suites.
      VPP cannot run unpinned workers, so right-sizing needs
      per-run core assignment from the CI layer (the runner knows
      its concurrency; topologies do not) or an unpinned worker
      mode in the dataplane. Until then the auto layout stands and
      suite 52 carries the residual sensitivity.
