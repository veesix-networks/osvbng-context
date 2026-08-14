# 03 - CPU feature utilisation

> VPP v26.06 (`v26.06-rc0-25-g3e3df231d`). Paths relative to the VPP source root.

VPP is shipped as a single binary that must run well on a 2013 Haswell and a
2024 Zen 5 without being recompiled per host. It achieves this by compiling
performance-critical functions **once per CPU microarchitecture**, detecting the
host's capabilities at startup with `cpuid`, and wiring up the best variant
through a function pointer. This file walks that machinery and the SIMD types it
selects between.

## Runtime CPU detection

At startup VPP queries the CPU with `cpuid` and exposes a `clib_cpu_supports_X()`
predicate for every feature bit it cares about. The feature list is a macro
table:

`src/vppinfra/cpu.h:115` (x86_64 excerpt):

```c
#define foreach_x86_64_flags \
  _ (sse3, 1, ecx, 0)        \
  _ (ssse3, 1, ecx, 9)       \
  _ (sse41, 1, ecx, 19)      \
  _ (sse42, 1, ecx, 20)      \
  _ (avx, 1, ecx, 28)        \
  _ (avx2, 7, ebx, 5)        \
  _ (avx512f, 7, ebx, 16)    \
  // ... avx512 sub-features, vaes, vpclmulqdq, sha, movdiri, enqcmd, ...
```

Each entry expands into an inline predicate that runs `cpuid` and tests one bit:

`src/vppinfra/cpu.h` (the generator, around `:191`):

```c
#define _(flag, func, reg, bit)                                         \
static inline int clib_cpu_supports_ ## flag() {                        \
  u32 eax, ebx = 0, ecx = 0, edx = 0;                                   \
  clib_get_cpuid (func, &eax, &ebx, &ecx, &edx);                        \
  return ((reg & (1 << bit)) != 0);                                     \
}
foreach_x86_64_flags
#undef _
```

There is an equivalent `foreach_aarch64_flags` table (`src/vppinfra/cpu.h:146`)
covering NEON (`asimd`), the crypto extensions, dot-product, SVE, and so on.
`show cpu` in the VPP CLI prints the detected model, microarch, and flag set
(`show_cpu` in `src/vlib/cli.c`).

## Per-microarchitecture function multi-versioning

This is the central mechanism. A function written once with the `CLIB_MARCH_FN`
machinery is compiled multiple times, each time with a different `-march=` flag,
producing a distinct object per microarchitecture. At startup the variants
register themselves and the highest-priority one supported by the host CPU wins.

### The list of microarchitectures (build time)

`src/cmake/cpu.cmake:169` (x86_64 branch). The default baseline everything must
run on is `corei7`/`corei7-avx`; on top of that, named variants are built:

```cmake
  set(VPP_DEFAULT_MARCH_FLAGS -march=corei7 -mtune=corei7-avx)

  add_vpp_march_variant(hsw  FLAGS -march=haswell -mtune=haswell)
  add_vpp_march_variant(trm  FLAGS -march=tremont -mtune=tremont OFF)
  add_vpp_march_variant(adl  FLAGS -march=alderlake ... OFF)
  add_vpp_march_variant(scalar FLAGS -march=core2 -mno-mmx -mno-sse OFF)
  add_vpp_march_variant(znver3 FLAGS -march=znver3 ... OFF)
  // if the assembler supports AVX-512:
  add_vpp_march_variant(skx    FLAGS -march=skylake-avx512 ...)
  add_vpp_march_variant(icl    FLAGS -march=icelake-client ...)
  add_vpp_march_variant(spr    FLAGS -march=sapphirerapids ... OFF)
  add_vpp_march_variant(znver4 FLAGS -march=znver4 ...)
  add_vpp_march_variant(znver5 FLAGS -march=znver5 ... OFF)
```

The matching human-readable enum is `foreach_march_variant`:

`src/vppinfra/cpu.h:13` (x86_64) and `:24` (aarch64):

```c
#if defined(__x86_64__)
#define foreach_march_variant         \
  _ (scalar, "Generic (SIMD disabled)") \
  _ (hsw, "Intel Haswell")            \
  _ (trm, "Intel Tremont")            \
  _ (skx, "Intel Skylake (server) / Cascade Lake") \
  _ (icl, "Intel Ice Lake")           \
  _ (adl, "Intel Alder Lake")         \
  _ (spr, "Intel Sapphire Rapids")    \
  _ (znver3, "AMD Milan (Zen 3)")     \
  _ (znver4, "AMD Genoa (Zen 4)")     \
  _ (znver5, "AMD Turin (Zen 5)")
#elif defined(__aarch64__)
#define foreach_march_variant         \
  _ (octeontx2, ...) _ (thunderx2t99, ...) _ (cortexa72, ...) \
  _ (neoversen1, ...) _ (neoversen2, ...) _ (neoversev2, ...)
#endif
```

### Selecting the variant at startup

Each compiled variant runs a constructor that registers its function pointer
with a priority. The priority for each microarch is gated on a `cpuid` check, so
a variant that the host cannot run returns `-1` and is never selected:

