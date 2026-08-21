# Todo

Working queue between sessions. Keep entries short, delete when done.

NEXT UP (in order):

1. Wire osvbng releases to osvbng-vpp artifacts: binapi generation in
   the pipeline (ADR 0002), osvbng consumes version-stamped bindings
   and debs from one build. The test rig consumes the same
   artifacts: the hand-committed plugin binaries in
   osvbng/test-infra/vpp-plugins/ go away, because they let the rig
   silently verify against a stale dataplane
   (design/verification.md). The suites now run in CI in three
   tiers, so what is left here is provenance, not plumbing: a
   runner still assembles an image around a hand-copied binary
   drop, and version-stamped debs are what make a green run mean
   the pair that shipped.
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
5. Plugin suite rework toward generic UP building blocks. cgnat
   runs on a shared session pool today, after per-worker pools
   plus handoff were tried and reverted (osvbng-vpp cgnat AUDIT.md
   Finding #8). Treat that as the current implementation, not a
   settled architecture: the revert handed off every packet rather
   than only RSS misses, and measured about one packet per second
   on QEMU where the cost it found was KVM waking a descheduled
   vCPU. Neither condition resembles bare metal at high core
   count, which is where a shared writable cache line per
   translated packet binds first.
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
      contention. Two more in the same function, fix together:
      internal/ipoe/dhcpv6.go spawns a goroutine per punted
      packet, which rule 12 bans outright, and it copies the
      packet and unwraps the relay before any subscriber-group
      lookup, so a packet for an unconfigured VLAN pair pays both
      before being dropped.
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
    the client never requested. Suite 33 still defers its v6 ping
    citing the RA-source reason that no longer applies: re-enable
    it or restate the deferral.
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
      assertions where the matrix is v4-only. Real-kernel v6
      exists only in suite 32; suite 18's Linux client is still
      v4-only and nothing asserts NUD recovery or LAN-side IA-PD
      forwarding.
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
17. CGNAT audit, 2026-08-20: a review of the plugin and the Go
    component, every finding re-checked against the code before
    landing here. Ranked; each item stands alone. The fixes belong
    in osvbng-vpp and osvbng; the decisions at the end are this
    repo's. The full record with evidence references and the
    seventeen defects found during verification is
    design/cgnat-audit-2026-08.md; the worker model it keeps
    pointing at is design/cgnat-worker-model.md.
    - Pool config can divide by zero: a subscriber-ratio wider
      than the port range truncates block size to 0 and
      ConfigurePool panics inside startup reconcile, which no
      recover covers. One plausible value, crash loop every boot.
      Reproduced against the real packages.
    - The fragment-rewrite pool has no capacity check where the
      session pool beside it has one, so a full fixed pool calls
      os_out_of_memory and takes VPP with it. Records are one per
      remote per subscriber against a 65536 ceiling, so ordinary
      browsing reaches it at a few hundred subscribers.
    - cgnat_pool_cascade_delete holds neither the session lock nor
      the worker barrier while pool_put-ing sessions and mappings
      and freeing per-mapping spinlocks; the other two delete
      paths take the barrier. Reachable from a config edit that
      drifts a pool and from reconcile's drop-orphan on every
      osvbngd start, both with workers forwarding.
    - Bypass installs a PRIORITY_HI drop entry that wins the FIB
      against the subscriber's own /32, and never enables
      cgnat-in2out, so the marker it installs can never be read.
      A bypass subscriber gets a blackhole and nothing else. No
      suite covers bypass.
    - A reused port block commits without programming anything:
      when GetOrAllocate returns isNew=false the component writes
      its own maps, makes no VPP call, and carries the previous
      session's sw_if_index, so the subscriber forwards
      untranslated. No race required, and it is why several
      teardown and restore paths blackhole.
    - Nothing reconciles mappings. The dump call exists with no
      caller, so a leaked mapping lives as long as the VPP
      process rather than until the next restart.
    - Subscriber-originated ICMP errors rewrite the inner
      src_port where the comment above states dst_port, and the
      out2in slowpath classifies an ICMP error from stale
      reassembly metadata instead of the header, which is why a
      subscriber traceroute gets no first hop.
    - The port budget is smaller than the config implies: one
      512-port block, a fresh port per 5-tuple and a hardcoded
      120s reuse cooldown put sustainable new flows near one per
      second, while max-sessions-per-subscriber defaults to 2000
      and can never bind. Measure on the rig before any fast-path
      work.
    - Knobs that change nothing, rule 4: the ALG bitmask (five
      ALGs on by default, no packet path reads it), the filtering
      enum, max-blocks-per-subscriber, exhaustion-behavior,
      ports-per-subscriber, the logging block, port_reuse_timeout.
    - Decisions, none of them made. What NAT behavior osvbng
      promises: it is symmetric today, and endpoint-independent
      mapping gates EIF, hairpinning and PCP alike. How portless
      protocols behave behind a shared outside IP, where ESP and
      GRE collide across subscribers today. Whether deterministic
      mode is built or refused, since it is advertised in config
      and unimplemented end to end. What CGN traceability is
      committed to, since the logging config is dead and
      allocation records are Debug. ADR 0006 already promises
      per-VRF allocator identity and leans on deterministic mode
      for log-once compliance; both need the code or the ADR to
      move.
18. Dead code audit, 2026-08-18: 143 functions flagged by deadcode
    at osvbng 4db1384, every claim re-checked against the code and
    this repo before landing. The full record, corrected action
    plan and the sign-off table are design/dead-code-audit-2026-08.md;
    all 17 items were decided there on 2026-08-21 and each carries
    where to start and how it is verified, with one issue per item
    (osvbng#488 to #502, osvbng-vpp#30, osvbng-context#27). Ranked;
    the first three are small.
    - PPP dispatcher panics on a frame whose declared Length is 0
      to 3: both guards pass and payload[4:length] slices out of
      range, no recover on the path, reachable from a punted
      subscriber frame. One condition.
    - HA CGNAT mapping restore never works: the receiver stores
      protobuf, the cgnat component decodes JSON, so every restore
      returns false. The decode helper the audit marks dead is the
      fix.
    - logger.Sync is never called, so the diode buffer's last poll
      interval is lost on every exit and "osvbng stopped" rarely
      reaches stdout.
    - Service-group state is never reversed at teardown: PPPoE
      parks its interface so the next subscriber inherits uRPF;
      IPoE deletes it but the urpf plugin's per-index cache skips
      re-enable on reuse. ACLs cannot leak yet (registry never
      populated). Fix in component teardown per ADR 0003, not in
      releaseSession.
    - L2TP CDN result codes are off by one against RFC 2661
      section 4.4.2, and the documented denylist triggers disagree
      with the code and the legacy spec.
    - One deletion PR for the 103 dead symbols with three
      corrections (keep checkpointToMapping, decide
      WithGARPCollector against HA_GARP_SPEC, also drop the
      operations.Dataplane interface), then a deadcode ratchet in
      CI so residue is removed in the PR that introduces it.
    - L2TP half-built surface the legacy spec mandated and the
      code still carries: outbound StopCCN and CDN (RFC 2661
      section 7.2.1 MUST), the v3 reject stub, the denylist feed,
      the LAC ppp-framing no-op.
    - Decisions: telemetry push path stays under ADR 0009 unless
      superseded; whether pkg/ is a supported out-of-tree SDK at
      all, since PLUGINS.md is 15 symbols stale and the
      cookiecutter has not compiled since June.
