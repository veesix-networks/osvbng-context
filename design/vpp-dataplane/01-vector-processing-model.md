# 01 - The vector processing model

> VPP v26.06 (`v26.06-rc0-25-g3e3df231d`). Paths relative to the VPP source root.

## Terminology: "frame" here is not an Ethernet frame

VPP overloads the word **frame**, and it is the single most common source of
confusion when reading this code. In VPP, a *frame* is a **call frame** in the
sense of a function-call or stack frame, the bundle of arguments handed to a
node. The VPP source says so directly at `src/vlib/node.h:403`:

```c
/* Calling frame (think stack frame) for a node. */
typedef struct vlib_frame_t
```

It has nothing to do with L2 framing. The Ethernet frame off the wire lives
*inside* one of the packets that a `vlib_frame_t` references. The two meanings
are nested, not the same thing. The vocabulary, smallest to largest:

| Term | What it is | Networking analogy |
|------|-----------|--------------------|
| **Ethernet frame** | The L2 PDU on the wire (dst/src MAC, ethertype, payload, FCS). | The actual bytes on the cable |
| **Buffer** (`vlib_buffer_t`) | VPP's struct for **one packet**: the packet bytes plus metadata. The Ethernet frame's bytes live here. | One packet, in memory |
| **Buffer index** (`u32`) | A lightweight integer handle to a buffer. This is what gets passed around, not pointers. | A ticket number for a packet |
| **Vector** | An array. Here, the array of buffer indices. | "a batch of packets" |
| **Frame** (`vlib_frame_t`) | The container carrying that vector of buffer indices from one node to the next. Up to `VLIB_FRAME_SIZE = 256` of them. | The crate the batch ships in |

```
vlib_frame_t  (a "frame" = the node's argument bundle)
   └── vector: [ bi0, bi1, bi2, ... bi255 ]   (array of buffer indices, max 256)
                  │
                  └── each index points at a vlib_buffer_t  (one packet)
                          └── whose data, at ingress, IS an Ethernet frame
```

Throughout these documents, **frame** always means `vlib_frame_t` (the node
argument bundle), and a packet's L2 header is always called an **Ethernet
frame** in full. When in doubt, read "frame" as "the crate of up to 256 packet
handles passed to a node."

## What "vector" means here

The "vector" in Vector Packet Processing is not a SIMD register and it is not a
parallel execution unit. It is an ordinary array of packets. VPP collects a
batch of packet handles, calls a graph node's function **once** for the whole
batch, and that function walks the array in a `for` loop, one packet at a time.

The win is not parallelism. The win is *amortisation*. Per-packet overheads
(getting code into the instruction cache, training the branch predictor,
the function-call and frame-setup cost) are paid once per batch instead of once
per packet. The packet-by-packet section ([02](02-why-the-vector-is-fast.md))
explains exactly which overheads get amortised.

## The node graph

VPP forwarding is a directed graph of *nodes*. Each node does one job (Ethernet
input, IPv4 lookup, IPv4 rewrite, an output driver, etc.) and hands packets to
the next node. Nodes are registered at load time and come in a handful of types.

`src/vlib/node.h:37`

```c
typedef enum
{
  /* An internal node on the call graph (could be output). */
  VLIB_NODE_TYPE_INTERNAL,
  /* Nodes which input data into the processing graph.
     Input nodes are called for each iteration of main loop. */
  VLIB_NODE_TYPE_INPUT,
  /* Nodes to be called before all input nodes. ... */
  VLIB_NODE_TYPE_PRE_INPUT,
  /* "Process" nodes which can be suspended and later resumed. */
  VLIB_NODE_TYPE_PROCESS,
  /* Nodes to by called by per-thread timing wheel. */
  VLIB_NODE_TYPE_SCHED,
  VLIB_N_NODE_TYPE,
} vlib_node_type_t;
```

- **INPUT** nodes pull packets from a source (a NIC, a kernel socket ring) and
  are the entry point of every frame. They are the ones polled on every loop
  iteration. See [05](05-afpacket-vs-dpdk-polling.md).
- **INTERNAL** nodes are everything in the middle and the output drivers.
- **PROCESS** nodes are cooperative coroutines for control-plane-ish work
  (timers, management), not the per-packet fast path.

A node is registered with `VLIB_REGISTER_NODE` (`src/vlib/node.h:175`), which
uses a constructor to push the registration onto a global linked list at load
time. The node's per-packet work lives in a `VLIB_NODE_FN` function
(`src/vlib/node.h:208`), which is what gets compiled once per CPU
microarchitecture (see [03](03-cpu-feature-utilization.md)).

## Frames carry the vector

A node does not receive a raw array pointer. It receives a `vlib_frame_t`. The
frame is a small header followed by the vector of arguments (for the fast path,
an array of 32-bit buffer indices).

`src/vlib/node.h:396`

```c
/* Max number of vector elements to process at once per node. */
#define VLIB_FRAME_SIZE 256
```

`src/vlib/node.h:403`

```c
/* Calling frame (think stack frame) for a node. */
typedef struct vlib_frame_t
{
  u16 frame_flags;
  u16 flags;                 /* hints to the next node */
  u16 scalar_offset, vector_offset, aux_offset;
  u16 n_vectors;             /* elements currently in the frame */
  u16 frame_size_index;
  u8 arguments[0];           /* scalar + vector args live here */
} vlib_frame_t;
```

The two numbers that matter:

