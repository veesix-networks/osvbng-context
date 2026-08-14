# 05 - AF_PACKET vs DPDK, and the polling question

> VPP v26.06 (`v26.06-rc0-25-g3e3df231d`). Paths relative to the VPP source root.

The question this file answers directly: **are we still running 100% CPU
polling loops in both architectures?**

Short answer: **DPDK, yes by default.** **AF_PACKET, no by default**: its input
node is registered in interrupt mode and only switches to busy-polling while a
backlog exists, sleeping the core in `epoll_wait` when the ring is empty. Both
behaviours are a property of one field (the input node's `state`) plus the
shared file poller, not of the driver's packet path. Below is the evidence.

## The two drivers in one table

| | AF_PACKET | DPDK |
|---|---|---|
| Where packets come from | Linux kernel `PACKET_MMAP` ring (`TPACKET` v2/v3), shared mmap'd with the kernel | NIC hardware RX ring, mapped directly into userspace via a poll-mode driver (PMD); kernel not involved |
| Per-packet fetch | read filled slots from the mmap ring | `rte_eth_rx_burst()` |
| Input node | `af_packet_input_node`, `src/plugins/af_packet/node.c:778` | `dpdk_input_node`, `src/plugins/dpdk/device/node.c:531` |
| Registered default state | `VLIB_NODE_STATE_INTERRUPT` (`node.c:809`) | `VLIB_NODE_STATE_DISABLED`, set to polling when hardware is detected (`node.c:561`) |
| Default idle behaviour | core sleeps in `epoll_wait` on the socket fd | core busy-polls the NIC ring at 100% |
| Can do the other mode? | yes, switches to polling under load (adaptive) | yes, supports `rte_eth_dev_rx_intr_*` interrupt mode if you ask for it |
| Typical use | dev, lab, low-rate, containers without hugepages/VFIO | production line-rate forwarding |

## DPDK: pure poll-mode by default

The DPDK input node is registered **disabled**, and enabled to the polling state
once a device is bound:

`src/plugins/dpdk/device/node.c:555`

```c
VLIB_REGISTER_NODE (dpdk_input_node) = {
  .type = VLIB_NODE_TYPE_INPUT,
  .name = "dpdk-input",
  .sibling_of = "device-input",
  .flags = VLIB_NODE_FLAG_TRACE_SUPPORTED,

  /* Will be enabled if/when hardware is detected. */
  .state = VLIB_NODE_STATE_DISABLED,
  // ...
};
```

Once enabled (polling), the dispatch loop calls it on **every** iteration
(`src/vlib/main.c:1552`, `n->state == VLIB_NODE_STATE_POLLING`). Its fetch is a
straight burst poll of the hardware ring:

`src/plugins/dpdk/device/node.c:357` (inside `dpdk_device_input`):

```c
  /* get up to DPDK_RX_BURST_SZ buffers from PMD */
  while (n_rx_packets < DPDK_RX_BURST_SZ)
    {
      u32 n_to_rx = clib_min (DPDK_RX_BURST_SZ - n_rx_packets, 32);
      n = rte_eth_rx_burst (xd->port_id, queue_id, ptd->mbufs + n_rx_packets,
                            n_to_rx);
      n_rx_packets += n;
      if (n < n_to_rx)
        break;
    }

  if (n_rx_packets == 0)
    return 0;          // nothing there; node returns 0 and is polled again
```

When the wire is idle, `rte_eth_rx_burst` returns 0, the node returns 0, and the
main loop immediately calls it again. That is a 100% busy core by design: it is
how DPDK achieves sub-microsecond reaction time and avoids interrupt overhead at
line rate. `top` will show the worker core pinned at 100% even on an idle link.

DPDK *can* run interrupt-driven. `dpdk_setup_interrupts`
(`src/plugins/dpdk/device/common.c`) probes `rte_eth_dev_rx_intr_enable`, and if
the NIC supports it, registers a `clib_file_t` per queue with the
`dpdk_rx_read_ready` callback. `dpdk_interface_rx_mode_change`
(`src/plugins/dpdk/device/device.c`) toggles `rte_eth_dev_rx_intr_enable/disable`
when you change rx-mode. But the default for a forwarding deployment is polling.

## AF_PACKET: interrupt by default, adaptive under load

The AF_PACKET input node is registered in **interrupt** state, not polling:

`src/plugins/af_packet/node.c:803`

```c
VLIB_REGISTER_NODE (af_packet_input_node) = {
  .name = "af-packet-input",
  .flags = VLIB_NODE_FLAG_TRACE_SUPPORTED,
  .sibling_of = "device-input",
  .format_trace = format_af_packet_input_trace,
  .type = VLIB_NODE_TYPE_INPUT,
  .state = VLIB_NODE_STATE_INTERRUPT,         // <-- not POLLING
  // ...
};
```

In interrupt state the dispatch loop does **not** call it every iteration
(`src/vlib/main.c:1552` only runs `POLLING` nodes). Instead the kernel signals
readability on the AF_PACKET socket fd, the shared file poller wakes the worker,
and the node runs to drain the ring.

The clever part is that the node flips itself between polling and interrupt based
on whether the ring still has packets waiting, at the end of each run:

`src/plugins/af_packet/node.c:520`

```c
  if (apm->polling_count == 0)
    {
      if ((((block_desc_t *) (block_start = rx_queue->rx_ring[block]))
             ->hdr.bh1.block_status &
           TP_STATUS_USER) != 0)
        vlib_node_set_state (vm, node->node_index, VLIB_NODE_STATE_POLLING);
      else
        vlib_node_set_state (vm, node->node_index, VLIB_NODE_STATE_INTERRUPT);
    }
```

`TP_STATUS_USER` means "the kernel has filled this block, it is the user's to
read." So: if there is still a filled block waiting, switch to **polling**
(keep draining hot, do not pay the syscall/wakeup round trip per burst); if the
next block is empty, switch back to **interrupt** and let the core sleep until
the kernel has more. The result is a core that busy-polls only while it is
actually busy, and idles cheaply otherwise. (AF_PACKET explicitly rejects the
generic "adaptive" rx-mode in `af_packet_interface_rx_mode_change`,
`src/plugins/af_packet/device.c`, because it implements this in-node instead.)

## The deciding mechanism: `vlib_file_poll` and the sleep

Whether a worker core spins or sleeps comes down to one function the main loop
calls each iteration, `vlib_file_poll` (`src/vlib/main.c:1546` calls it). Its job
is to service fd events, but it is also where a worker decides to block:

`src/vlib/file.c:106`

```c
void
vlib_file_poll (vlib_main_t *vm)
{
  // ...
  int timeout_ms = 0, max_timeout_ms = 10;

  /* we are busy, skip some loops before polling again */
  if (vlib_last_vectors_per_main_loop (vm) >= 2)
    goto skip_loops;

  /* at least one node is polling */
  if (nm->input_node_counts_by_state[VLIB_NODE_STATE_POLLING])
    goto skip_loops;
  // ... (also skips if APIs queued, or recently after a barrier release) ...

  /* check for pending interrupts */
  for (int nt = 0; nt < VLIB_N_NODE_TYPE; nt++)
    if (nm->node_interrupts[nt] &&
        clib_interrupt_is_any_pending (nm->node_interrupts[nt]))
      goto epoll;

  /* at this point we know that thread is going to sleep ... */
  __atomic_store_n (&vm->thread_sleeps, 1, __ATOMIC_RELAXED);

  ticks = vlib_tw_timer_first_expires_in_ticks (vm);
  if (ticks != TW_SLOTS_PER_RING)
    timeout_ms = clib_min (ticks_to_ms, max_timeout_ms);
  else
    timeout_ms = max_timeout_ms;
  goto epoll;

skip_loops:
  vm->file_poll_skip_loops = 1024;     // don't even epoll for 1024 dispatches

epoll:
  n_fds_ready = epoll_wait (vm->epoll_fd, epoll_events,
                            ARRAY_LEN (epoll_events), timeout_ms);
  // ...
}
```

Read it as a decision tree:

- **Any input node on this worker is in `POLLING` state** (or the worker just
  did real work, `vectors/loop >= 2`): `goto skip_loops`, set
  `file_poll_skip_loops = 1024` and call `epoll_wait` with `timeout_ms = 0`
  (non-blocking). The worker returns immediately and the `while (1)` loop spins.
  **This is the 100% busy core.** It is the steady state for DPDK, and for
  AF_PACKET while a backlog exists.
- **No input node is polling, nothing pending**: announce `thread_sleeps = 1`,
  compute a timeout from the timer wheel (capped at `max_timeout_ms = 10`), and
  call `epoll_wait` with that real timeout (`src/vlib/file.c:181`). **The core
  blocks here.** It wakes on a packet (the AF_PACKET socket fd becomes readable),
  an interrupt, a timer, or a cross-thread wakeup. **This is the sleeping core**,
  the steady state for idle AF_PACKET.

So the same loop body produces a busy-poll or a sleep depending entirely on
whether the worker has a node in the polling state. DPDK keeps its node polling;
AF_PACKET drops its node out of polling whenever the ring drains.

## Direct answers

- **Is VPP a polling architecture?** At line rate, yes, and deliberately so.
  Polling avoids per-packet interrupt overhead and gives deterministic latency.
- **Does DPDK busy-poll at 100%?** Yes, by default, on every assigned worker
  core, even on an idle link. That is the cost of its latency profile.
- **Does AF_PACKET busy-poll at 100%?** Not by default. It is interrupt-driven
  and sleeps in `epoll_wait` when idle, busy-polling only while the kernel ring
  has a backlog. Its worst case under sustained load looks like DPDK; its idle
  case looks like a normal blocked thread.
- **Can you change either?** Yes. `set interface rx-mode <intf> [polling |
  interrupt | adaptive]` drives `*_interface_rx_mode_change` in each driver. The
  defaults above are just the starting `.state` in the node registration plus
  the in-node adaptive logic.

## Why this matters for osvbng

For lab and CI topologies osvbng runs over AF_PACKET (no hugepages or VFIO
needed, runs in plain containers), so an idle test box is not pegged at 100% per
worker. For production line-rate BNG forwarding the dataplane is DPDK (or another
poll-mode driver), where each worker owns a core and spins. Either way the rest
of the graph above the input node ([01](01-vector-processing-model.md) through
[03](03-cpu-feature-utilization.md)) is identical; only the first node and its
polling discipline differ.
