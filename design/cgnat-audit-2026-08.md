# CGNAT audit, August 2026

A security and performance review of the CGNAT plugin
(`osvbng-vpp/plugins/osvbng_cgnat/`) and its Go control plane
(`osvbng/internal/cgnat/`, `pkg/config/cgnat/`, `pkg/ha/`) was
written on 2026-08-20 by static analysis. Every finding was then
re-checked against osvbng main at b1eb14c3 with the vpp submodule at
fb3580a4, where the plugin tree is byte-identical to the audited
one. Of 37 lettered findings, 19 hold as written, 10 hold with a
corrected mechanism or severity, 8 split into sub-claims of which
six are refuted, and none falls entirely. Verification found 17
defects the audit did not reach; the worst is not in the audit.

This note is the durable record: what is wrong, where, and in what
order to fix it. Line references are to the trees above and will
drift; search by symbol when they do. Everything here is desk work
against code and tests. Nothing was run on the rig except the
config cases marked as executed, and the items under "needs the
rig" stay open until it is.

Each fix belongs in osvbng-vpp or osvbng. The decisions the audit
surfaces belong here and are listed last.

## Fix order

Ranked by what breaks, divided by fix size. The first six are small
and independent.

1. Validate CGNAT pool config before it divides by zero. Executed:
   `subscriber-ratio: 65535` on the default range, or a 1024-port
   range with ratio 2000, gives block size 0 and `ConfigurePool`
   panics inside startup reconcile with no `recover()` on the start
   path. One plausible value, crash loop on every boot.
2. Bound the fragment-rewrite pool. `cgnat_frag_rewrite_acquire`
   calls `pool_get_zero` on a fixed 65536-entry pool with no
   capacity check; VPP aborts the process when a fixed pool is
   full. Records are one per remote per subscriber, so ordinary
   browsing reaches it at a few hundred subscribers.
3. Take the worker barrier in `cgnat_pool_cascade_delete`. It is
   the only one of three delete paths holding neither the session
   lock nor the barrier while it frees sessions, mappings and
   spinlocks under live traffic. Reachable from a config edit that
   drifts a pool and from reconcile's drop-orphan at every osvbngd
   start.
4. Read the ICMP type from the header in the out2in slowpath, and
   restore the `ip.reass.ip_proto` fail-closed check there. This
   closes the first-hop traceroute report.
5. Fix the inner field in the in2out ICMP-error rewrite:
   `->src_port` to `->dst_port` at `osvbng_cgnat_in2out.c:469`.
6. Populate the PPPoE Released payload, and make the reused-block
   path program the dataplane. Without the second half the leak
   stops but the next subscriber on that address forwards
   untranslated.
7. Decide what bypass is, then rebuild it. Today it installs a drop
   route that wins the FIB and enables nothing.
8. Measure the port budget on the rig before any fast-path work.
9. Sweep the dead knobs and refuse what is not implemented.
10. Then the structural set: per-inside-IP serialisation, a
    mapping-level reconcile, the worker model
    (design/cgnat-worker-model.md), fragment keying, the portless-
    protocol decision, endpoint-independent mapping, the fast-path
    diet.

## Found during verification, not in the audit

**The fragment-rewrite pool can abort VPP.** `pool_get_zero` at
`osvbng_cgnat_session.c:105` has no capacity check, unlike the
session pool at `:326`. `CGNAT_MAX_FRAG_REWRITES` is 65536
(`osvbng_cgnat.h:418`); VPP's `pool_get` on a full fixed pool calls
`os_out_of_memory()`. Remotely triggerable by normal traffic.
Critical.

**A reused port block commits without programming anything.** When
`GetOrAllocate` returns `isNew=false`, `internal/cgnat/component.go:
526-530` commits the mapping, makes no VPP call, and carries the
previous session's `sw_if_index`, so `cgnat-in2out` is never enabled
on the new interface. This is the real mechanism behind B1's
second-order damage, B2's same-address collision, and parts of D1
and D6, which the audit attributes to event ordering. No race
required. Critical.

