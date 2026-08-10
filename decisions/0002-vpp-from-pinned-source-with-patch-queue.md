# ADR 0002 - VPP built from pinned source with a maintained patch queue

- Status: Accepted
- Date: 2026-08-10
- Deciders: Brandon

## Context

osvbng consumed prebuilt VPP packages pinned to exact versions. The
pin discipline existed because ABI drift between package rebuilds
caused silent plugin crashes, but it also meant upstream VPP bugs
could never be fixed at the source: every VPP issue became a
workaround in osvbng code or a wait for upstream. Separately, the
plugins were built out of tree against installed headers, which is a
second ABI seam.

## Decision

**osvbng-vpp builds VPP from the pinned upstream tag (currently
v26.06) with a patch queue applied in order, and every plugin builds
inside that exact tree, in one containerized pipeline producing one
versioned artifact set.**

- Patches are first-class citizens: numbered, reviewed like code,
  each carrying the problem it fixes, the upstream link, and an
  Upstream-Status (submitted, merged-in-future, local-only with
  justification).
- Upstream-first: fixes that can go to fd.io go to fd.io. Local-only
  needs a stated reason.
- A version bump re-applies the queue (drop merged, rebase the rest)
  and the bump PR lists every patch's disposition; the bump is done
  when the queue is clean and every plugin rebuilds.
- The build is containerized (deps baked at the pinned tag) so any
  docker host produces identical artifacts; CI never compiles VPP.
- Go bindings for the binary API are generated from this pipeline's
  own api json during release, version-stamped, and consumed by
  osvbng, never generated from a developer's local tree.

## Consequences

- Upstream bugs become patches with provenance instead of buried
  workarounds; a release is reproducible from (tag, queue, plugins).
- Rebase cost lands on every bump, bounded by the upstream-first
  policy keeping the queue short.
- The dev loop (make vpp-dev) reuses the same container and tree
  incrementally, so plugin iteration is seconds; release artifacts
  come only from the clean path.

## Alternatives considered

- **Prebuilt packages (status quo):** cannot patch, ABI surprises,
  bugs wait on upstream cadence.
- **A real VPP fork:** drifts irrecoverably within releases; the
  queue keeps every divergence small, named and justified.
- **Vendoring VPP:** bloats the tree with code we do not modify
  wholesale; the pin plus queue carries the same information.
