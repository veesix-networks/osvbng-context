# CGNAT worker model

How the CGNAT plugin should distribute work across VPP workers. This
note records what nat44-ed does (read from the pinned VPP source,
v26.06, file references below are into `src/plugins/nat/nat44-ed/`),
answers the concerns that shape the design, and sets out the
candidate to build and the measurements that would confirm or kill
it. It is a design note, not an ADR: the candidate is chosen on
reasoning and prior art, and nothing here has been measured on the
hardware osvbng targets. The ADR comes after the numbers.

## What ships today

One shared `cgnat_session_t` pool. Every worker runs `cgnat-in2out`
and `cgnat-out2in` independently against it. Session create takes a
pool lock; per-packet state (`last_active`, `total_pkts`,
`total_bytes`, `tcp_flags`, `tcp_state`) is written unlocked from
whichever worker handles the packet.

This conflicts with the plugin coding rules in
`osvbng-vpp/CLAUDE.md` on three counts:

- "Per-worker state for anything mutated per packet; a writable
  cache line shared between workers is the single biggest measured
  throughput killer." Every translated packet writes the session's
  second cache line.
- "NEVER `pool_get`/`pool_put` on a shared pool from a worker."
  `cgnat_session_create` does exactly this, under a lock.
- "NEVER `ASSERT(thread_index == 0)` to force single-worker." All
  four node functions carry it, citing an invariant that was
  reverted.

The asserts are dead in release builds, abort debug builds on any
box with two or more cores, and tell every reviewer the opposite of
the truth. Removing them, stating the affinity in the main header,
and closing the barrier gaps found by the 2026-08-20 audit
(design/cgnat-audit-2026-08.md) is bug-fix work that does not wait
for anything below.

## What the revert actually measured

A per-worker session pool with frame-queue handoff was tried and
reverted. The recorded evidence: on a 12-worker QEMU deployment
with a single subscriber pinging at about one packet per second,
RTT was bimodal at roughly 1ms and 35ms, because the handoff
enqueued to a session-owning worker that KVM had descheduled
between packets. Reducing to one worker removed the pattern.

Two limits on how far that generalises:

- It handed off every packet. The coding rules prescribe handoff
  only when RSS lands a packet off its owning worker, and nat44-ed
  skips the enqueue for packets already on their owner. The
  experiment priced the design the rules do not ask for.
- The 30ms is a hypervisor artifact. Cold-worker wakeup at one
  packet per second is KVM rescheduling a vCPU. On bare metal with
  dedicated cores a polling worker is never descheduled that way.

So one candidate was tested, in the traffic regime and on the
platform least favourable to it. The first measurement in the test
plan below is the one that retires this evidence or confirms it.

## What nat44-ed does

Read from v26.06. Ten facts, each load-bearing for a choice below.

1. Session state is per-thread, only the lookup is shared.
   `snat_main_per_thread_data_t` (`nat44_ed.h`) holds each worker's
   own session pool and LRU lists. The one shared structure is
   `sm->flow_hash`, a single bihash_16_8 (`nat44_ed.h:510`) whose
   value packs `thread_index << 32 | session_index`
   (`nat44_ed_inlines.h:69-78`). A hit names the owner.
2. in2out owner is a hash of the inside address and fib index
   modulo the worker vector (`nat44_ed.c`,
   `nat44_ed_get_in2out_worker_index`, after the flow-hash miss).
   All of one subscriber's flows land on one worker.
3. out2in owner for a packet with no session is derived from the
   outside port by arithmetic. Each worker allocates only from its
   own slice: `port_per_thread = (65536 - 1024) / n_workers`
   (`nat44_ed.c:2126`), allocation inside the slice at
   `nat44_ed_in2out.c:93-111`, and the reverse is
   `workers[(port - 1024) / port_per_thread]`
   (`nat44_ed.c:747-758`). No table, and no allocator shared
   between threads.