**Nothing reconciles mappings.** `CGNATDumpSubscriberMappings` is
declared and implemented (`pkg/southbound/vpp/cgnat.go:666-699`)
with no production caller. `reconcile.go` converges pools, prefixes
and outside addresses only, so every leaked mapping from B1, D2, D3
and D6 lives for the life of the VPP process rather than until the
next restart. High, and the cheapest safety net for the whole
class.

**The port budget is about one new flow per second per
subscriber.** One 512-port block, a fresh port per 5-tuple, and a
reuse cooldown hardcoded to 120s (`osvbng_cgnat_session.c:257`)
give a sustainable rate near `512 / (lifetime + 120)`. A page load
opens 50 to 100 connections. Drops are silent. The defaults are
incoherent: `max-blocks-per-subscriber` defaults to 4 and
`max-sessions-per-subscriber` to 2000, sized for four blocks that
can never be allocated, so `PORT_EXHAUSTED` fires about 4x before
`SESSION_LIMIT` and the session cap tunes nothing. High; reaches
every subscriber.

**Bypass never enables the feature it marks.** The bypass path
never calls `CGNATEnableOnSession`, so `cgnat_bypass_check` can
never fire; with B8 the whole effect of `cgnat.bypass: true` is a
blackhole route on the subscriber's /32. `handleBypass` also
hardcodes VRF 0 (`component.go:649`) while the check reads the RX
interface's FIB. No test mentions bypass. High.

**`cm->mappings` is a growable pool.** `sessions` and
`frag_rewrite_pool` are `pool_init_fixed`; `mappings` is not, and
workers dereference mappings on every packet. Safe today only
because every mapping add holds the barrier. Remove that barrier
for churn reasons, which C5 invites, and it becomes a live use-
after-free. Make the pool fixed first.

**`setupOutsideInterfaces` leaves pools half-registered at
random.** It returns on the first error and `Start` downgrades that
to a `Warn` (`component.go:137-139`). Because it iterates a Go map,
one bad name or one `INSTANCE_IN_USE` on a daemon restart against a
live VPP leaves an arbitrary subset of pools with outside prefixes
installed but no registered outside interface. That is the state C7
describes, reached from a typo.

**Deterministic and bypass sessions never get in2out disabled.**
Release falls through to `CGNATEnableOnSession(0, ...)` whenever
`sessionPoolMap` has no entry; pool id 0 cannot exist (`reconcile.
go:33-41` remaps a zero hash to 1), so the plugin returns
`NO_SUCH_ENTRY` and the feature and the sv-reass refcount leak onto
recycled interfaces.

**`classifySession` ignores the pool's mode for service groups.**
A service group pointing at a deterministic pool takes the PBA path
and sends a mapping, which the plugin silently overrides with the
det derivation, so the Go allocator's record does not match what
VPP installed and PBA logging resolves the wrong subscriber.
`GetMode()` has no callers in validation.

**The reverse index is not what resolves outside identity after
a restart.** `tryRestoreSyncedMapping` scans the whole
`ha_synced_cgnat` namespace on every PBA activation and never
early-exits: quadratic at mass reactivation.

**Smaller.** `SetOutsideVRF` refuses on the global session count,
so pool A's sessions block a re-bind of pool B. `pkts_slowpath` is
computed and discarded in both fast nodes, so no counter shows the
slow-path rate. The pool dump reports `alg_bitmask = 0x1F` while
every session dump reports `alg_flags = 0`. `COOLDOWN` and
`HAIRPINNED` errors are defined and never set. The plugin's
AUDIT.md refers throughout to a handoff file that no longer exists.

## A. Cross-subscriber isolation

**A1, fragment aux table misdelivers across subscribers. Holds,
and is broader than written.** The acquire looks up only the i2o
key and then installs the o2i key `(remote, outside_ip, proto,
outside_fib)` with an overwriting add (`osvbng_cgnat_session.c:
143-155`). Two subscribers on one outside IP to one remote collide,
and the consumer rewrites the fragment to whichever won
(`osvbng_cgnat_out2in.c:331-346`). Every session create acquires a
record, not only fragmented flows, so on a busy outside IP
misdelivery is the default outcome. Once the shared key is deleted
it is never reinstalled, so the survivor drops fragments for the
life of its record. Two sub-claims fall: there are no dangling
freed-record keys, and the proposed sv-reass fix is unavailable
because `ip.flow_hash` overwrites the reass port fields after
`ip4-lookup`. Interim mitigation: drop non-first fragments out2in
instead of guessing. Critical.

