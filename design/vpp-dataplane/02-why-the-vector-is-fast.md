# 02 - Why processing the whole vector is fast

> VPP v26.06 (`v26.06-rc0-25-g3e3df231d`). Paths relative to the VPP source root.

The headline intuition is correct: the first packet through a node warms the
CPU caches and the rest ride for nearly free. But "warms the cache" is doing a
lot of work in that sentence. There are at least six distinct mechanisms, and
they stack. This file names each one and points at the code.

## Mechanism 1: Instruction-cache locality (the core idea)

The reason VPP groups packets per node rather than pushing one packet through
the whole graph is the **instruction cache**, not the data cache.

Consider the two ways to forward N packets through a 6-node graph:

- **Run-to-completion (per-packet):** packet 0 executes node A's code, then B,
  C, D, E, F; then packet 1 executes A, B, C, ... By the time packet 1 reaches
  A again, A's code may have been evicted from L1i by the code for B..F. Every
  packet re-fills the instruction cache for every node. The i-cache is cold
  constantly.
- **Vector (VPP):** all N packets execute node A, then all N execute node B,
  and so on. Node A's instructions are pulled into L1i for packet 0 and stay hot
  for packets 1..N-1. You pay the i-cache miss once per node per frame instead
  of once per node per packet.

This is exactly the ordering enforced by the dispatch loop: each node's
`function` is called once over the entire frame (`src/vlib/main.c:906`), and the
loop fully drains one node's pending frame before the next
(`src/vlib/main.c:1610`). There is no single line that says "warm the i-cache";
it is an emergent property of the per-node batching. With a 256-packet frame and
a forwarding node of a few KB of code, the per-packet share of i-cache misses
approaches zero.

The same batching warms two other CPU structures for packets 1..N-1:

- the **branch predictor** (the node's branches resolve the same way for similar
  packets, so after the first packet the predictor is trained), and
- the **data cache** for any per-node tables the node touches repeatedly (FIB
  trie nodes, adjacency rewrite strings, hash buckets).

### The precise claim (it is per-node, not per-graph)

A tempting but wrong way to state Mechanism 1 is "the whole node graph gets
loaded into the CPU once per vector." It does not. The accurate claim is:

> Each node's hot code is fetched into L1i **once per frame**, and reused across
> every packet in that frame. At any instant the resident code working set is a
> **single node**, not the whole graph.

The dispatch loop calls `node->function(vm, node, frame)` once with up to 256
packets, so only node A's code needs to be hot while A runs. When node B runs
next it may evict A's code, which is fine because the frame is done with A. The
consequence is the important part:

- **Run-to-completion** (one packet through A, B, ... F, then the next packet) has a
  code working set equal to the **sum** of every node on the path. If that sum
  exceeds L1i, every packet re-misses on every node.
- **Vector processing** has a code working set equal to the **largest single
  node**, never the sum. Graph size stops mattering for i-cache pressure.

### "What if the code is too large?"

Two genuinely different cases, often conflated:

1. **The whole graph is too large for L1i.** Expected and harmless. A real BNG
   graph is hundreds of nodes and far bigger than the ~32 KB L1i on a typical
   x86 core. Vector processing is exactly the technique that makes this a
   non-issue: you never need more than one node resident.
2. **A single node's per-packet hot path is too large for L1i.** This is the
   real failure mode. If one node's inner loop plus everything it calls per
   packet overflows L1i (or the micro-op cache below), it thrashes *within* the
   frame and the amortisation breaks. This is why VPP nodes are deliberately
   small and single-purpose, why rare work is pushed behind `PREDICT_FALSE`
   branches (the slow path is never fetched in the common case), and why authors
   split a fat operation across several small nodes rather than inlining it all
   into one.

So "too large" is a constraint on the size of an individual node, not on the
size of the graph.

### Two levels of front-end caching

The i-cache story actually operates at two granularities, and the second one is
often the bigger win for a tight node:

- **L1 instruction cache**, at the *node-across-frames* level (described above):
  a node's code is re-fetched at most once per frame.
- **The decoded micro-op cache** (Intel DSB, AMD op cache), and for very small
  loops the loop buffer, at the *iteration-within-the-node* level. A dual/quad
  loop iterating ~128 times over a 256-packet frame runs every iteration after
  the first straight out of the micro-op cache, skipping instruction fetch *and*
  decode entirely. For a small node this matters more than L1i and is the most
  precise mechanism behind "packets 2..N are nearly free."

### How to tell whether a node is actually amortising

Two signals, one built into VPP and one from the CPU:

1. **`show runtime`** (driven by the per-node counters at `src/vlib/main.c:920`)
   prints `Vectors/Call` and `Clocks/Vector` per node. The signature of healthy
   amortisation is that **`Clocks/Vector` falls as `Vectors/Call` rises**: the
   busier the box, the cheaper each packet. If a hot node's `Clocks/Vector`
   stays flat or climbs as the frame fills, it is not amortising, usually
   because it is front-end bound (code too big) or memory bound (data).
