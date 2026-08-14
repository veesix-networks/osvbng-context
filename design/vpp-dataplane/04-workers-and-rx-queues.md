# 04 - Worker threads and RX queues

> VPP v26.06 (`v26.06-rc0-25-g3e3df231d`). Paths relative to the VPP source root.

This file answers: how does a worker thread come into existence, how is it
pinned to a core, how does it end up running the dispatch loop from
[01](01-vector-processing-model.md), and how do packets from a specific NIC RX
queue reach a specific worker?

## Thread 0 is main, threads 1..N are workers

VPP numbers threads from 0. Thread 0 is the **main** thread: it runs the CLI,
the API, the process nodes, and management work. Threads 1..N are **workers**:
they do nothing but run the per-packet dispatch loop. Each thread has its own
clone of `vlib_main_t` and learns its identity from a thread-local index.

`src/vlib/threads.h` exposes the helpers:

- `vlib_get_thread_index()` returns the current thread's index (`__os_thread_index`).
- `vlib_num_workers()` is `n_vlib_mains - 1`.
- `vlib_get_worker_thread_index(w)` maps worker number `w` (0-based) to thread
  index `w + 1`.

Both main and workers run the **same** loop function, `vlib_main_or_worker_loop`
(`src/vlib/main.c:1446`), distinguished only by its `is_main` argument. The main
thread calls it with `is_main = 1`; workers call it with `0`.

## Registering the worker thread type

The "workers" thread class is registered declaratively with
`VLIB_REGISTER_THREAD`, which names the entry function each spawned worker
pthread will run:

`src/vlib/main.c:2067`

```c
VLIB_REGISTER_THREAD (worker_thread_reg, static) = {
  .name = "workers",
  .short_name = "wk",
  .function = vlib_worker_thread_fn,
};
```

That entry function initialises the worker (its heap, timer wheel, file poller)
and then enters the shared loop and never returns:

`src/vlib/main.c:2040`

```c
vlib_worker_thread_fn (void *arg)
{
  vlib_worker_thread_t *w = (vlib_worker_thread_t *) arg;
  vlib_main_t *vm = vlib_get_main ();

  ASSERT (vm->thread_index == vlib_get_thread_index ());
  vm->numa_node = clib_get_current_numa_node ();

  vlib_worker_thread_init (w);
  clib_time_init (&vm->clib_time);
  clib_mem_set_heap (w->thread_mheap);
  vlib_tw_init (vm);
  vlib_file_poll_init (vm);
  // ... call worker init functions ...

  vlib_main_or_worker_loop (vm, /* is_main */ 0);   // never returns
}
```

## Spawning and pinning to a core

Workers are created from `start_workers` (`src/vlib/threads.c`), which clones
`vlib_main_t` per worker (giving each its own node runtimes, frames, and
counters) and then launches a pthread for each. The launch and the CPU pinning
are in `vlib_launch_thread_int`:

`src/vlib/threads.c:510`

```c
static clib_error_t *
vlib_launch_thread_int (void *fp, vlib_worker_thread_t * w, unsigned cpu_id)
{
  pthread_t worker;
  pthread_attr_t attr;
  cpu_set_t cpuset;

  w->cpu_id = cpu_id;
  vlib_get_thread_core_numa (w, cpu_id);

  CPU_ZERO (&cpuset);
  CPU_SET (cpu_id, &cpuset);

  pthread_attr_init (&attr);
  pthread_attr_setstack (&attr, w->thread_stack, VLIB_THREAD_STACK_SIZE);
  pthread_create (&worker, &attr, fp_arg, (void *) w);
  pthread_setaffinity_np (worker, sizeof (cpu_set_t), &cpuset);   // pin to core
  // ...
}
```

The `pthread_setaffinity_np` at `src/vlib/threads.c:534` is the pin. After this,
that worker only ever runs on `cpu_id`. The set of cores VPP may use comes from
the startup config (`cpu { main-core ... corelist-workers ... }`) and is resolved
in `vlib_thread_init` (`src/vlib/threads.c`). Each worker gets its own dedicated
core; this is why VPP forwarding throughput scales close to linearly with worker
count and why nothing else should be scheduled on those cores.

## Binding an RX queue to a worker