`src/vppinfra/cpu.h:285` (selected priorities):

```c
clib_cpu_march_priority_spr ()    -> 300 if Intel && enqcmd
clib_cpu_march_priority_icl ()    -> 200 if Intel && avx512_bitalg
clib_cpu_march_priority_adl ()    -> 150 if Intel && movdiri && avx2
clib_cpu_march_priority_skx ()    -> 100 if Intel && avx512f
clib_cpu_march_priority_hsw ()    ->  50 if avx2
clib_cpu_march_priority_trm ()    ->  40 if Intel && movdiri
clib_cpu_march_priority_znver5 () -> 350 if AMD  && avx512_vp2intersect
clib_cpu_march_priority_znver4 () -> 250 if AMD  && avx512f
clib_cpu_march_priority_znver3 () ->  70 if AMD  && vaes
```

The registry is a linked list of `clib_march_fn_registration`
(`src/vppinfra/cpu.h:56`), and selection just walks it keeping the
highest-priority entry:

`src/vppinfra/cpu.h:64`

```c
static_always_inline void *
clib_march_select_fn_ptr (clib_march_fn_registration * r)
{
  void *rv = 0;
  int last_prio = -1;
  while (r)
    {
      if (last_prio < r->priority)
        {
          last_prio = r->priority;
          rv = r->function;
        }
      r = r->next;
    }
  return rv;
}
```

So on a Zen 4 host, the `znver4` variant (priority 250) wins over `skx` (100)
and `hsw` (50); on a Skylake-SP host, `skx` wins; on an old box with only AVX2,
`hsw` wins; with nothing, the `corei7` baseline runs. No recompile, no config.

### How a node opts in

Forwarding nodes are multi-versioned for free: `VLIB_NODE_FN`
(`src/vlib/node.h:208`) wraps the node function name in `CLIB_MARCH_SFX`, so the
node's per-packet code is compiled once per microarch and the registration picks
the best one. Standalone hot functions use `CLIB_MARCH_FN` directly and are
called through `CLIB_MARCH_FN_SELECT(fn)` (`svm_fifo.c` is a clear example, as
are the `vlib_buffer_enqueue_*` batch primitives).

## SIMD vector types

VPP defines fixed-width vector types per ISA so node code can be written against
`u8x16` / `u8x32` / `u8x64` and the right intrinsics get emitted. Each header is
a macro table over `(lane-type, lane-bits, lane-count, intrinsic-suffix)`:

| Header | Width | Example types | Backing ISA |
|--------|-------|---------------|-------------|
| `src/vppinfra/vector_sse42.h:12` | 128-bit | `u8x16`, `u32x4`, `u64x2` | SSE4.2 (`_mm_*`) |
| `src/vppinfra/vector_avx2.h:12` | 256-bit | `u8x32`, `u32x8`, `u64x4` | AVX2 (`_mm256_*`) |
| `src/vppinfra/vector_avx512.h:12` | 512-bit | `u8x64`, `u32x16`, `u64x8` | AVX-512 (`_mm512_*`) |
| `src/vppinfra/vector_neon.h:36` | 128-bit | `u8x16`, `u32x4`, ... | Arm NEON (`v*q_*`) |

`src/vppinfra/vector_avx2.h:12`:

```c
#define foreach_avx2_vec256u \
  _(u,8,32,epi8) _(u,16,16,epi16) _(u,32,8,epi32) _(u,64,4,epi64)
```

These are what back the batch helpers from [02](02-why-the-vector-is-fast.md):
`clib_index_to_ptr_u32` (the buffer index-to-pointer gather) has SSE/AVX2/AVX512
implementations that load 4/8/16 indices, shift them into byte offsets, add the
buffer-pool base, and store 4/8/16 pointers per instruction.

## Other CPU features VPP reaches for

- **TSC for timing.** `clib_cpu_time_now()` reads the timestamp counter directly
  (`rdtsc`) for the per-node cycle accounting in the dispatch loop. VPP detects
  `invariant_tsc` (`foreach_x86_64_flags`) to trust it as a clock source.
- **`cldemote`.** `clib_cl_demote()` (`src/vppinfra/cache.h:107`) emits
  `cldemote` when `__CLDEMOTE__` is set, pushing a finished cache line toward
  LLC so a downstream worker (or device) gets it faster. No-op where unsupported.
- **Crypto/IO extensions.** AES-NI, VAES, SHA, `vpclmulqdq` (IPsec, hashing),
  `movdiri`/`movdir64b`/`enqcmd` (low-overhead doorbell writes to accelerators)
  are all in the detected flag set and gate the higher-priority variants above.

## The takeaway for a blog

VPP does not assume a CPU. It enumerates the host's capabilities at boot, and
for every function that matters it has pre-compiled a Haswell version, a
Skylake-AVX512 version, a Zen 4 version, a Neoverse version, and a scalar
fallback. A function-pointer indirection per hot function, resolved once at
startup, is the entire runtime cost of that flexibility.