2. **`perf` top-down analysis** (`perf stat --topdown`, or `toplev.py` from
   pmu-tools) to confirm *why*. A well-optimised hot node should resolve as
   **Backend Bound** (limited by data movement or execution units). A hot node
   that is **Frontend Bound** is the red flag for i-cache / code-size trouble.
   Drill in with `L1-icache-load-misses`, and on Intel the
   `idq.dsb_uops` vs `idq.mite_uops` ratio: a high MITE share means the micro-op
   cache is missing and the loop is being re-decoded every iteration.

Rule of thumb for the blog: **optimised = backend-bound with `Clocks/Vector`
dropping under load; not optimised = front-end bound, or `Clocks/Vector` that
refuses to drop as the frame fills.**

## Mechanism 2: Software pipelining via dual / quad loops

Inside a node, the packet loop is not a naive `for (i = 0; i < n; i++)`. Fast
nodes use a "dual loop" (2 packets per iteration) or "quad loop" (4, sometimes
8) so they can **prefetch the data for packets that are 2 ahead while computing
on the current ones**. This hides DRAM and L2/L3 latency: by the time the loop
reaches packet i+2, its header and metadata are already in L1.

Canonical example, `ip4-load-balance`, `src/vnet/ip/ip4_forward.c:90`:

```c
  vlib_buffer_t *bufs[VLIB_FRAME_SIZE], **b = bufs;
  u16 nexts[VLIB_FRAME_SIZE], *next;

  from = vlib_frame_vector_args (frame);
  n_left = frame->n_vectors;
  next = nexts;

  vlib_get_buffers (vm, from, bufs, n_left);   // indices -> pointers (SIMD)

  while (n_left >= 4)
    {
      // ...
      /* Prefetch next iteration. */
      {
        vlib_prefetch_buffer_header (b[2], LOAD);
        vlib_prefetch_buffer_header (b[3], LOAD);

        CLIB_PREFETCH (b[2]->data, sizeof (ip0[0]), LOAD);
        CLIB_PREFETCH (b[3]->data, sizeof (ip0[0]), LOAD);
      }

      ip0 = vlib_buffer_get_current (b[0]);
      ip1 = vlib_buffer_get_current (b[1]);
      // ... compute next-node for b[0] and b[1] ...
      b += 2;
      next += 2;
      n_left -= 2;
    }

  while (n_left > 0)                            // tail: 1 packet at a time
    {
      // ... same logic, no prefetch ...
    }
```

The subtlety worth getting right in a blog: the loop *processes two packets per
iteration* (`b += 2; n_left -= 2` at `src/vnet/ip/ip4_forward.c:181`) but its
guard is `n_left >= 4` (`:99`). The extra headroom exists precisely so that
`b[2]` and `b[3]` are always valid buffers to prefetch (`:108`). When fewer than
4 remain, the tail loop at `:186` mops up the last two or three with no
prefetch, because there is nothing further ahead to prefetch.

Heavier nodes go wider. `ip4_rewrite_inline` in the same file runs an 8-wide
loop when `CLIB_N_PREFETCHES >= 8`, prefetching buffer headers 6 and 7 ahead
while it rewrites 0 and 1, with a comment that states the intent outright:

`src/vnet/ip/ip4_forward.c` (in `ip4_rewrite_inline`):

```c
      /* Worth pipelining. No guarantee that adj0,1 are hot... */
      // ...
      p = vlib_buffer_get_current (b[2]);
      clib_prefetch_store (p - CLIB_CACHE_LINE_BYTES);
      clib_prefetch_load (p);
```

## Mechanism 3: Explicit data prefetch primitives

The prefetch calls above compile to `__builtin_prefetch`, wrapped so a node can
express read-vs-write and cache-level intent. Definitions in
`src/vppinfra/cache.h`:

`src/vppinfra/cache.h:55` (multi-line prefetch, up to 4 cache lines):

```c
#define CLIB_PREFETCH(addr, size, type)                                       \
  do                                                                          \
    {                                                                         \
      void *_addr = (addr);                                                   \
      ASSERT ((size) <= 4 * CLIB_CACHE_PREFETCH_BYTES);                       \
      _CLIB_PREFETCH (0, size, type);                                         \
      _CLIB_PREFETCH (1, size, type);                                         \
      _CLIB_PREFETCH (2, size, type);                                         \
      _CLIB_PREFETCH (3, size, type);                                         \
    }                                                                         \
  while (0)
```

`src/vppinfra/cache.h:83` (the single-line read/write helpers used by nodes):

```c
static_always_inline void
clib_prefetch_load (void *p)
{
  __builtin_prefetch (p, /* rw */ 0, /* locality */ 3);
}
// clib_prefetch_store at :101 uses rw = 1
```

The `type` argument selects the locality hint that maps onto `prefetcht0/1/2`
and `prefetchnta`:

`src/vppinfra/cache.h:39`