4. The flow-hash lookup comes first in both directions. Port
   arithmetic is only the fallback for a packet with no session.
   The handoff node caches the session index in the buffer opaque
   (`vnet_buffer2 (b)->nat.cached_session_index`) so the owner
   does not look it up again.
5. Handoff only when needed. The handoff node compares each
   packet's target to its own `thread_index` and enqueues only the
   ones that differ (`nat44_ed_handoff.c:171-186`, enqueue at
   `:263` via `vlib_buffer_enqueue_to_thread`).
6. Main is never a target. `sm->workers` is built from the
   "workers" thread registration (`nat44_ed.c:2369-2384`); thread
   0 is not in it. Unknown protocols stay on the current thread
   because there is no port to steer by.
7. No expiry walker and no barrier for it. Per-thread,
   per-protocol LRU, reclaimed lazily on create: look at the
   oldest, free it if expired, otherwise put it back
   (`nat44_ed_inlines.h:326-355`). Constant work per create.
8. Zero explicit barrier calls in the plugin. Control-plane writes
   are safe because VPP's API dispatcher takes the worker barrier
   around every handler not marked `is_mp_safe`
   (`src/vlibapi/api_shared.c:545-565`), and the CLI does the
   same (`src/vlib/cli.c:601`). That is also the cost: every API
   call stalls every worker.
9. Bihash reads take no lock but spin while a writer holds that
   bucket (`clib_bihash_wait_bucket_lock` on the search path,
   `src/vppinfra/bihash_template.h`); writes lock per bucket.
   Concurrent adds from different owning threads are safe.
10. Nothing is NUMA-aware. A handoff moves the buffer index; the
    buffer stays in the pool of the NUMA node that received it
    (`vlib_buffer_t.numa_node`), so an owner on the other socket
    reads remote memory for every handed-off packet.

## The concerns, answered

**Flows on one CPU.** Yes, and the unit of affinity is the
subscriber, not the flow. PBA blocks are per subscriber; flow-level
affinity would split each 512-port block across N workers, 32 ports
each at 16, which is unworkable. Subscriber affinity keeps the block
and its allocator private to one worker, so the allocator needs no
lock at all.

**Return traffic on another NIC or CPU.** Two separate problems.
Which worker is solved by the flow hash for existing flows and by
port arithmetic for new inbound ones. Which socket is the part
nat44-ed ignores and osvbng can fix, because osvbng owns the
routing: give each socket its own outside addresses and advertise
them only through that socket's core NIC. Return traffic for a
socket-0 subscriber then arrives on socket 0 by construction, and
every handoff is intra-socket, where the frame queue and the
session line share L3. If both sockets advertise the same pool, the
upstream router ECMPs return traffic across them and half of it
crosses UPI. That is a BGP policy decision, not dataplane code, and
it is the most valuable single element of the design.

**Elephant flows.** A flow cannot be split across workers without
reordering; VPP's unit is the RX queue. But one worker's capacity,
several Mpps and tens of Gbps at 1500 bytes, is far above any
subscriber's plan, and the guard is the per-subscriber policer or
CAKE stage that already runs ahead of NAT on the arc. The real risk
is hash imbalance, many hot subscribers on one worker, and nat44-ed
has no answer to it. osvbng has one nat44-ed lacks: the control
plane programs the mapping and knows the plan, so it can carry an
explicit owner worker. Default to the hash; keep the override.
Inbound floods toward one outside address spread across workers by
port slice, which is the right property.

**Main core.** Handled by VPP's model once the target set is built
from the workers registration. With workers configured, main does
not poll RX, so the cgnat nodes never run there. The only main-
thread datapath work in today's plugin is the expiry walker, which
lazy LRU deletes.