**A2, unknown-protocol sessions collide. Holds.** Key is
`(src, dst, 0, 0, proto, fib)`, identical for every subscriber on
one outside IP to one concentrator; the second create overwrites
(`:429-437`) and the first delete removes the shared key
(`:472-480`). The header comment at `osvbng_cgnat.h:729-734` cites
RFC 4787, which scopes UDP only; nothing cited permits this. The
blackhole is permanent while the tunnel is up because outbound
traffic keeps refreshing the session. Needs a decision, below.
High.

**A3, port allocator has no in-use tracking. Holds, misfiled.**
The only skip is the 120s cooldown on a port freed earlier
(`:254-259`); a live port has timestamp 0 and is handed out again
at the 513th concurrent flow. Blocks are disjoint per subscriber,
so this is intra-subscriber corruption, not an isolation breach.
It also makes `PORT_EXHAUSTED` effectively unreachable, so the
block silently overflows and the PBA record stops bounding what
the subscriber used. Fix is a per-mapping in-use bitmap. Medium-
high.

**A4, keys truncate fib_index to 16 bits. Holds.** Consistent
across every call site, so collision only above 65536 FIB tables.
Low; add the guard so the ceiling is loud.

## B. Broken subscriber pathways

**B1, PPPoE teardown never releases the mapping. Holds, with
corrections.** `terminate()` publishes Released without
`IPv4Address`, `VRF` or `ServiceGroup` (`internal/pppoe/session.go`)
and the CGNAT handler early-returns on nil IP (`component.go:691`).
PADT, LCP dead peer and admin clear all leak; only the post-VPP-
failure path publishes a full event. IPoE populates two of the
three, not `ServiceGroup`. The inheritance of the outside identity
is not caused by registry ordering but by the reused-block path
above. "Leak forever" is "leak until restart". Critical.

**B2, inside VRF hardcoded to 0. Holds.** Every cited line passes
VRF 0 while `sess.VRF` is live in the same function, and the plugin
falls back to fib 0 on a table miss at three sites. ADR 0006
promises `(inside_vrf_id, inside_ip)` identity. The `ENTRY_NEEDS_
REFRESH` sub-claim is harmless and dropped. The PPPoE VRF ceiling
(`osvbng_pppoe.c:294-302`, a fib index compared to a next-node
count) is real, independent, and already blocks multi-VRF PPPoE.
Critical for multi-VRF, no effect single-VRF.

**B3, deterministic mode never programs a mapping. Holds.** The Go
det path calls only `CGNATEnableOnSession`; the derivation lives
only in the mapping add, which nothing calls per det subscriber;
the datapath has no derivation on miss. The suites the audit hoped
would refute this, 09 and 11, are in `tests/skip-suites.txt` with
no reason recorded, so the "NAT traffic flows" assertion never
runs. The SIGFPE is real but at a different divide
(`osvbng_cgnat.h:668`) that osvbng cannot reach; the forward and
reverse port maths are exact inverses and that sub-claim is
refuted; `cgnat_det_reverse` has no callers. Interim: refuse
`mode: deterministic` at validation. Critical for det pools.

**B4, PMTUD through the NAT. Mechanism holds, trigger does not.**
A locally generated ICMP error traverses no CGNAT node and quotes
the inside address. But nothing subtracts the 8-byte PPPoE encap
from `max_l3_packet_bytes`, so it is 1500 and a 1500-byte DF packet
passes at the default MTU pairing; the path is reachable only with
a reduced MRU. Not the cause of the traceroute report. Medium
shipped, High for reduced-MRU and L2TP.

