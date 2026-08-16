# Control-plane performance and logging

The Go control plane runs on a small fixed core budget. ADR 0007
resolves the layout per host: the auto layout reserves one core
today, and `OSVBNG_CP_CORES` pins the control plane to a larger
set on big hosts (GOMAXPROCS and taskset both follow the set, so
two to four control-plane cores is a supported deployment, not a
special build). The budget's size is a host decision; what never
changes is that it is fixed while storm work scales with
subscriber count, so anything that runs per packet, per session or
per event competes for it. Scale testing repeatedly lost
throughput to exactly two things, lock contention and logging, so
the discipline here is not taste, it is measured. The one-line
rule: **a hot path never blocks on observability or on a lock held
across I/O.**

Hot paths, concretely: punt-path packet handling, the DHCP, PPPoE
and L2TP exchanges, AAA request and response handling, VPP async
callbacks, event handlers on session lifecycle topics, accounting
sweeps. Anything multiplied by subscriber count during a
reconnect wave.

Read this before writing or reviewing any of the above. The
governing session rule is in CLAUDE.md; this note carries the
detail and the evidence.

## What profiling proved

The legacy context repo's session-setup profiling work (2026,
IPoE, target 500 CPS) is the grounding. The headline: during a
setup burst Go sat at 5.1 percent CPU while goroutines spent about
95 percent of their time blocked. The system was latency-bound,
not compute-bound, and a CPU profile missed the bottleneck
entirely. Block and mutex profiles come first;
`SetBlockProfileRate(1000)` and `SetMutexProfileFraction(10)` are
wired in cmd/osvbngd/main.go and cost nothing measurable at those
rates.

What the profiles found, and what fixed each finding:

| Bottleneck | Contention | Fix |
| - | - | - |
| Log handler mutex | 41,722s cumulative | Non-blocking sink (pkg/logger) |
| ifmgr global RWMutex | 3,348s | sync.Map, per-interface locks |
| memory cache RWMutex | 533s | sync.Map |
| Prefix allocator linear scan | 569s | O(1) free list |
| Global session RWMutex | 649s | per-session mutex, sync.Map |
| Sync checkpoint in VPP callbacks | 7 percent CPU | async opdb writes |

The logging line deserves its number spelled out: a single mutex
inside the log handler accumulated 41,722 seconds of contention,
and replacing the logger with a no-op lifted setup from 78 to 101
average CPS before any other fix. That measurement is why
pkg/logger is zerolog behind a diode writer, a bounded async ring
that drops whole lines and counts them rather than ever stalling
a goroutine.

What was NOT the bottleneck: the govpp async transport measured
245K requests/sec of capacity and was used at 0.16 percent.
Profile before optimizing, the obvious suspect was innocent.

End state after the fixes (ADR 0008 records the transport and the
lock decomposition): 302 average and 456 max CPS IPv4-only with
6,000 of 6,000 sessions completing, and zero mutex contention in
the burst profile. The remaining known bottleneck is the DHCPv6
packet pipeline (gopacket parse overhead, latency not contention).

## Concurrency rules

1. Prefer ownership to locking. One goroutine owns a piece of
   state and others talk to it over bounded channels. Do not
   sprinkle mutexes over shared maps.
2. A mutex guards a short critical section only, never held
   across I/O, an RPC, a disk write, or a channel send. If the
   lock wraps a call you cannot bound, redesign.
3. Read-mostly state is an immutable snapshot behind
   atomic.Pointer, swapped on write. RWMutex degrades badly under
   reader contention; both global RWMutexes in the table above
   were this mistake.
4. Every hot-path channel is bounded and its full behavior is
   chosen and stated: drop-and-count (the punt and egress rings,
   design/control-dataplane-seam.md) or backpressure with a
   budget (the async transport's stream pool). An unbounded queue
   or a blocking send into a channel you do not own is how a
   storm deadlocks the control plane.
5. No goroutine per packet, per session or per event. Worker
   pools and batches. Every goroutine is scheduler pressure on
   the shared core.
6. No unbounded bulk work. Ten thousand sessions hitting one
   timeout together must not become ten thousand simultaneous
   operations: bucket, jitter and rate-limit sweeps. The
   accounting bucketing in internal/aaa/component.go is the
   reference pattern.
7. Profile before guessing. A performance claim in a PR carries a
   measurement; a hot-path change that adds allocations justifies
   them.

## Logging rules

1. One logger, pkg/logger. No fmt.Print, no log.Printf, no ad hoc
   loggers in shipped code.
2. The sink never blocks, and that property is load-bearing. The
   diode writer drops and counts on overflow; dropping log lines
   is always preferable to dropping subscribers. Never wrap the
   logger in anything synchronous.
3. Hot paths log nothing per event at info level. Per-event
   detail is debug, and the call site checks the level before
   building fields, so disabled debug costs no allocation.
4. Storm-shaped errors are sampled, never per-event. A RADIUS
   timeout during a storm should be one line per peer per
   interval plus a suppressed count, not ten thousand identical
   lines that bury the signal and burn the ring. pkg/logger has
   no sampler yet (queued in todo.md); until it exists, do not
   add per-event error logs on any path a storm can drive.
5. Precompute child loggers with their fixed fields at
   construction, pass primitives as fields, never fmt.Sprintf
   into a message.

## Review red flags

Any of these blocks a PR touching a hot path: a log call in a
per-event loop without a level gate; a lock held across I/O; a new
RWMutex on read-mostly state; an unbounded channel; fmt.Sprintf in
a log call; a goroutine spawned per event; a new logger that is
not pkg/logger.

## Known debt, 2026-08

- pkg/logger has no storm sampler (logging rule 4).
- The event bus delivers by spawning a goroutine per event per
  subscriber (pkg/events/local/bus.go), the pattern rule 5 bans.
  It has not resurfaced in profiles since the session-setup fixes
  landed, but it is the next candidate under storm load.
- The DHCPv6 packet pipeline still parses each packet three times
  through gopacket.
- The auto CPU layout does not implement its own documented
  tiers: pkg/config/cpu.go's layout table promises workers scaling
  with host size and a two-core control plane at 8 plus cores, but
  autoWorkerCores always returns core 1 and autoCPCores always
  core 2. Control-plane cores also have no YAML intent knob
  (env override only, unlike dataplane.main-core and workers) and
  nothing is NUMA-aware. On large hosts the auto layout wastes
  the machine.

All four are queued in todo.md.
