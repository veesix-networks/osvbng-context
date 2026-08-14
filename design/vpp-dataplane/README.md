# VPP Dataplane Architecture

A code-grounded explanation of how VPP (Vector Packet Processing, the FD.io
project) moves packets, written so it can be cited directly in a design
review. Every claim points at a file and line in the VPP source.

osvbng is a control plane. The actual per-packet forwarding, encapsulation,
QoS, and FIB lookups happen inside VPP worker threads running the node graph
described here. Understanding this layer explains where osvbng's latency budget
goes and why the project's performance rules (no per-packet allocations, no
busy loops in the control plane, short critical sections) exist.

## Version pin

All line numbers in this folder are against:

```
VPP v26.06
git describe: v26.06-rc0-25-g3e3df231d
```

Paths are relative to the VPP source root, the pinned tree the
osvbng-vpp build checks out (see osvbng-vpp and ADR 0002).

Line numbers move between releases. Re-confirm against the exact tree you build.

## Reading order

1. [01 - The vector processing model](01-vector-processing-model.md)
   What a "vector" actually is, the node graph, frames of up to 256 packets,
   and the worker dispatch loop that calls each node once per frame.

2. [02 - Why processing the whole vector is fast](02-why-the-vector-is-fast.md)
   Instruction-cache warming, the dual/quad-loop software-pipelining pattern,
   data prefetch, SIMD batch helpers, branch-predictor warming, and cache-line
   alignment. This is the "what else makes packets 2..N fast" answer.

3. [03 - CPU feature utilisation](03-cpu-feature-utilization.md)
   Runtime CPU detection, per-microarchitecture function multi-versioning
   (the same function compiled for Haswell, Skylake-AVX512, Zen 4, Neoverse,
   etc. and selected at startup), SIMD vector types, and the `__builtin_prefetch`
   wrappers.

4. [04 - Worker threads and RX queues](04-workers-and-rx-queues.md)
   How worker threads are registered, pinned to cores, and enter the same
   dispatch loop; how a NIC RX queue is bound to a specific worker; thread 0
   (main) vs threads 1..N (workers).

5. [05 - AF_PACKET vs DPDK, and the polling question](05-afpacket-vs-dpdk-polling.md)
   The two input drivers compared. Directly answers "are we still running 100%
   CPU polling loops in both architectures?" Short version: DPDK yes by default,
   AF_PACKET no by default (it is interrupt/adaptive and sleeps in `epoll_wait`
   when idle).

## One-paragraph summary

VPP builds a directed graph of *nodes*. Instead of pushing one packet all the
way through the graph (run-to-completion, which thrashes the instruction cache),
VPP gathers a *vector* of up to 256 packets into a *frame* and runs each node's
function once over the whole frame before moving to the next node. The first
packet in the frame pays the cost of pulling that node's code into the L1
instruction cache and training the branch predictor; packets 2..N run with hot
i-cache, prefetched data, and SIMD-accelerated helpers. Workers are pthreads
pinned one-per-core, each running an identical dispatch loop over the RX queues
placed on that worker. Whether a core busy-polls at 100% or sleeps depends on
the input node's state (`POLLING` vs `INTERRUPT`), which differs by driver.