**B5, translated packets skip the arc, MSS clamp unpinned. Holds.**
The translate path falls through to `ip4-lookup` rather than
`vnet_feature_next` (`osvbng_cgnat_in2out.c:303-305, 617-619`), and
the constraint block names neither `tcp-mss-clamping-ip4-in` nor
anything that chains to it. The order is a solver tie broken by
load order. Two lines. High if misordered; verify with
`show ip feature`.

**B6, hairpinning drops with a misleading counter. Holds, and the
plugin's SUMMARY.md is wrong.** The exclusive DPO catches the
packet; it does not escape to FIB. In a single-table deployment the
operative cause is missing inbound origination; the RX-derived FIB
is a second bug that bites in VRF-lite and L3VPN. The `HAIRPINNED`
counter is never incremented. Medium-high.

**B7, inner rewrite hits `src_port` not `dst_port`. Holds exactly.**
`osvbng_cgnat_in2out.c:467-470` against its own comment at
`:400-405`; the out2in mirror at `osvbng_cgnat_out2in.c:428-431` is
correct for its direction. Adjacent: the inner UDP checksum is not
updated in either direction, and in2out tests the ICMP-error branch
before the fragment branch where out2in orders them correctly.
High, one token.

**B8, bypass entries are PRIORITY_HI drop routes. Holds, raised to
Critical, settled from the VPP FIB source.** `cgnat-bypass`,
`osvbng-pppoe` and `osvbng-ipoe` are all `FIB_SOURCE_PRIORITY_HI`,
so `fib_source_cmp` returns EQUAL and `fib_entry_src_action_
reactivate` installs the bypass source's drop path list as the
forwarding. PPPoE adds the /32 first and bypass second, so the
ordering that loses is the one the control plane produces. A debug
VPP asserts here; a release build installs the drop. The second
sub-claim, policing before the bypass check, is unreachable today
because bypass never enables the feature.

**B9, unordered async teardown on a recycled sw_if_index. Holds.**
The interface delete and the mapping delete are independent async
calls, outside the chained-from-callback ordering ADR 0008
guarantees, across a 64-worker pool. PPPoE parks hidden interfaces
on a LIFO free list, so the just-freed index is the first handed
out. High.

## C. Dataplane concurrency

The locking that exists is scoped to one function. `session_pool_
lock` is taken only in `cgnat_session_create` (`osvbng_cgnat_
session.c:325-450`); `cgnat_session_delete` does not take it, and
of its three callers two hold the barrier and one holds nothing.

**C1, single-worker asserts over a multi-worker design. Holds,
worse than stated.** All four node functions carry
`ASSERT (vm->thread_index == 0)` citing a reverted invariant. Any
box with two or more cores runs workers, so the nodes never execute
on thread 0: the assert protects nothing in release and aborts
debug almost anywhere. The node comment claiming CI catches this is
false in both directions; the rig runs multi-worker on release
debs. Critical as an architectural-clarity defect.

**C2, cascade delete with no barrier. Holds.** `cgnat_pool_cascade_
delete` (`osvbng_cgnat.c:50-85`) frees sessions, mappings and
spinlocks from the main thread under neither lock nor barrier;
mapping delete at `:405` and the expiry walk take the barrier for
the same mutations. Reachable from the southbound's del-then-re-add
on pool drift and from reconcile drop-orphan on every osvbngd
start. A lost update on the pool free list hands one slot to two
sessions, which is a cross-subscriber leak. Critical, two lines.

**C3, slow-path double create. Holds, severity down.** The re-
lookup is outside the lock, so two workers can both miss and both
create; the second in2out add overwrites and the walker visits only
the in2out table, so the loser's slot and `session_count` leak
permanently. Needs the first two packets of one flow on two workers
at once, which symmetric RSS rarely produces. Medium.

**C4, unlocked per-packet writes. Holds, mechanism corrected.** A
lost bit in `tcp_flags |=` needs same-direction writers; the i2o-
versus-o2i race that bites is the CLOSING transition zeroing both
bytes, after which a late `|=` resurrects flags and the next
SYN|ACK check promotes a closed flow back to the 2-hour timeout.
SUMMARY.md documents a brief mis-compute; the code produces a
lasting one. The cache-line ping-pong needs no race and is the
throughput ceiling of the shared-pool design. Medium.

