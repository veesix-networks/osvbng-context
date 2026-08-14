# ADR 0008 - Async VPP binary API transport with reconciliation in the session layer

- Status: Accepted
- Date: 2026-08-14
- Deciders: Brandon

## Context

govpp's synchronous Channel API measures 107 requests/second; its
async API measures 251,878 (the C vppapiclient reaches 762,000). The
sync pattern also creates a new API channel per call and blocks the
caller until VPP replies, so VPP programming from packet-processing
paths stalls everything behind it. Before the async transport,
IPv4-only session setup measured 12.45 CPS average (18.82 max) and
6,000-session load tests completed only 1,309 sessions.

## Decision

**All runtime VPP programming goes through an async worker in
pkg/southbound/vpp/ built on govpp streams, and the worker's only
job is to deliver each reply or error to its caller's callback;
retry, teardown, and VPP state reconciliation belong to the session
layer (IPoE, PPPoE, CGNAT), never to the transport.**

- Reply matching uses a pool of streams (default 64, held in
  AsyncWorkerConfig, not YAML). The default is derived from VPP
  latency characteristics and the 48k session target and sustains
  32k+ API calls/sec while providing backpressure toward VPP.
- On stream recycle the worker alternates ReplyBufSize (8/9), which
  makes govpp create a fresh reply channel instead of reusing a
  pooled one, discarding any stale reply. The residual race needs a
  VPP reply arriving more than 5s late, and a timeout of that size
  indicates VPP failure, where the circuit breaker opens anyway.
- SendAsync always invokes the callback on rejection (queue full,
  circuit open), not only on the error return: async callers ignore
  the return value, so the callback is the only reliable error path.
- Timeout and send errors are wrapped with the VPP message name
  (for example "recv osvbng_ipoe_set_session_ipv6: reply timeout
  (5s)") so the session layer knows which operation failed. Session
  layers do not yet act on this; the transport contract is in place.
- Callbacks are dispatched as goroutines (recvLoop, sendLoop error
  paths, and reconnect drain), so a slow callback never blocks reply
  receipt. Ordering stays correct because sequential per-session VPP
  operations are enqueued from inside the previous callback, and
  cross-session concurrency is safe because sessions own separate
  state and shared maps are mutex-protected.
- Shutdown is a fixed sequence: open the circuit, cancel the
  context, wait for workers (each closes its stream on exit), then
  drain the request queue. Opening the circuit first stops new
  enqueues during the drain. Reconnect destroys the worker via this
  sequence and creates a new one; streams are never rebuilt in
  place.

The session-setup path pairs the transport with hot-path work in the
control plane: DHCPv4 and DHCPv6 forwarding run concurrently per
session, the IPv4 pool and DHCPv6 PD prefix allocators
(pkg/allocator/) use pre-populated O(1) free lists (with a restore
path that removes OpDB-restored leases from the free list at
startup), and global RWMutexes were decomposed into sync.Map plus
per-interface locks in pkg/ifmgr/ (with an O(1) address index for
ARP lookups), per-session mutexes in internal/ipoe/, and sync.Map in
the memory cache.

## Consequences

- IPv4-only session setup measures 302 CPS average (456 max), up
  from 12.45 (18.82 max), with 6,000 of 6,000 sessions completing.
  Dual-stack measures 130 avg / 161 max with IA_NA only and 78 avg /
  123 max with IA_NA plus PD.
- The pool design makes reply loss structurally near-impossible, so
  session-layer reconciliation is defense in depth, not the primary
  correctness mechanism. It remains a known gap that callers do not
  reconcile on transport errors.
- Session-layer code must treat the callback as the completion
  event: anything that depends on VPP state (for example forwarding
  DHCPv6 packets pended during session creation) runs from the
  callback, not from the code that enqueued the request.

## Alternatives considered

- Synchronous Channel API per call: measured 107 rr/s and blocks
  packet processing; the async API measures 251,878 rr/s.
- Reconciliation inside the transport: rejected, the worker reports
  errors cleanly and the session layer owns retry and teardown.
- Exposing pool size in YAML: rejected until operators demonstrably
  need to tune it; adding the field later is a one-line change.
- Larger default pool (256): rejected, 64 already sustains the
  target rate and its backpressure toward VPP is intentional.