**Deadlocks.** The design removes shared mutable datapath state
rather than locking it: per-thread sessions and LRU written only by
their owner, a per-worker allocator, and bihash bucket locks held
for a few instructions and never nested. No spinlock on the packet
path means no lock ordering, which means nothing to deadlock. Two
rules keep it that way. A worker never takes the barrier, since it
would wait on itself. And control-plane writes reach a worker by
the per-worker interrupt pattern from the coding rules: main
enqueues to the owner's list, sets interrupt pending on a per-
worker input node, and the owner installs into its own pool. That
replaces nat44-ed's implicit barrier per API call, which at
osvbng's per-subscriber mapping churn is the barrier-on-a-
churning-path problem the audit records.

## The candidate to build

Phase 0, independent of everything else: the point fixes from the
audit, the asserts removed, the affinity stated in the header, the
cascade delete barrier'd.

Phase 1, the house pattern, no Go changes:

- per-thread session pools and per-thread per-protocol LRU;
- owner = hash(inside address, fib) within the NUMA-local worker
  set for the access interface the packet arrived on;
- one shared flow hash with `(thread, session)` values;
- handoff nodes in both directions, same-thread skip, cached
  session index in the buffer opaque;
- lazy expiry on create, the walker deleted;
- mapping add and delete delivered to the owner by per-worker
  interrupt, never under the barrier;
- per-packet counters per thread.

Port slicing is not needed in this phase. With address-and-port-
dependent filtering, which is what ships, every out2in packet
belongs to an existing flow and resolves through the flow hash. The
Go allocator and the authority chain in ADR 0006 are untouched.

Phase 2, with endpoint-independent mapping and filtering: per-
worker port slices so a first inbound packet steers by arithmetic,
and per-socket outside-address advertisement. Here the Go allocator
must learn the worker count to carve a subscriber's block inside
the owner's slice, or the dataplane allocates inside the slice and
Go records it. Either is an amendment to ADR 0006, and an SRG pair
needs identical worker layouts on both peers.

## Test plan

Bare metal, dual socket, one access NIC and one core NIC per
socket, `corelist-workers` split per socket, rx-queues per NIC equal
to that socket's workers, buffers per NUMA node. Placement verified
with `show threads`, `show interface rx-placement` and
`show hardware-interfaces` before anything is measured. bngblaster
on the access side, TRex on the core side. Run with the
`make vpp-perf` convention and record the numbers in this note.

In order, because each result changes whether the next is worth
running:

1. Cold-worker RTT on bare metal. One subscriber at one packet per
   second through the phase 1 build. If the 30ms does not
   reproduce, the revert's evidence is retired.
2. Throughput against worker count per socket, 64 byte and IMIX.
   With N workers roughly (N-1)/N of packets in both directions
   take one intra-socket handoff, because the NIC hashes the
   5-tuple and cannot know the owner function. The number that
   decides the design is the per-packet cost of a handoff to a hot
   worker.
3. Wrong NUMA layout on purpose, core NIC on the other socket,
   against the right one, with uncore or `pcm-numa` counters. This
   prices the per-socket advertisement decision.
4. Churn at 1000 sessions per second up and down during test 2.
   Prices mapping programming by interrupt against today's
   barrier.
5. PPPoE upstream per access port. The decap path has no handoff
   and NICs generally cannot hash inside ethertype 0x8864, so
   upstream PPPoE concentrates on one queue per port today.
   Handoff is the fix for that ceiling, not only a cost; measure
   with and without.
6. One subscriber at 10Gbps beside others at 50Mbps, asserting the
   others' latency. Confirms the policer ahead of NAT is the guard
   it is assumed to be.

## Open decisions

- Per-socket outside sub-prefixes, which need BGP policy per NIC
  pair, against accepting cross-socket handoff and measuring it.
- Phase 2 block allocation: Go learning the worker count, or the
  dataplane allocating inside the slice with Go recording it.
- Hardware. Every measurement above needs a dual-socket box with
  two NIC pairs and a TRex source. Without it the plan is blocked,
  and should be called blocked rather than verified on the
  af-packet rig, which cannot produce these numbers.