**C5, barrier per mapping add and delete. Holds.** Add and delete
both sync (`osvbng_cgnat.c:326, 405`), the delete holding it across
up to 2000 session deletes per subscriber, and the bulk handler
loops N entries through the full function with no chunking from
the Go side: 10k barriers in one handler on a 10k-subscriber
restore. High.

**C6, expiry walk under the barrier. Holds, magnitude raised.** One
sync, a full-table `foreach`, the delete loop, one release
(`osvbng_cgnat_session.c:536-565`) every 10s. The walk is two cache-
miss streams, about 24MB of bucket pages plus a random miss per
session into a 100MB pool on 4k pages. Plausibly 50 to 150ms of
all-worker stall at the 512k ceiling; needs `show runtime` to
price. High.

**C7, out2in trusts metadata it cannot validate. Holds, raised to
High.** This is the cause of the traceroute report: `ip4_ttl_and_
checksum_check` resets `VLIB_TX` where the MTU check does not, so a
self-generated Time Exceeded lands back in the inside FIB, reaches
`cgnat-out2in` via the DPO, and is misclassified at `osvbng_cgnat_
out2in.c:355-358` from the stale `reass.icmp_type_or_tcp_flags`
field. The comment claiming `flow_hash` aliases `reass.ip_proto` is
wrong; only the L4 port fields are aliased, so the fail-closed
check is available. Two lines.

## D. Control-plane races

**D1, no per-subscriber event ordering. Holds, access type
corrected.** Handlers run one goroutine each (`pkg/events/local/
bus.go:112-114`), activate and release arrive on different topics,
and release is keyed by inside IP. But PPPoE's release never runs
(B1), so the live path is IPoE with a sticky DHCP lease.
`GetOrAllocate` also returns the dead session's `SwIfIndex`.
Critical.

**D2, in-flight windows. Three of four hold.** A release during the
async add window early-exits and the callback then commits for a
dead session, which nothing reaps. The 64-worker pool has no per-
key serialisation; the reorder hazard is the same-inside-IP flap,
not another subscriber's block, because deletes are keyed on inside
IP. A failed delete frees the block locally anyway. `drainQueue`
flips before replaying; boot window only. High.

**D3, storms. Holds in part.** Bus drop past 10000 with a per-event
warn, goroutine fan-out against rule 12, an unsampled error per
failed allocation. The 4096 CGNAT queue exists only during the
startup restore window. A dropped Released event leaks a VPP
mapping permanently. High at scale.

**D4, HA CGNAT sync. Holds, sharpened.** The backlog field is typed
for session requests and cannot hold a CGNAT one; the session
sender drops identically but pushed to the backlog first, so its
drop is recoverable and CGNAT's is not. No gap detection. Bulk sync
ignores `SrgNames` and never sets `SrgName` in the response, so it
writes a sequence key nothing reads. A post-heal pull exists; what
is missing is conflict detection, since `RestoreMappingIfAbsent`
ORs the allocator bit without checking the owner. High where HA and
PBA meet.

**D5, config validation. All seven hold; four executed.** The
divide-by-zero is item 1 of the fix order. `end < start` in a port
range underflows to four billion usable ports and allocates 256MiB
of bitmap per /24 with no error. No pool-versus-pool overlap check,
and `FindPoolForIP` iterates a map so overlapping prefixes select
nondeterministically. Enum typos select PBA. `expandCIDR` includes
network and broadcast and expands /0 to nothing. Exclusions match
by exact string. Bad inside prefixes are skipped silently to
`classNone`.

**D6, reconcile and restore. All five hold, severity raised.**
`populateLocalState` discards `ConfigurePool` errors while still
registering the pool id. `on_divergence: fail` applies then fails,
deliberately and test-locked, so it is a naming complaint.
`RecoverDataplane` runs against a snapshot with live handlers
active and re-adds mappings with no local owner and no opdb key.
The preserved-for-retry path re-adds blocks without a
`sessionPoolMap` entry and nothing retries; when that session
activates, the reused-block path marks it live without programming
VPP, a silent blackhole on a plain restart. The earlier triage
verdict that only rig coverage remained is withdrawn.

