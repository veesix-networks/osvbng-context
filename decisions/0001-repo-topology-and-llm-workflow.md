# ADR 0001 - Three-repo topology with public, LLM-first context

- Status: Accepted
- Date: 2026-08-10
- Deciders: Brandon

## Context

osvbng grew as one main repo plus eleven separate VPP plugin repos and
a private context repo mixing engineering notes with business
material. LLM-assisted development has become the normal way the
project moves, which the old layout served badly: plugin work was
scattered across repos that build in isolation from the VPP they run
on, the main repo's history absorbed high-volume mechanical commits,
process knowledge lived in a repo that could never be public, and the
spec-NNN workflow duplicated what decisions and code comments already
carry.

## Decision

**Three public repos, with the main repo consuming the other two as
submodules:**

- **osvbng**: the control plane, orchestration, releases, issues and
  changelog. Mostly human-driven; receives focused, reviewed PRs so
  its history stays readable.
- **osvbng-vpp**: every VPP plugin plus the containerized build that
  produces VPP and the plugins as one versioned artifact set. Plugin
  repos are imported with history and archived. High-volume LLM work
  lands here.
- **osvbng-context** (this repo): ADRs, design notes, LLM working
  rules, the working queue, and the spec corpus. Functions like a
  standards repo: any LLM session checks it out and reads its
  CLAUDE.md before touching the tree. `git clone --recursive` of the
  main repo yields code, plugins and decisions in one working set.

**The context is public by design.** ADRs document the project, and a
GPL project's reasoning belongs with it; LLM contribution rules are
part of the contribution surface, exactly like a style guide. The
spec-NNN workflow is retired in favor of ADRs plus purposeful
comments at the point of use.

## Consequences

- One clone gives an LLM session everything it needs to re-orient;
  ADR references in code comments resolve inside the same checkout.
- The main repo's history stays human-scale; submodule bumps are the
  only trace of mechanical churn.
- Business, branding and vendor material stay out: this repo carries
  engineering context only, and prior private notes are summarized
  (design/osvbng-implemented-summary.md) rather than migrated.
- Submodules cost some contributor friction (the --recursive habit);
  accepted for the isolation they buy.

## Alternatives considered

- **Context inside the main repo:** couples mechanical context churn
  to the repo whose history is meant to stay quiet.
- **Private context repo (status quo):** locks contribution rules and
  decisions away from the public project they govern.
- **Keep per-plugin repos:** eleven trees that cannot build against
  the one VPP they ship with; the ABI-drift class this topology
  removes.
