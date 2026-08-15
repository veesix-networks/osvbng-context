# How changes are verified

Rule 8 says a change is done when it runs against reality.
Reality is the integration suites under `osvbng/tests/`, run
locally; there is no standing test infrastructure. This note maps
those suites so a session can find and run the right one. The
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
fix is todo item 2: one release build produces version-stamped
artifacts and the suites consume those, removing the hand-copied
binaries.

## What this means for a session

The suites run locally, and only locally. Workflow files for them
exist under `.github/workflows/`, but they are not the
verification path in practice: building the dataplane from
scratch on a runner made every run too slow, so integration runs
never went through CI and the maintainer runs suites on the dev
machine. CI gates a pull request on build and unit tests only.
Wiring the suites into CI is wanted and is blocked on the same
thing as todo item 2: prebuilt version-stamped artifacts, so a
runner assembles an image instead of compiling a dataplane.

So "verified" in a PR body can never mean "CI will catch it": run
the suite covering the touched area locally before calling work
done, and anything a subscriber touches runs against bngblaster.
Pick the suite by number from the catalog in the methodology doc,
or add one when no suite covers the behavior. Report results
exactly: which suite, pass or fail, what was not run, and which
dataplane drop it ran against.