## E. Fast path

**E1** holds: `cgnat_is_local_receive` runs a full forwarding
lookup on every in2out packet when a session hit already implies it
passed at create. A translated packet looks up in the outside FIB,
so the argument is create-time checking, not duplicated work. 40 to
80 cycles typical. **E2** holds: one bypass anywhere lifts the early-
out for every packet on every subscriber interface; the LPM
terminates on the first probe because per-session /32s exist, so 60
to 150 cycles, not 400. **E3** holds: the mapping and pool
dereferences on the hit path are denormalised into the session, as
out2in already proves. **E4** holds: no prefetch or dual loop in any
of the four nodes while five sibling plugins have it; 20 to 40
percent is the realistic retrofit. **E5** holds on the code side and
the RSS premise needs the rig; the cited line was the DHCPv6 punt
branch rather than the decap exit, and the asymmetry, not the
concentration, is what puts both directions of a session on
different workers. E1 to E3 touch the same lines and are one
change; E4 is separate and needs `make vpp-perf` numbers.

## F. Residential fitness

**F1** holds structurally: four bihash tables and none keyed on
`(inside IP, inside port)`, so mapping reuse has nowhere to live;
the filtering enum is stored, echoed and never read; unmatched
inbound always drops. **F2** holds: `GetALGBitmask` returns 0x1F when
unset and no packet path reads `alg_flags`. **F3** holds: no PCP,
UPnP, static mapping message or DMZ anywhere. **F4** holds and is
the port-budget item above. **F5** holds and is regulatory: the
`logging:` block has no consumer, allocation records are Debug, and
the data an operator would be served a notice for may not exist.
**F6** holds: ICMP errors quoting ESP, GRE or 6in4 are dropped in
both directions although the portless session they belong to is in
the table, and the control plane always sends a 7200s TCP
established timeout where RFC 5382 requires 7440.

## G. Dead knobs

Every row holds: `port_reuse_timeout` (allocator hardcodes 120s),
`alg_bitmask`, `filtering`, `max_blocks_per_sub`, `exhaustion-
behavior`, `ports-per-subscriber` (set in two shipped rig configs),
`LoggingConfig`, `on_divergence: fail`. One correction:
`address_pooling` has a Go consumer at `pool.go:137, 477`, which is
unreachable for the same reason multi-block is. Rule 4 applies to
all of them: implement, or reject at validation until implemented.

## Needs the rig

- The arc order for B5: `vppctl show ip feature` on a live image.
- The expiry-walk cost for C6: `show runtime` on the `cgnat-expire-
  process` node at high occupancy.
- The PPPoE RSS premise for E5: per-queue counters on the access
  port under load.
- The port budget: one subscriber driven through ordinary browsing
  shapes, watching `PORT_EXHAUSTED`.
- Deterministic mode: `tests/rf-run.sh 11-cgnat-pppoe-det` should
  fail on "Verify NAT Traffic Flowing".
- Bypass: one session with `cgnat.bypass: true`, then
  `show ip fib table 0 <client>/32`, expecting the drop source to
  contribute forwarding.
- Fragments and ESP across two subscribers on one outside IP, which
  no suite exercises.

## Decisions this repo owns

- Portless protocols behind a shared outside IP: a dedicated
  address, drop and count, or accept the collision. The code picks
  the worst silently and cites an RFC that does not cover it.
- What NAT behaviour osvbng promises. Symmetric today; endpoint-
  independent mapping gates EIF, hairpinning and PCP alike, and is
  a large build.
- Deterministic mode: build it end to end or refuse it at
  validation. It is advertised in config and unimplemented.
- The traceability commitment: the interim of refusing dead config
  and raising records to Info, against committing to IPFIX.
- ADR 0006 already promises per-VRF identity and leans on
  deterministic mode; both need the code or the ADR to move.