```c
#define CLIB_PREFETCH_TO_STREAM 0 // NTA
#define CLIB_PREFETCH_TO_L3     1 // T2
#define CLIB_PREFETCH_TO_L2     2 // T1
#define CLIB_PREFETCH_TO_L1     3 // T0
```

`CLIB_N_PREFETCHES` (default 16, `src/vppinfra/cache.h:22`) is what node code
tests to decide how wide to make its loop. On a microarch tuned with a smaller
value (some Arm cores set 8), nodes fall back to narrower loops automatically.

## Mechanism 4: SIMD batch helpers in the hot path

Several per-frame operations every node performs are themselves vectorised.
The most common is the index-to-pointer gather at the top of every modern node,
`vlib_get_buffers`. It converts the frame's `u32` buffer indices into
`vlib_buffer_t *` pointers, 64 at a time, using `clib_index_to_ptr_u32` (a
SIMD routine, see [03](03-cpu-feature-utilization.md)):

`src/vlib/buffer_funcs.h:185` (inside `vlib_get_buffers_with_offset`, which
`vlib_get_buffers` at `:228` calls):

```c
      u32 n = round_pow2 (count, 8);
      while (n >= 64)
        {
          clib_index_to_ptr_u32 (bi, base, sh, b, 64);   // SIMD, 64 at a time
          b += 64;
          bi += 64;
          n -= 64;
        }
      while (n)
        {
          clib_index_to_ptr_u32 (bi, base, sh, b, 8);    // SIMD, 8 at a time
          b += 8; bi += 8; n -= 8;
        }
```

The symmetric operation at the end of a node, enqueueing packets to their next
nodes, is also a batch primitive (`vlib_buffer_enqueue_to_next`,
`src/vlib/buffer_node.h`), and it is itself march-multi-versioned so the build
picks an AVX2/AVX512/NEON implementation per CPU.

## Mechanism 5: Speculative enqueue (branch-free common case)

The dual/quad loop assumes all packets in an iteration go to the same next node,
enqueues them speculatively, and only fixes up the rare case where one diverges.
When the speculation holds (the overwhelmingly common case for a flow), the
"enqueue" is just a counter bump with no per-packet branch into the slow path.
VPP documents this directly on the macro:

`src/vlib/buffer_node.h:15`

```
/** \brief Finish enqueueing two buffers forward in the graph.
 Standard dual loop boilerplate element. ... In the ideal case,
 next_index == next0 == next1, which means that the speculative enqueue
 at the top of the dual loop has correctly dealt with both packets. In
 that case, the macro does nothing at all.
```

The quad-loop equivalent is at `src/vlib/buffer_node.h:82`. Modern nodes like
`ip4-load-balance` express the same idea by writing a `nexts[]` array and
calling `vlib_buffer_enqueue_to_next` once for the whole frame, which is the
batch form of the same speculation.

## Mechanism 6: Cache-line alignment and false-sharing avoidance

Hot structures are aligned to a cache line so unrelated fields touched by
different workers do not sit in the same line (false sharing). The cache-line
size and the alignment marker:

`src/vppinfra/cache.h:11`

```c
/* Default cache line size of 64 bytes. */
#ifndef CLIB_LOG2_CACHE_LINE_BYTES
#define CLIB_LOG2_CACHE_LINE_BYTES 6
#endif
```

`src/vppinfra/cache.h:26`

```c
#define CLIB_CACHE_LINE_BYTES     (1 << CLIB_LOG2_CACHE_LINE_BYTES)   /* 64 */
#define CLIB_CACHE_LINE_ALIGN_MARK(mark)                                      \
  u8 mark[0] __attribute__ ((aligned (CLIB_CACHE_LINE_BYTES)))
```

`vlib_node_runtime_t` opens with `CLIB_CACHE_LINE_ALIGN_MARK (cacheline0)`
(`src/vlib/node.h:486`) so the per-node runtime that the dispatch loop touches
every iteration starts on its own cache line. Driver RX/TX queue structs do the
same and then `STATIC_ASSERT_SIZEOF` themselves to an exact multiple of cache
lines so the layout cannot silently regress.

## Putting it together

For a 256-packet frame entering, say, `ip4-lookup`:

1. The node's code is pulled into L1i for packet 0 and stays hot for packets
   1..255 (Mechanism 1).
2. `vlib_get_buffers` converts all 256 indices to pointers with SIMD before the
   loop even starts (Mechanism 4).
3. The dual/quad loop computes on packets i and i+1 while prefetching the
   headers and FIB data for i+2 and i+3 (Mechanisms 2 and 3).
4. The branch predictor, trained on packet 0, predicts the same path for the
   rest of the frame (Mechanism 1).
5. The common "all go to the same next node" case enqueues with no per-packet
   branch (Mechanism 5).

The first packet is slow. Packets 2..256 execute against hot i-cache, hot
predictor, prefetched data, and SIMD helpers. That is the whole game.