- **`VLIB_FRAME_SIZE == 256`** is the ceiling on packets processed per node call.
  A node is invoked with at most 256 packets in `n_vectors`. Under low load a
  frame might carry one packet; under high load it fills toward 256 and the
  per-packet cost drops. This is the self-regulating behaviour VPP is known for:
  the busier you are, the more efficient you get.
- **`n_vectors`** is how many packets are actually in this frame.

The vector itself (the `u32` buffer-index array) is reached with
`vlib_frame_vector_args(frame)` (`src/vlib/node_funcs.h`), and a node turns
those indices into buffer pointers with `vlib_get_buffers` (covered in
[02](02-why-the-vector-is-fast.md), it is SIMD-accelerated).

## The dispatch loop

Every worker (and the main thread) runs one function:
`vlib_main_or_worker_loop` in `src/vlib/main.c:1446`. Its core is an infinite
loop. Each iteration: poll the input nodes, then drain every frame those inputs
produced through the rest of the graph.

`src/vlib/main.c:1500` (the loop opens), and the input-node poll at
`src/vlib/main.c:1548`:

```c
  while (1)
    {
      // ... barrier checks, handoff-queue checks, file poll ...

      for (vlib_node_type_t nt = 0; nt < VLIB_N_NODE_TYPE; nt++)
        {
          if (node_type_attrs[nt].can_be_polled)
            vec_foreach (n, nm->nodes_by_type[nt])
              if (n->state == VLIB_NODE_STATE_POLLING)
                cpu_time_now = dispatch_node (
                  vm, n, nt,
                  /* frame */ 0, VLIB_NODE_DISPATCH_REASON_POLL, cpu_time_now);
          // ... interrupt-driven dispatch for the same node type ...
        }
```

Note `n->state == VLIB_NODE_STATE_POLLING` at `src/vlib/main.c:1552`. An input
node only runs here if it is in the polling state. That single condition is the
whole busy-poll-vs-sleep story in [05](05-afpacket-vs-dpdk-polling.md).

Input nodes enqueue work into *pending frames*. After polling inputs, the loop
drains them in graph order:

`src/vlib/main.c:1610`

```c
      /* Input nodes may have added work to the pending vector.
         Process pending vector until there is nothing left.
         All pending vectors will be processed from input -> output. */
      for (i = 0; i < _vec_len (nm->pending_frames); i++)
        cpu_time_now = dispatch_pending_node (vm, i, cpu_time_now);
      vec_set_len (nm->pending_frames, 0);
```

So one main-loop iteration is: poll inputs to create frames, push each frame
through the graph node-by-node until the graph is empty, repeat. Critically,
each node processes its **entire** frame before the next node runs. That is what
keeps a node's code hot in the instruction cache for the whole vector.

## Where a node's function is actually called

Both `dispatch_node` and `dispatch_pending_node` funnel into one call site. The
node's registered function pointer is invoked with the frame:

`src/vlib/main.c:904`

```c
  node->dispatch_reason = dispatch_reason;
  if (PREDICT_TRUE (vm->dispatch_wrapper_fn == 0))
    n = node->function (vm, node, frame);     // <-- the node runs here
  else
    n = vm->dispatch_wrapper_fn (vm, node, frame);

  t = clib_cpu_time_now ();
  // ...
  vm->main_loop_vectors_processed += n;       // n = packets this node handled
```

`node->function(vm, node, frame)` at `src/vlib/main.c:906` is the heart of the
engine. It is called once and returns `n`, the number of packets it processed.
That return value feeds the per-node counters (`vectors`, `calls`, `clocks`)
that `show runtime` prints, and it feeds the adaptive polling logic in
`src/vlib/main.c:925` that flips a node between interrupt and polling mode based
on observed vector rate.

Just before the call, VPP prefetches the node's outbound frame bookkeeping so
the enqueue at the end of the node is cheap:

`src/vlib/main.c:871`

```c
  /* Speculatively prefetch next frames. */
  if (node->n_next_nodes > 0)
    {
      nf = vec_elt_at_index (nm->next_frames, node->next_frame_index);
      CLIB_PREFETCH (nf, 4 * sizeof (nf[0]), WRITE);
    }
```

## Per-node accounting

`dispatch_node` records, per node, the number of calls, the number of vectors
(packets), and the CPU cycles spent (`clib_cpu_time_now()` reads the TSC before
and after). These are the numbers behind `show runtime`:

- `vectors/call` = packets per frame, the efficiency signal. Closer to 256 means
  the box is busy and amortising well; close to 1 means lightly loaded.
- `clocks/vector` = cycles per packet for that node, the cost signal.

The counters live in `vlib_node_runtime_t` (`src/vlib/node.h:486`,
`vectors_since_last_overflow` etc.) and are updated in
`vlib_node_runtime_update_stats` (`src/vlib/main.c:546`).

## Mental model

```
input node (poll)            internal nodes (drain pending frames)
─────────────────            ─────────────────────────────────────
af-packet-input / dpdk-input
   │  builds a frame
   │  [b0 b1 b2 ... b255]  (up to VLIB_FRAME_SIZE = 256 buffer indices)
   ▼
 ethernet-input  ──► ip4-input ──► ip4-lookup ──► ip4-rewrite ──► <intf>-output
   run once          run once       run once       run once         run once
   over all 256      over all 256   over all 256   over all 256     over all 256
```

Each box runs to completion over the whole vector before the next box starts.
The next file explains why that ordering is what makes packets 2..N cheap.