A NIC presents one or more hardware RX queues. Each queue is described by a
`vnet_hw_if_rx_queue_t`, which carries the index of the **single worker thread**
that services it:

`src/vnet/interface.h:610` (fields):

```c
typedef struct {
  u32 hw_if_index;
  u32 dev_instance;
  clib_thread_index_t thread_index;   // which worker polls this queue
  u32 file_index;                     // fd for interrupt mode (~0 if none)
  u32 queue_id;                       // hardware queue id
  vnet_hw_if_rx_mode mode;            // polling / interrupt / adaptive
  // ...
} vnet_hw_if_rx_queue_t;
```

The binding is set by `vnet_hw_if_set_rx_queue_thread_index`, which is what the
`set interface rx-placement <intf> queue <q> worker <w>` CLI ultimately calls:

`src/vnet/interface/rx_queue.c:216`

```c
void
vnet_hw_if_set_rx_queue_thread_index (vnet_main_t *vnm, u32 queue_index,
                                      clib_thread_index_t thread_index)
{
  vnet_hw_if_rx_queue_t *rxq = vnet_hw_if_get_rx_queue (vnm, queue_index);
  // ...
  rxq->thread_index = thread_index;

  if (rxq->file_index != ~0)
    clib_file_set_polling_thread (&file_main, rxq->file_index, thread_index);
  // ...
}
```

Note the second half: if the queue has an interrupt fd (`file_index != ~0`), the
fd's epoll registration is moved to the same worker, so both the busy-poll path
and the interrupt path for that queue land on one core. That keeps a queue's
processing on a single core's caches.

## How a worker knows which queues to poll

An input node does **not** scan all interfaces. Each worker's copy of the input
node carries a per-thread *poll vector*: a compact list of `(dev_instance,
queue_id)` pairs that this worker is responsible for.

`src/vnet/interface.h:775`

```c
typedef struct {
  u32 dev_instance;
  u32 queue_id;
} vnet_hw_if_rxq_poll_vector_t;
```

When the placement or the mode of any queue changes, VPP regenerates these
per-thread vectors (`src/vnet/interface/runtime.c`), splitting queues into the
polling set and the adaptive set per worker based on each queue's mode and
`thread_index`. The input node simply asks for its vector at the top of its
function:

This is exactly the loop you see in both drivers. AF_PACKET
(`src/plugins/af_packet/node.c:778`):

```c
VLIB_NODE_FN (af_packet_input_node) (vlib_main_t * vm, ...)
{
  vnet_hw_if_rxq_poll_vector_t *pv;
  pv = vnet_hw_if_get_rxq_poll_vector (vm, node);   // this worker's queues
  for (int i = 0; i < vec_len (pv); i++)
    {
      apif = vec_elt_at_index (apm->interfaces, pv[i].dev_instance);
      if (apif->is_admin_up)
        n_rx_packets += af_packet_device_input_fn (vm, node, frame, apif,
                                                    pv[i].queue_id, ...);
    }
  return n_rx_packets;
}
```

DPDK is structurally identical (`src/plugins/dpdk/device/node.c:531`): get the
poll vector, loop over `(dev_instance, queue_id)`, call the device input.

`vnet_hw_if_get_rxq_poll_vector` returns the polling set when the node is in
polling state and the interrupt set when an interrupt fired
(`vnet_hw_if_generate_rxq_int_poll_vector`, `src/vnet/interface/rx_queue.c:233`,
builds the latter from the pending-interrupt bitmap). That distinction is the
subject of [05](05-afpacket-vs-dpdk-polling.md).

## Picture

```
core 0          core 1 (worker 1)            core 2 (worker 2)
──────          ──────────────────           ──────────────────
main thread     vlib_main_or_worker_loop     vlib_main_or_worker_loop
 CLI/API         poll vector:                  poll vector:
 process nodes    eth0 q0, eth1 q0              eth0 q1, eth1 q1
                  │                              │
                  ▼                              ▼
                 af-packet/dpdk-input           af-packet/dpdk-input
                  → ethernet-input → ...         → ethernet-input → ...
```

RSS (or the driver's hashing) spreads flows across the hardware queues; each
queue is pinned to one worker; each worker owns its cores' caches end to end.
osvbng sets this placement as part of bringing an interface up.
