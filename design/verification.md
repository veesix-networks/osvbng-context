# How changes are verified

A change is done when it runs against reality, not when it
compiles or its unit tests pass (CLAUDE.md, rules for LLM
sessions). Reality is the integration suites under
`osvbng/tests/`, run locally; there is no standing test
infrastructure. This note maps those suites so a session can find
and run the right one. The
authoritative description lives with the code in
`osvbng/docs/qa/testing-methodology.md` (suite catalog, HA
testing, dataplane performance testing, release qualification);
this note does not duplicate it.

## Shape

Every integration suite is a directory under `osvbng/tests/` named
`NN-topic` (01-smoke through the l2tp, cgnat, ha, routing and api
suites, 40 plus of them) containing a containerlab topology
(`NN-topic.clab.yml`), a Robot Framework suite (`NN-topic.robot`)
and its config tree. Shared keywords live in `tests/*.robot`
(common, sessions, localauth, restart, l2gw). The topology runs
the locally built osvbng image against real peers: FRR core
routers, bngblaster subscriber simulation, FreeRADIUS, Kea for
relay and proxy, xl2tpd as an external LAC for the LNS suite.

## Running

From the osvbng repo:

    make robot-test suite=NN-topic

or directly, `./tests/rf-run.sh ./tests/NN-topic/`. The runner
creates its own venv and writes results to `tests/out/`.

## What a green suite proves, and what it does not

The dataplane under test is not built from osvbng-vpp at test
time. The image is stock VPP debs at the pinned version plus
plugin binaries committed by hand under
`osvbng/test-infra/vpp-plugins/`, produced by an osvbng-vpp
release build at some past commit. That set includes a rebuilt
`af_packet_plugin.so`, which is the only way the osvbng-vpp patch
queue reaches the tests at all: the stock debs do not carry the
patches.

So a green suite proves osvbng HEAD against that binary drop, not
against osvbng-vpp main. When either repo has moved since the last
drop, a pass says nothing about the current pair. Before treating
a result as proof, check the drop's freshness
(`git log -1 -- test-infra/vpp-plugins/` in osvbng) against what
changed in osvbng-vpp, and state the dataplane provenance in the
PR's verification section. A change in osvbng-vpp itself is only
exercised after a fresh drop built from that change. The standing
fix is queued in todo.md: one release build produces
version-stamped artifacts and the suites consume those, removing
the hand-copied binaries.

## What this means for a session

The suites run on the shared rig in three tiers, described in
osvbng `docs/contributing/ci-and-review.md`. A pull request runs
the core set listed in `tests/ci-suites.txt` (`integration.yml`),
held behind a maintainer approval gate because it executes PR code
on the rig. The full matrix runs nightly (`nightly.yml`) and
before a release (`release-qualification.yml`). `skip-suites.txt`
excludes suites from both CI and the local sweep, and asks for a
reason per entry.

Two things follow. A green PR run covers the allowlist, not the
catalog: read both files before assuming a suite ran, because a
suite in neither list never runs at all. And the tiers do not
change the dataplane-provenance problem above, which is what the
artifact work in todo.md fixes.

So "verified" still does not mean "CI will catch it": run the
suite covering the touched area before calling work done, and
anything a subscriber touches runs against bngblaster.
Pick the suite by number from the catalog in the methodology doc,
or add one when no suite covers the behavior. Report results
exactly: which suite, pass or fail, what was not run, and which
dataplane drop it ran against.
