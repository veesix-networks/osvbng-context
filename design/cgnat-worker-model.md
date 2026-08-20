# CGNAT worker model, an open question

The CGNAT plugin's approach to distributing work across VPP workers
is not settled, and the code, the plugin's AUDIT.md and
`design/cgnat-architecture.md` currently state it three different
ways. This note holds the question open honestly until benchmarks
on target hardware settle it. It is deliberately not an ADR: no
decision has been made.

## What ships today

One shared `cgnat_session_t` pool. Every worker runs
`cgnat-in2out` and `cgnat-out2in` independently against it. Session
create takes a pool lock; per-packet state (`last_active`,
`total_pkts`, `total_bytes`, `tcp_flags`, `tcp_state`) is written
unlocked from whichever worker handles the packet.

This conflicts with the plugin coding rules in
`osvbng-vpp/CLAUDE.md` on three counts:

- "Per-worker state for anything mutated per packet
  (`per_thread_data[vm->thread_index]`); a writable cache line
  shared between workers is the single biggest measured throughput
  killer." Every translated packet writes the session's second
  cache line.
- "NEVER `pool_get`/`pool_put` on a shared pool from a worker."
  `cgnat_session_create` does exactly this, under a lock.
- "NEVER `ASSERT(thread_index == 0)` to force single-worker." All
  four node functions carry it, citing an invariant that was
  reverted.

The asserts are the least defensible part and are independent of
everything below: the shipped code is multi-worker whatever
architecture wins, so they are dead in release builds, abort debug
builds on any box with two or more cores, and tell every reviewer
the opposite of the truth. The 2026-08-20 audit traced three
shipped cross-worker defects to reviewers reasoning against
whichever of the three statements they read first. Removing them,
stating the affinity in the main header, and closing the barrier
gaps is bug-fix work that should not wait for this note.

## What the revert actually measured

A per-worker session pool with frame-queue handoff was tried and
reverted. The recorded evidence: on a 12-worker QEMU deployment
with a single subscriber pinging at about one packet per second,
RTT was bimodal at roughly 1ms and 35ms, because the handoff
enqueued to a session-owning worker that KVM had descheduled
between packets, and the packet waited for the vCPU to come back.
Reducing to one worker removed the pattern.

Two limits on how far that generalises, both of which matter for a
high-core-count bare-metal deployment:

- **It measured handoff on every packet.** The coding rules
  prescribe handoff only "when RSS lands a packet off its owning
  worker", which makes handoff the exception rather than the rule.
  The experiment made it unconditional, so it priced the design
  that the rules do not ask for.
- **The 30ms is a hypervisor artifact.** Cold-worker wakeup at
  about one packet per second is KVM rescheduling a vCPU. On bare
  metal with dedicated cores, a polling worker is never
  descheduled that way. The measurement says little about the same
  design on the hardware osvbng targets.

So one of the candidate architectures was tested, in the traffic
regime and on the platform least favourable to it.

## Candidates, none of them measured on target hardware

1. **Shared pool, every worker translates** (today). Simplest, no
   handoff, no steering requirement. Ceiling is the shared writable
   cache line, which the coding rules name as the biggest measured
   throughput killer, plus lock contention on create.
2. **Per-worker pools with unconditional handoff** (tried,
   reverted). Pays a handoff per packet, and is exposed to
   cold-worker latency wherever workers are not kept hot.
3. **The house pattern, never tried.** Shared bihash for lookup
   with `(thread_index << 32 | index)` packed into the value so a
   hit names the owning worker, per-worker session state, and
   handoff only when RSS lands a packet off its owner. This is what
   the rules prescribe, and it is the option no experiment has
   priced.
4. **Steering so handoff is rare**, as a modifier on 3. Choosing
   the outside port so that return traffic hashes back to the
   owning worker turns out2in handoff into the exception.
   nat44-ed exposes `nat_set_workers` and `nat_worker_dump`, so it
   assigns workers explicitly; read its port-selection code at
   fd.io before designing ours, rather than assuming the
   mechanism.
5. **Per-worker port sub-ranges** within a subscriber's block, as a
   modifier on 3 or 4, so port allocation needs no cross-worker
   serialisation at all.

## What would settle it

Bare metal, high core count, a NIC whose RSS behaviour is known,
and traffic shaped like a BNG rather than like a single flow:
many subscribers at modest per-subscriber rates, which is the
regime where option 2 failed and the one the box will actually
see. Measure at minimum:

- Aggregate translated throughput against worker count, to find
  where each option stops scaling.
- Handoff rate under options 3 and 4, since their whole argument is
  that it is rare. If RSS lands most return traffic on the wrong
  worker, 3 collapses into 2.
- Per-packet cost attributable to the shared cache line under
  option 1, which is the number that decides whether today's design
  has a ceiling worth leaving in place.

Run it with `make vpp-perf` per the repo convention, and record the
numbers here. Until then no option is ruled in or out, and the
plugin's own AUDIT.md should stop reading as though the question
closed with the revert.

## Adjacent, and easy to confuse with this

PPPoE access has its own distribution problem that is independent
of the CGNAT pool model. The decap path has no handoff node, and
NICs generally cannot hash inside ethertype 0x8864, so upstream
PPPoE traffic can concentrate on one queue per access port while
downstream out2in spreads across workers by outer-IP RSS. That
asymmetry is also what puts the two directions of one session on
different workers, which is what makes option 1's unlocked writes
race in the first place. It was flagged as needing rig measurement
and has not been measured. Whichever CGNAT option wins, a
one-core-per-access-port ceiling upstream would bind first for
PPPoE subscribers, so measure it alongside.
